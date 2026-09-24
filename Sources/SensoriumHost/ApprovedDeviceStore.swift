import Foundation

/// Which paired machines' keys may open a session. These are public keys, not
/// secrets; what matters is that the list survives a host restart and that only
/// the pairing ceremony adds to it.
public protocol ApprovedDeviceStoring: Sendable {
    func load() -> Set<Data>
    func save(_ keys: Set<Data>)
    /// Un-pairs one device. Read-modify-write over `load()`/`save(_:)`, so it
    /// needs no storage of its own; a conforming type gets a correct
    /// implementation for free through the extension below.
    func remove(_ publicKey: Data)
    /// The name `publicKey`'s device gave when it paired -- see
    /// `HostPairingService.handlePairRequest`. `nil` for a key approved by an
    /// earlier version of this store, before this field existed, or one no
    /// caller ever named; a reader that needs to show something falls back
    /// to a fingerprint of the key itself, see `ApprovedDeviceDisplayName`.
    func name(for publicKey: Data) -> String?
    func setName(_ name: String?, for publicKey: Data)
}

extension ApprovedDeviceStoring {
    public func remove(_ publicKey: Data) {
        var keys = load()
        keys.remove(publicKey)
        save(keys)
        setName(nil, for: publicKey)
    }
}

public final class InMemoryApprovedDeviceStore: ApprovedDeviceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<Data>
    private var names: [Data: String] = [:]

    public init(keys: Set<Data> = []) {
        self.keys = keys
    }

    public func load() -> Set<Data> {
        lock.lock()
        defer { lock.unlock() }
        return keys
    }

    public func save(_ keys: Set<Data>) {
        lock.lock()
        defer { lock.unlock() }
        self.keys = keys
    }

    public func name(for publicKey: Data) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return names[publicKey]
    }

    public func setName(_ name: String?, for publicKey: Data) {
        lock.lock()
        defer { lock.unlock() }
        names[publicKey] = name
    }
}

/// One JSON file at an explicitly supplied URL: an array of each approved
/// key with the name recorded for it, if any.
public final class FileApprovedDeviceStore: ApprovedDeviceStoring, @unchecked Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// A key this file may already carry from a build that wrote more per
    /// device than this one reads is decoded past rather than refused:
    /// Swift's synthesized decoder ignores what this type has no property
    /// for, and the next write drops it.
    private struct StoredDevice: Codable {
        let publicKey: String
        var name: String?
    }

    /// Decodes the current shape first; falls back to the shape this file
    /// held before device names existed -- a plain array of base64 keys --
    /// so a store written by an older build still loads, with every key
    /// reading back as having no name.
    private func readDevices() -> [StoredDevice] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        if let devices = try? JSONDecoder().decode([StoredDevice].self, from: data) {
            return devices
        }
        let legacyKeys = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return legacyKeys.map { StoredDevice(publicKey: $0, name: nil) }
    }

    private func writeDevices(_ devices: [StoredDevice]) {
        let sorted = devices.sorted { $0.publicKey < $1.publicKey }
        guard let data = try? JSONEncoder().encode(sorted) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
        // Approved keys are not secrets, but which machines may reach this
        // one is the person at this machine's own business -- the same
        // owner-only permission `HostScreenArmingStore` already sets on
        // its own file.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    public func load() -> Set<Data> {
        Set(readDevices().compactMap { Data(base64Encoded: $0.publicKey) })
    }

    public func save(_ keys: Set<Data>) {
        // A name already on disk for a key that is still approved survives
        // a `save(_:)` driven only by the key set, such as the one
        // `HostPairingService` issues right after inserting a new key -- it
        // must not be wiped by a wholly unrelated device pairing.
        let existingDevices = Dictionary(uniqueKeysWithValues: readDevices().map { ($0.publicKey, $0) })
        let devices = keys.map { key -> StoredDevice in
            let encoded = key.base64EncodedString()
            return existingDevices[encoded] ?? StoredDevice(publicKey: encoded, name: nil)
        }
        writeDevices(devices)
    }

    public func name(for publicKey: Data) -> String? {
        let encoded = publicKey.base64EncodedString()
        return readDevices().first { $0.publicKey == encoded }?.name
    }

    public func setName(_ name: String?, for publicKey: Data) {
        let encoded = publicKey.base64EncodedString()
        var devices = readDevices()
        if let index = devices.firstIndex(where: { $0.publicKey == encoded }) {
            devices[index].name = name
        } else if name != nil {
            devices.append(StoredDevice(publicKey: encoded, name: name))
        }
        writeDevices(devices)
    }

}

/// The name to show for an approved device: the one it gave at pairing when
/// there is one, or a short fingerprint of its key -- never blank, and
/// never invented. The fingerprint is deliberately not the name recorded
/// alongside an unnamed key; it is derived from the key itself, so it
/// reads the same way every time a caller asks about that key.
public enum ApprovedDeviceDisplayName {
    public static func resolve(for publicKey: Data, in store: any ApprovedDeviceStoring) -> String {
        store.name(for: publicKey) ?? fingerprint(of: publicKey)
    }

    public static func fingerprint(of publicKey: Data) -> String {
        "Machine " + hex(of: publicKey)
    }

    /// The same short hex digest `fingerprint(of:)` names a device by, on
    /// its own -- for a caller that already has a name to show as the title
    /// and wants this only as a secondary line distinguishing it from
    /// another device of the same name, not as the title itself.
    public static func hex(of publicKey: Data) -> String {
        publicKey.prefix(4).map { String(format: "%02X", $0) }.joined()
    }
}

import Foundation
import SensoriumCore

/// Which paired machines' keys may open a session. These are public keys, not
/// secrets; what matters is that the list survives a host restart and that only
/// the pairing ceremony adds to it.
public protocol ApprovedDeviceStoring: Sendable {
    func load() -> Set<Data>
    func save(_ keys: Set<Data>)
    /// Un-pairs one device: its key and both of its names go in one step,
    /// so no write running at the same moment can bring any of them back.
    func remove(_ publicKey: Data)
    /// The name `publicKey`'s device gave when it paired -- see
    /// `HostPairingService.handlePairRequest`. `nil` for a key approved by an
    /// earlier version of this store, before this field existed, or one no
    /// caller ever named; a reader that needs to show something falls back
    /// to a fingerprint of the key itself, see `ApprovedDeviceDisplayName`.
    func name(for publicKey: Data) -> String?
    /// Writes only to a key already approved: a name is never how a device
    /// gets onto this list.
    func setName(_ name: String?, for publicKey: Data)
    /// The name the person at this machine chose for `publicKey`'s device
    /// in the paired list, or `nil` when they never renamed it. Kept apart
    /// from `name(for:)` so the name a device reports on the wire, which
    /// updates that one, can never overwrite a name chosen here. Only the
    /// host window's Rename writes it, through `PairedDeviceName.rename`.
    func customName(for publicKey: Data) -> String?
    /// Writes only to a key already approved, like `setName(_:for:)`.
    func setCustomName(_ name: String?, for publicKey: Data)
}

public final class InMemoryApprovedDeviceStore: ApprovedDeviceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<Data>
    private var names: [Data: String] = [:]
    private var customNames: [Data: String] = [:]

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

    public func remove(_ publicKey: Data) {
        lock.lock()
        defer { lock.unlock() }
        keys.remove(publicKey)
        names[publicKey] = nil
        customNames[publicKey] = nil
    }

    public func name(for publicKey: Data) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return names[publicKey]
    }

    public func setName(_ name: String?, for publicKey: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard keys.contains(publicKey) else { return }
        names[publicKey] = name
    }

    public func customName(for publicKey: Data) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return customNames[publicKey]
    }

    public func setCustomName(_ name: String?, for publicKey: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard keys.contains(publicKey) else { return }
        customNames[publicKey] = name
    }
}

/// One JSON file at an explicitly supplied URL: an array of each approved
/// key with the name it reported and the name chosen for it here, each if
/// any.
public final class FileApprovedDeviceStore: ApprovedDeviceStoring, @unchecked Sendable {
    private let url: URL
    /// Held for every read and write of the file, so each mutator's
    /// read-modify-write is one step: writers run on the connection thread,
    /// the pairing ceremony and the host window at once, and an unlocked
    /// write from a stale read would silently undo a rename or bring back a
    /// removed key.
    private let lock = NSLock()

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
        /// Absent from a file written before renaming existed, which
        /// decodes as `nil`: no name chosen here.
        var customName: String?
    }

    /// Decodes the current shape first; falls back to the shape this file
    /// held before device names existed -- a plain array of base64 keys --
    /// so a store written by an older build still loads, with every key
    /// reading back as having no name. Every name read passes through
    /// `DeviceName.sanitized`, so one written before that rule existed is
    /// shown cleaned. Callers hold `lock`.
    private func readDevices() -> [StoredDevice] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        if let devices = try? JSONDecoder().decode([StoredDevice].self, from: data) {
            return devices.map { device in
                var device = device
                device.name = device.name.flatMap(DeviceName.sanitized)
                device.customName = device.customName.flatMap(DeviceName.sanitized)
                return device
            }
        }
        let legacyKeys = (try? JSONDecoder().decode([String].self, from: data)) ?? []
        return legacyKeys.map { StoredDevice(publicKey: $0, name: nil, customName: nil) }
    }

    /// Callers hold `lock`.
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
        lock.lock()
        defer { lock.unlock() }
        return Set(readDevices().compactMap { Data(base64Encoded: $0.publicKey) })
    }

    public func save(_ keys: Set<Data>) {
        lock.lock()
        defer { lock.unlock() }
        // A name already on disk for a key that is still approved survives
        // a `save(_:)` driven only by the key set, such as the one
        // `HostPairingService` issues right after inserting a new key -- it
        // must not be wiped by a wholly unrelated device pairing.
        let existingDevices = Dictionary(uniqueKeysWithValues: readDevices().map { ($0.publicKey, $0) })
        let devices = keys.map { key -> StoredDevice in
            let encoded = key.base64EncodedString()
            return existingDevices[encoded] ?? StoredDevice(publicKey: encoded, name: nil, customName: nil)
        }
        writeDevices(devices)
    }

    public func remove(_ publicKey: Data) {
        lock.lock()
        defer { lock.unlock() }
        let encoded = publicKey.base64EncodedString()
        let devices = readDevices()
        let remaining = devices.filter { $0.publicKey != encoded }
        guard remaining.count != devices.count else { return }
        writeDevices(remaining)
    }

    public func name(for publicKey: Data) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let encoded = publicKey.base64EncodedString()
        return readDevices().first { $0.publicKey == encoded }?.name
    }

    public func setName(_ name: String?, for publicKey: Data) {
        lock.lock()
        defer { lock.unlock() }
        let encoded = publicKey.base64EncodedString()
        var devices = readDevices()
        guard let index = devices.firstIndex(where: { $0.publicKey == encoded }) else { return }
        devices[index].name = name
        writeDevices(devices)
    }

    public func customName(for publicKey: Data) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let encoded = publicKey.base64EncodedString()
        return readDevices().first { $0.publicKey == encoded }?.customName
    }

    public func setCustomName(_ name: String?, for publicKey: Data) {
        lock.lock()
        defer { lock.unlock() }
        let encoded = publicKey.base64EncodedString()
        var devices = readDevices()
        guard let index = devices.firstIndex(where: { $0.publicKey == encoded }) else { return }
        devices[index].customName = name
        writeDevices(devices)
    }

}

/// The name to show for an approved device: the one the person at this
/// machine chose for it, else the one it reported, else a short fingerprint
/// of its key -- never blank, and never invented. The fingerprint is deliberately not the name recorded
/// alongside an unnamed key; it is derived from the key itself, so it
/// reads the same way every time a caller asks about that key.
public enum ApprovedDeviceDisplayName {
    public static func resolve(for publicKey: Data, in store: any ApprovedDeviceStoring) -> String {
        store.customName(for: publicKey) ?? store.name(for: publicKey) ?? fingerprint(of: publicKey)
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

/// Renaming a paired device from the host window. The chosen name changes
/// only what this machine shows; it is not a credential, and renaming
/// touches neither the device's key nor its arming record.
public enum PairedDeviceName {
    public static let maximumLength = DeviceName.maximumLength

    /// Cleaned by `DeviceName.sanitized`; `nil` when nothing is left, which
    /// means "show the name the device reports".
    public static func normalized(_ typed: String) -> String? {
        DeviceName.sanitized(typed)
    }

    /// Does nothing for a key that is not paired.
    public static func rename(_ publicKey: Data, to typed: String, in store: any ApprovedDeviceStoring) {
        guard store.load().contains(publicKey) else { return }
        store.setCustomName(normalized(typed), for: publicKey)
    }
}

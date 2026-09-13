import Foundation

/// The presence-bound credential a device registered at pairing: its
/// public half, registered with this host when the devices pair. One per
/// device, replaced only by a fresh pairing ceremony, never updated in
/// place by anything on the wire.
///
/// `credentialID` is what a later `hostScreenRequest`'s signed proof
/// references; `publicKey` is what a signature over that proof's challenge
/// is actually checked against -- kept separate because a FIDO2
/// authenticator returns an opaque credential handle, not a raw public
/// key.
///
/// `strength` is the device's own report, shown to the person arming it
/// and never trusted as proof; it changes only when this whole record is
/// replaced by a fresh pairing -- there is no separate call anywhere in
/// this codebase that edits `strength` alone.
public struct PresenceCredentialRecord: Codable, Equatable, Sendable {
    public let credentialID: Data
    public let publicKey: Data
    public let credentialFormat: String
    public let strength: HostScreenCredentialStrength

    public init(credentialID: Data, publicKey: Data, credentialFormat: String, strength: HostScreenCredentialStrength) {
        self.credentialID = credentialID
        self.publicKey = publicKey
        self.credentialFormat = credentialFormat
        self.strength = strength
    }
}

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
    /// The presence-bound credential `publicKey`'s device registered at
    /// pairing, if any. `nil` for a device that registered none -- it may
    /// still pair and use a session canvas -- or one approved by an
    /// earlier version of this store, before this field existed.
    func presenceCredential(for publicKey: Data) -> PresenceCredentialRecord?
    /// Replaces `publicKey`'s registered credential outright -- there is no
    /// partial update. Called from exactly one place in this codebase,
    /// `HostPairingService.handlePairRequest`, so a new credential can only
    /// ever arrive through the pairing ceremony.
    func setPresenceCredential(_ credential: PresenceCredentialRecord?, for publicKey: Data)
}

extension ApprovedDeviceStoring {
    public func remove(_ publicKey: Data) {
        var keys = load()
        keys.remove(publicKey)
        save(keys)
        setName(nil, for: publicKey)
        setPresenceCredential(nil, for: publicKey)
    }
}

public final class InMemoryApprovedDeviceStore: ApprovedDeviceStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: Set<Data>
    private var names: [Data: String] = [:]
    private var presenceCredentials: [Data: PresenceCredentialRecord] = [:]

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

    public func presenceCredential(for publicKey: Data) -> PresenceCredentialRecord? {
        lock.lock()
        defer { lock.unlock() }
        return presenceCredentials[publicKey]
    }

    public func setPresenceCredential(_ credential: PresenceCredentialRecord?, for publicKey: Data) {
        lock.lock()
        defer { lock.unlock() }
        presenceCredentials[publicKey] = credential
    }
}

/// One JSON file at an explicitly supplied URL: an array of each approved
/// key with the name recorded for it, if any.
public final class FileApprovedDeviceStore: ApprovedDeviceStoring, @unchecked Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    private struct StoredDevice: Codable {
        let publicKey: String
        var name: String?
        /// The four fields of a registered `PresenceCredentialRecord`,
        /// base64/raw-string encoded the same way `publicKey` already is.
        /// All four are `nil` together or none are -- `presenceCredential`/
        /// `setPresenceCredential` below are the only things that ever
        /// write them, and both always write or clear the whole set.
        /// Optional, defaulted-by-absence fields: a file written by an
        /// earlier version (this device's own `{publicKey,name}` shape,
        /// or the even older plain-array-of-keys shape) still decodes,
        /// with every device reading back as having registered none.
        var presenceCredentialID: String?
        var presenceCredentialPublicKey: String?
        var presenceCredentialFormat: String?
        var presenceCredentialStrength: String?

        var presenceCredential: PresenceCredentialRecord? {
            guard let idString = presenceCredentialID, let credentialID = Data(base64Encoded: idString),
                  let keyString = presenceCredentialPublicKey, let credentialPublicKey = Data(base64Encoded: keyString),
                  let credentialFormat = presenceCredentialFormat,
                  let strengthString = presenceCredentialStrength,
                  let strength = HostScreenCredentialStrength(rawValue: strengthString) else {
                return nil
            }
            return PresenceCredentialRecord(
                credentialID: credentialID,
                publicKey: credentialPublicKey,
                credentialFormat: credentialFormat,
                strength: strength
            )
        }

        mutating func setPresenceCredential(_ credential: PresenceCredentialRecord?) {
            presenceCredentialID = credential?.credentialID.base64EncodedString()
            presenceCredentialPublicKey = credential?.publicKey.base64EncodedString()
            presenceCredentialFormat = credential?.credentialFormat
            presenceCredentialStrength = credential?.strength.rawValue
        }
    }

    /// Decodes the current shape first; falls back to the shape this file
    /// held before device names existed -- a plain array of base64 keys --
    /// so a store written by an older build still loads, with every key
    /// reading back as having no name and no registered credential.
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
        // Approved keys are not secrets, but a registered presence
        // credential's own public key and format now live in this same
        // file (`StoredDevice.presenceCredential`) -- the same
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
        // A name, and a registered presence credential, already on disk for
        // a key that is still approved both survive a `save(_:)` driven
        // only by the key set, such as the one `HostPairingService` issues
        // right after inserting a new key -- neither must be wiped by a
        // wholly unrelated device pairing.
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

    public func presenceCredential(for publicKey: Data) -> PresenceCredentialRecord? {
        let encoded = publicKey.base64EncodedString()
        return readDevices().first { $0.publicKey == encoded }?.presenceCredential
    }

    public func setPresenceCredential(_ credential: PresenceCredentialRecord?, for publicKey: Data) {
        let encoded = publicKey.base64EncodedString()
        var devices = readDevices()
        if let index = devices.firstIndex(where: { $0.publicKey == encoded }) {
            devices[index].setPresenceCredential(credential)
        } else if credential != nil {
            var device = StoredDevice(publicKey: encoded, name: nil)
            device.setPresenceCredential(credential)
            devices.append(device)
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

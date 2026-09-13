import Foundation
import SensoriumCore

/// Everything needed to reconnect in one action: which machine, and the key it must
/// prove. The canvas is a fixed preset, so there is nothing to choose per session.
public struct SavedHost: Codable, Equatable, Sendable {
    public let displayName: String
    public let host: String
    public let port: UInt16
    public let hostPublicKey: Data
    public let tlsCertificateHash: Data?
    /// The stream scale a person chose for this host, persisted so it
    /// survives relaunch -- see `StreamScalePreference`. `.automatic` for a
    /// host saved before this field existed.
    public let streamScalePreference: StreamScalePreference
    /// When a session with this machine last became live -- the picture, not the
    /// handshake. `nil` for a machine that has been paired but never connected,
    /// and for one saved before this field existed. It is what orders the
    /// launch window's list; see `SavedHostList.presentationOrder(_:)`.
    public let lastConnectedAt: Date?
    /// Which target a session with this machine should try first --
    /// `StartTarget.resolve(preference:lastTarget:rememberedOffer:)`'s own
    /// `preference`. `.hostScreenWhenOffered` for a host saved before this
    /// field existed, which is exactly the fallback-to-canvas behaviour a
    /// machine that has never gone live already had.
    public let startTargetPreference: StartTarget
    /// The target a session with this machine last actually reached and
    /// showed a picture on -- what `.hostScreenWhenOffered` falls back to
    /// when it has no remembered offer of its own. `nil` for a machine that
    /// has never gone live, and for one saved before this field existed.
    /// Stamped the same moment `lastConnectedAt` is; see
    /// `connected(at:liveTarget:)`.
    public let lastLiveTarget: StartTarget?
    /// The most recent canvas connect's own unprompted host-screen offer for
    /// this machine -- what `.hostScreenWhenOffered` connects to directly,
    /// without waiting for a canvas connect to receive the same offer again.
    /// Empty for a machine that has never received one, and for one saved
    /// before this field existed. Written every time a live session
    /// receives an offer, whichever target it is streaming; see
    /// `ClientSessionHost.hostScreenOffered(displays:)`.
    public let rememberedHostScreenOffer: [RememberedHostScreen]

    public init(
        displayName: String,
        host: String,
        port: UInt16,
        hostPublicKey: Data,
        tlsCertificateHash: Data? = nil,
        streamScalePreference: StreamScalePreference = .automatic,
        lastConnectedAt: Date? = nil,
        startTargetPreference: StartTarget = .hostScreenWhenOffered,
        lastLiveTarget: StartTarget? = nil,
        rememberedHostScreenOffer: [RememberedHostScreen] = []
    ) {
        self.displayName = displayName
        self.host = host
        self.port = port
        self.hostPublicKey = hostPublicKey
        self.tlsCertificateHash = tlsCertificateHash
        self.streamScalePreference = streamScalePreference
        self.lastConnectedAt = lastConnectedAt
        self.startTargetPreference = startTargetPreference
        self.lastLiveTarget = lastLiveTarget
        self.rememberedHostScreenOffer = rememberedHostScreenOffer
    }

    private enum CodingKeys: String, CodingKey {
        case displayName, host, port, hostPublicKey, tlsCertificateHash, streamScalePreference
        case lastConnectedAt, startTargetPreference, lastLiveTarget, rememberedHostScreenOffer
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try container.decode(String.self, forKey: .displayName)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decode(UInt16.self, forKey: .port)
        hostPublicKey = try container.decode(Data.self, forKey: .hostPublicKey)
        tlsCertificateHash = try container.decodeIfPresent(Data.self, forKey: .tlsCertificateHash)
        // `decodeIfPresent`, not `decode`: a host saved before this field
        // existed has no key for it at all, and that silently means
        // .automatic rather than a decode failure that would lose the whole
        // saved host.
        streamScalePreference = try container.decodeIfPresent(
            StreamScalePreference.self, forKey: .streamScalePreference
        ) ?? .automatic
        lastConnectedAt = try container.decodeIfPresent(Date.self, forKey: .lastConnectedAt)
        // Same reasoning as `streamScalePreference` above: a host saved
        // before this field existed has no key for it, and that silently
        // means `.hostScreenWhenOffered` rather than a decode failure.
        startTargetPreference = try container.decodeIfPresent(
            StartTarget.self, forKey: .startTargetPreference
        ) ?? .hostScreenWhenOffered
        lastLiveTarget = try container.decodeIfPresent(StartTarget.self, forKey: .lastLiveTarget)
        // Same reasoning again: no key at all silently means no offer ever
        // remembered, not a decode failure.
        rememberedHostScreenOffer = try container.decodeIfPresent(
            [RememberedHostScreen].self, forKey: .rememberedHostScreenOffer
        ) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(hostPublicKey, forKey: .hostPublicKey)
        try container.encodeIfPresent(tlsCertificateHash, forKey: .tlsCertificateHash)
        try container.encode(streamScalePreference, forKey: .streamScalePreference)
        try container.encodeIfPresent(lastConnectedAt, forKey: .lastConnectedAt)
        try container.encode(startTargetPreference, forKey: .startTargetPreference)
        try container.encodeIfPresent(lastLiveTarget, forKey: .lastLiveTarget)
        try container.encode(rememberedHostScreenOffer, forKey: .rememberedHostScreenOffer)
    }

    /// The same machine, stamped with when its picture last came up and which
    /// target that was -- what a `.lastUsed` `startTargetPreference` falls
    /// back to next time. Nothing else about it changes -- the pinned key
    /// and the TLS hash in particular are carried straight over, since this
    /// is written back through the same upsert an ordinary save uses.
    public func connected(at moment: Date, liveTarget: StartTarget) -> SavedHost {
        SavedHost(
            displayName: displayName,
            host: host,
            port: port,
            hostPublicKey: hostPublicKey,
            tlsCertificateHash: tlsCertificateHash,
            streamScalePreference: streamScalePreference,
            lastConnectedAt: moment,
            startTargetPreference: startTargetPreference,
            lastLiveTarget: liveTarget,
            rememberedHostScreenOffer: rememberedHostScreenOffer
        )
    }

    /// The same machine, with a new start-target preference -- the Screen
    /// menu's "Start with" submenu writing back a person's own pick.
    /// Everything else, including `lastLiveTarget`, carries straight over:
    /// choosing where to start next time says nothing about where the
    /// current session actually is.
    public func withStartTargetPreference(_ preference: StartTarget) -> SavedHost {
        SavedHost(
            displayName: displayName,
            host: host,
            port: port,
            hostPublicKey: hostPublicKey,
            tlsCertificateHash: tlsCertificateHash,
            streamScalePreference: streamScalePreference,
            lastConnectedAt: lastConnectedAt,
            startTargetPreference: preference,
            lastLiveTarget: lastLiveTarget,
            rememberedHostScreenOffer: rememberedHostScreenOffer
        )
    }

    /// The same machine, remembering a fresh host-screen offer -- a live
    /// session's own report of what a canvas connect just offered it, so
    /// `.hostScreenWhenOffered` can connect to it directly next time.
    /// Everything else, including `startTargetPreference` itself, carries
    /// straight over: remembering an offer is not choosing to use it.
    public func withRememberedHostScreenOffer(_ offer: [RememberedHostScreen]) -> SavedHost {
        SavedHost(
            displayName: displayName,
            host: host,
            port: port,
            hostPublicKey: hostPublicKey,
            tlsCertificateHash: tlsCertificateHash,
            streamScalePreference: streamScalePreference,
            lastConnectedAt: lastConnectedAt,
            startTargetPreference: startTargetPreference,
            lastLiveTarget: lastLiveTarget,
            rememberedHostScreenOffer: offer
        )
    }

    public struct CanvasPreset: Equatable, Sendable {
        public let logicalWidth: Int
        public let logicalHeight: Int
        public let scale: Int
        public let framesPerSecond: Int
    }

    public static let remoteCanvasPreset = CanvasPreset(
        logicalWidth: 1920,
        logicalHeight: 1200,
        scale: 2,
        framesPerSecond: 60
    )

    /// A deep link is only a selector for an existing paired identity. It never
    /// supplies a port, public key, or certificate pin.
    public func matches(_ entryURL: SensoriumEntryURL) -> Bool {
        host.caseInsensitiveCompare(entryURL.host) == .orderedSame
    }
}

/// The list rules every store shares: which machine a save replaces, and the order
/// the launch window draws them in. Pure, so both stores below behave
/// identically and neither has to be run against a real file to check it.
public enum SavedHostList {
    /// Most recently connected first. A machine paired but never connected has no
    /// date to sort on, so it keeps the order it was saved in, below every machine
    /// that has one -- a stable tiebreak rather than an arbitrary one, so the
    /// list does not reshuffle itself between launches.
    public static func presentationOrder(_ hosts: [SavedHost]) -> [SavedHost] {
        hosts.enumerated()
            .sorted { left, right in
                switch (left.element.lastConnectedAt, right.element.lastConnectedAt) {
                case let (leftDate?, rightDate?):
                    return leftDate == rightDate ? left.offset < right.offset : leftDate > rightDate
                case (.some, .none):
                    return true
                case (.none, .some):
                    return false
                case (.none, .none):
                    return left.offset < right.offset
                }
            }
            .map(\.element)
    }

    /// Identity is the pinned key, never the name or the address: renaming a
    /// machine, or pairing again after it moved to a new address, must land on the
    /// row that is already there rather than adding a second one beside it.
    public static func upserting(_ host: SavedHost, into hosts: [SavedHost]) -> [SavedHost] {
        var result = hosts
        if let existing = result.firstIndex(where: { $0.hostPublicKey == host.hostPublicKey }) {
            result[existing] = host
        } else {
            result.append(host)
        }
        return result
    }

    public static func removing(hostPublicKey: Data, from hosts: [SavedHost]) -> [SavedHost] {
        hosts.filter { $0.hostPublicKey != hostPublicKey }
    }
}

/// How the saved-machines file is read and written, kept apart from the file store
/// itself so the one decision that can lose a pinned key -- what an older
/// file's shape means -- is verified without writing anything.
public enum SavedHostFileCoding {
    /// An array is the current shape. A single JSON object is what a machine that
    /// paired before this file held more than one wrote, and it reads as a
    /// one-element list: treating it as no saved machines would throw away a
    /// pinned key and a TLS certificate hash and ask for a pairing code that
    /// is not needed. Anything else reads as an empty list, which is what an
    /// absent file already means.
    public static func decode(_ data: Data) -> [SavedHost] {
        let decoder = JSONDecoder()
        if let list = try? decoder.decode([SavedHost].self, from: data) {
            return list
        }
        if let single = try? decoder.decode(SavedHost.self, from: data) {
            return [single]
        }
        return []
    }

    public static func encode(_ hosts: [SavedHost]) -> Data? {
        try? JSONEncoder().encode(hosts)
    }
}

/// Every machine this one has paired with. A store is a list because a person owns
/// more than one machine; which of them a session dials is their own choice on the
/// launch window, never this type's.
public protocol SavedHostStoring: Sendable {
    /// Every saved machine, already in `SavedHostList.presentationOrder`.
    func loadAll() -> [SavedHost]
    /// Adds this machine, or replaces the entry that pins the same key.
    func save(_ host: SavedHost)
    /// Forgets exactly one machine. Every other saved machine is untouched.
    func remove(hostPublicKey: Data)
    /// Forgets every saved machine at once. Reached only when this machine's own
    /// identity is replaced, which makes every pairing it holds worthless.
    func clear()
}

public extension SavedHostStoring {
    /// One saved machine by the key it pins, for the callers that already know
    /// which machine they are talking about -- a live session writing its own
    /// stream-scale choice back, for one.
    func load(hostPublicKey: Data) -> SavedHost? {
        loadAll().first { $0.hostPublicKey == hostPublicKey }
    }

    /// Records that this machine connected, reading the stored record first. A
    /// session holds the machine it started from, and anything written while it
    /// ran -- a resolution chosen from the Display menu, for one -- is on the
    /// stored record and not on that copy; stamping the copy would put the
    /// choice back the way it was. A machine no longer held here is not written.
    func stampConnected(hostPublicKey: Data, at moment: Date, liveTarget: StartTarget) {
        guard let stored = load(hostPublicKey: hostPublicKey) else { return }
        save(stored.connected(at: moment, liveTarget: liveTarget))
    }

    /// Records a person's own "Start with" pick, reading the stored record
    /// first for the same reason `stampConnected` does: a live session holds
    /// the machine it started from, and this write must land on whatever the
    /// store holds now, not overwrite it with a stale copy.
    func setStartTargetPreference(hostPublicKey: Data, to preference: StartTarget) {
        guard let stored = load(hostPublicKey: hostPublicKey) else { return }
        save(stored.withStartTargetPreference(preference))
    }

    /// Records a live session's own report of a fresh host-screen offer,
    /// reading the stored record first for the same reason `stampConnected`
    /// does. A machine no longer held here is not written.
    func rememberHostScreenOffer(hostPublicKey: Data, offer: [RememberedHostScreen]) {
        guard let stored = load(hostPublicKey: hostPublicKey) else { return }
        save(stored.withRememberedHostScreenOffer(offer))
    }
}

public final class InMemorySavedHostStore: SavedHostStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var hosts: [SavedHost]

    public init(hosts: [SavedHost] = []) {
        self.hosts = hosts
    }

    public func loadAll() -> [SavedHost] {
        lock.lock()
        defer { lock.unlock() }
        return SavedHostList.presentationOrder(hosts)
    }

    public func save(_ host: SavedHost) {
        lock.lock()
        defer { lock.unlock() }
        hosts = SavedHostList.upserting(host, into: hosts)
    }

    public func remove(hostPublicKey: Data) {
        lock.lock()
        defer { lock.unlock() }
        hosts = SavedHostList.removing(hostPublicKey: hostPublicKey, from: hosts)
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        hosts = []
    }
}

/// Writes one JSON file at an explicitly supplied URL. No test executes this: it
/// would write outside the repository. What it writes and what an older file
/// means are `SavedHostFileCoding`'s decisions, which are verified.
public final class FileSavedHostStore: SavedHostStoring, @unchecked Sendable {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func loadAll() -> [SavedHost] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        return SavedHostList.presentationOrder(SavedHostFileCoding.decode(data))
    }

    /// Reads the file, upserts, and writes the whole list back -- which is
    /// also what rewrites a single-object file from before this store held a
    /// list into the list shape, the first time anything is saved.
    public func save(_ host: SavedHost) {
        write(SavedHostList.upserting(host, into: stored()))
    }

    public func remove(hostPublicKey: Data) {
        write(SavedHostList.removing(hostPublicKey: hostPublicKey, from: stored()))
    }

    public func clear() {
        try? FileManager.default.removeItem(at: url)
    }

    private func stored() -> [SavedHost] {
        guard let data = try? Data(contentsOf: url) else {
            return []
        }
        return SavedHostFileCoding.decode(data)
    }

    private func write(_ hosts: [SavedHost]) {
        guard let data = SavedHostFileCoding.encode(hosts) else {
            return
        }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: [.atomic])
    }
}

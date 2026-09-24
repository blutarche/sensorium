#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// One device on the tailnet, as the viewer's device picker will render it.
/// Built from `tailscale status --json`'s `Self` and `Peer` entries, both
/// through the same parsing and the same validation -- a malformed `Self`
/// is dropped exactly as a malformed peer would be, not trusted just
/// because it names this machine.
public struct TailnetPeer: Equatable, Sendable {
    /// Tailscale's own stable node identifier (`ID` in the JSON). Survives a
    /// rename or a re-key, unlike the display name or the addresses below.
    public let id: String
    /// The name a person recognises (`HostName`): what the picker shows.
    public let displayName: String
    /// The MagicDNS name (`DNSName`), when the tailnet has one assigned.
    /// `nil` rather than empty when absent, so a caller never has to treat
    /// an empty string as a real value.
    public let magicDNSName: String?
    /// This peer's address in Tailscale's CGNAT range, when it has one.
    public let tailnetIPv4: String?
    /// This peer's address in Tailscale's ULA range, when it has one.
    public let tailnetIPv6: String?
    public let isOnline: Bool
    /// Whether this entry came from the JSON's `Self` object rather than its
    /// `Peer` map. Carried on the value rather than only used to decide
    /// membership, so a caller other than the picker's own presentation
    /// order can still tell the two apart.
    public let isThisMachine: Bool

    public init(
        id: String,
        displayName: String,
        magicDNSName: String?,
        tailnetIPv4: String?,
        tailnetIPv6: String?,
        isOnline: Bool,
        isThisMachine: Bool
    ) {
        self.id = id
        self.displayName = displayName
        self.magicDNSName = magicDNSName
        self.tailnetIPv4 = tailnetIPv4
        self.tailnetIPv6 = tailnetIPv6
        self.isOnline = isOnline
        self.isThisMachine = isThisMachine
    }

    /// The address a dial actually connects with. Prefers the tailnet IPv4
    /// address before the MagicDNS name before the tailnet IPv6 address: a
    /// dial of this peer's IPv4 address reaches this host's TLS handshake,
    /// while a dial of its MagicDNS name reports unreachable instead -- a
    /// name may resolve to an address this host does not answer on. The device picker is the one
    /// place that turns a picked peer into a dial target; the address it
    /// chooses here is what gets saved and redialed on later reconnects.
    public var dialAddress: String {
        tailnetIPv4 ?? magicDNSName ?? tailnetIPv6 ?? ""
    }
}

/// What one parse of a tailscale status document produced: every peer this
/// parser could understand, plus how many it could not -- so a caller can
/// tell "an empty tailnet" (zero peers, zero dropped) apart from "something
/// in this status is malformed" (fewer peers than expected, some dropped)
/// without inspecting the peer list itself.
public struct TailnetDirectorySnapshot: Equatable, Sendable {
    public let peers: [TailnetPeer]
    public let droppedPeerCount: Int

    public init(peers: [TailnetPeer], droppedPeerCount: Int) {
        self.peers = peers
        self.droppedPeerCount = droppedPeerCount
    }
}

/// Only for input this parser cannot treat as a tailscale status document at
/// all -- not merely a document missing or misshaping the parts it wants,
/// which degrades to fewer peers and a higher `droppedPeerCount` instead.
public enum TailnetDirectoryError: Error, Equatable {
    /// The bytes are not valid JSON.
    case invalidJSON
    /// The JSON parsed, but its top level is not an object -- an array, a
    /// string, a number: not a shape `tailscale status --json` ever produces.
    case unexpectedTopLevelShape
}

/// Parses `tailscale status --json` into the model the device picker reads,
/// and orders that model for presentation. No socket, no subprocess, no
/// knowledge of how the bytes were obtained -- see `TailnetStatusProviding`
/// for that seam.
public enum TailnetDirectory {
    /// Tailscale's CGNAT range, 100.64.0.0/10: first octet 100, second
    /// octet 64 through 127.
    private static let ipv4SecondOctetRange: ClosedRange<UInt8> = 64...127
    /// Tailscale's ULA range, fd7a:115c:a1e0::/48, as its first six bytes.
    private static let ipv6Prefix: [UInt8] = [0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0]

    /// `true` when `address` parses as a real IPv4 address inside
    /// Tailscale's CGNAT range. Uses `inet_pton` rather than a string check:
    /// a textually-plausible but out-of-range or malformed value (an IPv6
    /// literal in an IPv4-shaped string, extra octets, leading zeros a real
    /// parser would refuse) must read as absent, not as a wrong address.
    private static func isTailnetIPv4(_ address: String) -> Bool {
        var v4 = in_addr()
        guard inet_pton(AF_INET, address, &v4) == 1 else { return false }
        let octets = withUnsafeBytes(of: v4.s_addr) { Array($0) }
        return octets[0] == 100 && ipv4SecondOctetRange.contains(octets[1])
    }

    private static func isTailnetIPv6(_ address: String) -> Bool {
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        return Array(bytes.prefix(ipv6Prefix.count)) == ipv6Prefix
    }

    /// `tailscale status --json` emits `DNSName` fully qualified, with a
    /// trailing dot (`example-host.tail1234.ts.net.`) -- valid DNS, but not a name
    /// anything past this parser should store or dial with the dot still
    /// on it. Drops exactly one trailing dot; an empty or all-dot result
    /// reads as absent, the same as a missing `DNSName`.
    private static func canonicalizedMagicDNSName(_ dnsName: String?) -> String? {
        guard var name = dnsName, !name.isEmpty else { return nil }
        if name.hasSuffix(".") {
            name.removeLast()
        }
        return name.isEmpty ? nil : name
    }

    /// One JSON object (`Self`, or one value in `Peer`) into a `TailnetPeer`,
    /// or `nil` when it cannot be understood as one. Every field beyond `ID`,
    /// `HostName`, and at least one valid tailnet address is optional and
    /// defaults rather than fails: an unknown key is ignored, and a missing
    /// or wrongly-typed optional field reads as absent, never as a reason to
    /// drop the whole peer.
    private static func peer(from raw: Any, isThisMachine: Bool) -> TailnetPeer? {
        guard let object = raw as? [String: Any] else { return nil }
        guard let id = object["ID"] as? String, !id.isEmpty else { return nil }
        guard let hostName = object["HostName"] as? String, !hostName.isEmpty else { return nil }

        let magicDNSName = Self.canonicalizedMagicDNSName(object["DNSName"] as? String)

        let addresses = (object["TailscaleIPs"] as? [Any])?.compactMap { $0 as? String } ?? []
        let ipv4 = addresses.first(where: isTailnetIPv4)
        let ipv6 = addresses.first(where: isTailnetIPv6)
        // A peer with neither address is one nothing here could ever dial:
        // dropped the same as a peer this parser could not read at all.
        guard ipv4 != nil || ipv6 != nil else { return nil }

        let isOnline = object["Online"] as? Bool ?? false

        return TailnetPeer(
            id: id,
            displayName: hostName,
            magicDNSName: magicDNSName,
            tailnetIPv4: ipv4,
            tailnetIPv6: ipv6,
            isOnline: isOnline,
            isThisMachine: isThisMachine
        )
    }

    /// Parses `statusJSON` into every peer this parser could understand.
    /// Throws only when the bytes are not usable as a tailscale status
    /// document at all (`TailnetDirectoryError`); a document that parses but
    /// is missing or misshapes `Self` or individual `Peer` entries degrades
    /// to fewer peers and a higher `droppedPeerCount` instead of throwing,
    /// because one malformed entry must not empty the whole list.
    public static func parse(statusJSON: Data) throws -> TailnetDirectorySnapshot {
        let rawTopLevel: Any
        do {
            rawTopLevel = try JSONSerialization.jsonObject(with: statusJSON, options: [])
        } catch {
            throw TailnetDirectoryError.invalidJSON
        }
        guard let topLevel = rawTopLevel as? [String: Any] else {
            throw TailnetDirectoryError.unexpectedTopLevelShape
        }

        var peers: [TailnetPeer] = []
        var droppedPeerCount = 0

        if let selfRaw = topLevel["Self"] {
            if let selfPeer = peer(from: selfRaw, isThisMachine: true) {
                peers.append(selfPeer)
            } else {
                droppedPeerCount += 1
            }
        }

        // A missing or wrongly-shaped `Peer` map reads as zero peers from
        // it, the same as an empty one: an empty or still-connecting
        // tailnet looks exactly like this, and it is not this parser's job
        // to tell that apart from a status document it cannot fully read.
        if let peerMap = topLevel["Peer"] as? [String: Any] {
            // Sorted by key rather than iterated in whatever order
            // `JSONSerialization` happens to produce, so two parses of the
            // same bytes always keep and drop peers in the same order.
            for key in peerMap.keys.sorted() {
                guard let raw = peerMap[key] else { continue }
                if let parsed = peer(from: raw, isThisMachine: false) {
                    peers.append(parsed)
                } else {
                    droppedPeerCount += 1
                }
            }
        }

        return TailnetDirectorySnapshot(peers: peers, droppedPeerCount: droppedPeerCount)
    }

    /// Ordered for the device picker: this machine never appears (it is
    /// where the picker itself is running, not a target to choose), online
    /// devices before offline ones -- only an online device can be dialed at
    /// all right now -- then case-insensitive by display name within each
    /// group, so "iPhone" and "iphone" interleave the way a person reading
    /// the list expects rather than splitting on ASCII case.
    public static func presentationOrder(_ peers: [TailnetPeer]) -> [TailnetPeer] {
        peers
            .filter { !$0.isThisMachine }
            .sorted { lhs, rhs in
                if lhs.isOnline != rhs.isOnline {
                    return lhs.isOnline
                }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
    }
}

/// The seam between bytes that describe the tailnet and how they were
/// obtained, so parsing is verifiable against fixtures with no socket or
/// subprocess.
public protocol TailnetStatusProviding: Sendable {
    func statusJSON() async throws -> Data
}

/// A `TailnetStatusProviding` backed by bytes fixed at construction, for
/// tests and for anything else that wants deterministic status data with no
/// tailnet, socket, or subprocess involved.
public struct FixtureTailnetStatusProvider: TailnetStatusProviding {
    private let json: Data

    public init(json: Data) {
        self.json = json
    }

    public func statusJSON() async throws -> Data {
        json
    }
}

import Foundation
import SensoriumCore

/// Every fixture below is invented: names and addresses that read as
/// synthetic, inside the two ranges `tailscale status --json`
/// actually uses (100.64.0.0/10, fd7a:115c:a1e0::/48) but never anyone's
/// real device or tailnet.
func testTailnetDirectoryParsesAndSortsPeers() {
    // A normal multi-peer status
    let normalJSON = Data("""
    {
      "Self": {
        "ID": "nSELF00000001",
        "HostName": "workshop-mini",
        "DNSName": "workshop-mini.tail-example.ts.net.",
        "TailscaleIPs": ["100.100.0.1", "fd7a:115c:a1e0::1"],
        "Online": true
      },
      "Peer": {
        "nodekey:aaa": {
          "ID": "nPEERAAA0001",
          "HostName": "Skylark",
          "DNSName": "skylark.tail-example.ts.net.",
          "TailscaleIPs": ["100.100.0.2", "fd7a:115c:a1e0::2"],
          "Online": true
        },
        "nodekey:bbb": {
          "ID": "nPEERBBB0002",
          "HostName": "anchovy-nas",
          "DNSName": "anchovy-nas.tail-example.ts.net.",
          "TailscaleIPs": ["100.100.0.3"],
          "Online": false
        },
        "nodekey:ccc": {
          "ID": "nPEERCCC0003",
          "HostName": "ZEBRA-station",
          "TailscaleIPs": ["fd7a:115c:a1e0::4"],
          "Online": true
        },
        "nodekey:ddd": {
          "ID": "nPEERDDD0004",
          "HostName": "corvid",
          "TailscaleIPs": ["100.100.0.5", "fd7a:115c:a1e0::5"],
          "Online": true
        }
      }
    }
    """.utf8)

    let normalSnapshot = try! TailnetDirectory.parse(statusJSON: normalJSON)
    expect(normalSnapshot.droppedPeerCount == 0, "a well-formed status with every field present drops nothing")
    expect(normalSnapshot.peers.count == 5, "self plus four real peers is five parsed entries")
    expect(
        normalSnapshot.peers.contains { $0.isThisMachine && $0.displayName == "workshop-mini" },
        "the Self object parses into a peer flagged as this machine"
    )
    let skylark = normalSnapshot.peers.first { $0.displayName == "Skylark" }
    expect(
        skylark?.magicDNSName == "skylark.tail-example.ts.net"
            && skylark?.tailnetIPv4 == "100.100.0.2"
            && skylark?.tailnetIPv6 == "fd7a:115c:a1e0::2"
            && skylark?.isOnline == true
            && skylark?.isThisMachine == false,
        "every field reaches the model: id, display name, MagicDNS name, both addresses, online, and not-this-machine"
    )
    let zebra = normalSnapshot.peers.first { $0.displayName == "ZEBRA-station" }
    expect(zebra?.magicDNSName == nil, "a peer with no DNSName in the JSON reports no MagicDNS name, not an empty string")
    expect(zebra?.tailnetIPv4 == nil && zebra?.tailnetIPv6 == "fd7a:115c:a1e0::4", "a peer with only an IPv6 address carries only that address")

    // `tailscale status --json` emits DNSName fully qualified
    let trailingDotJSON = Data("""
    {
      "Self": {
        "ID": "nSELF00000002",
        "HostName": "mini",
        "DNSName": "mini.tail1234.ts.net.",
        "TailscaleIPs": ["100.100.0.9"],
        "Online": true
      },
      "Peer": {}
    }
    """.utf8)
    let trailingDotSnapshot = try! TailnetDirectory.parse(statusJSON: trailingDotJSON)
    expect(
        trailingDotSnapshot.peers.first?.magicDNSName == "mini.tail1234.ts.net",
        "the fully-qualified DNSName tailscale emits loses exactly its trailing dot, not the name itself"
    )

    // Sort order, including self-exclusion
    let ordered = TailnetDirectory.presentationOrder(normalSnapshot.peers)
    expect(!ordered.contains { $0.isThisMachine }, "this machine never appears in the presented list")
    expect(
        ordered.map(\.displayName) == ["corvid", "Skylark", "ZEBRA-station", "anchovy-nas"],
        "online devices sort before offline, then case-insensitive by display name within each group"
    )

    // A peer missing its addresses, a peer with garbage in one
    // field, and every other way a single entry can fail to parse
    let malformedJSON = Data("""
    {
      "Self": {
        "ID": "nSELF00000001",
        "HostName": "workshop-mini",
        "TailscaleIPs": ["100.100.0.1"],
        "Online": true
      },
      "Peer": {
        "a-good": {
          "ID": "nGOOD00000001",
          "HostName": "good-peer",
          "TailscaleIPs": ["100.100.0.9"],
          "Online": true
        },
        "b-no-address": {
          "ID": "nNOADDR0001",
          "HostName": "no-address-peer",
          "TailscaleIPs": [],
          "Online": true
        },
        "c-garbage-address": {
          "ID": "nGARBAGE0001",
          "HostName": "garbage-address-peer",
          "TailscaleIPs": ["not-an-ip", "999.999.999.999"],
          "Online": true
        },
        "d-missing-id": {
          "HostName": "missing-id-peer",
          "TailscaleIPs": ["100.100.0.10"],
          "Online": true
        },
        "e-empty-hostname": {
          "ID": "nEMPTYHOST01",
          "HostName": "",
          "TailscaleIPs": ["100.100.0.11"],
          "Online": true
        },
        "f-not-an-object": "just a string, not a peer object",
        "g-address-out-of-tailnet-range": {
          "ID": "nOUTOFRANGE1",
          "HostName": "out-of-range-peer",
          "TailscaleIPs": ["10.0.0.5"],
          "Online": true
        }
      }
    }
    """.utf8)

    let malformedSnapshot = try! TailnetDirectory.parse(statusJSON: malformedJSON)
    expect(
        malformedSnapshot.peers.map(\.displayName).sorted() == ["good-peer", "workshop-mini"],
        "only the Self object and the one genuinely well-formed peer survive"
    )
    expect(
        malformedSnapshot.droppedPeerCount == 6,
        "one malformed peer must not empty the whole list: six broken entries are dropped and counted, not thrown"
    )

    // An empty tailnet
    let emptyPeerMapJSON = Data("""
    {
      "Self": {"ID": "nSELF00000001", "HostName": "workshop-mini", "TailscaleIPs": ["100.100.0.1"], "Online": true},
      "Peer": {}
    }
    """.utf8)
    let emptyPeerMapSnapshot = try! TailnetDirectory.parse(statusJSON: emptyPeerMapJSON)
    expect(
        emptyPeerMapSnapshot.peers.count == 1 && emptyPeerMapSnapshot.droppedPeerCount == 0,
        "an empty Peer map parses to just this machine, dropping nothing -- an empty tailnet is not an error"
    )
    expect(
        TailnetDirectory.presentationOrder(emptyPeerMapSnapshot.peers).isEmpty,
        "with no real peers, the presented list is empty rather than showing this machine"
    )

    let missingPeerKeyJSON = Data("""
    {"Self": {"ID": "nSELF00000001", "HostName": "workshop-mini", "TailscaleIPs": ["100.100.0.1"], "Online": true}}
    """.utf8)
    let missingPeerKeySnapshot = try! TailnetDirectory.parse(statusJSON: missingPeerKeyJSON)
    expect(
        missingPeerKeySnapshot.peers.count == 1 && missingPeerKeySnapshot.droppedPeerCount == 0,
        "a status document with no Peer key at all is tolerated the same as an empty one"
    )

    // Not a tailscale status document at all
    expect(
        (try? TailnetDirectory.parse(statusJSON: Data("not json at all".utf8))) == nil,
        "bytes that are not valid JSON throw rather than silently returning nothing"
    )
    expect(
        (try? TailnetDirectory.parse(statusJSON: Data("[1, 2, 3]".utf8))) == nil,
        "valid JSON whose top level is not an object throws rather than pretending it found zero peers"
    )
    do {
        _ = try TailnetDirectory.parse(statusJSON: Data("not json at all".utf8))
        expect(false, "the invalid-JSON case above must actually throw")
    } catch TailnetDirectoryError.invalidJSON {
        // expected
    } catch {
        expect(false, "invalid JSON throws TailnetDirectoryError.invalidJSON specifically, not some other error")
    }

    // The transport seam
    let fixtureProvider = FixtureTailnetStatusProvider(json: normalJSON)
    let providedJSON = { () -> Data in
        let box = LockedBox<Data>()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            box.value = try? await fixtureProvider.statusJSON()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value ?? Data()
    }()
    expect(providedJSON == normalJSON, "a fixture-backed provider returns exactly the bytes it was given, unmodified")
}

/// `TailnetPeer.dialAddress` picks the address a dial actually connects
/// with, not the address the picker's subtitle shows a person. It must
/// prefer the tailnet IPv4 address before either the MagicDNS name or the
/// tailnet IPv6 address: this host's TLS listener only ever binds an IPv4
/// socket, so a name that resolves to the peer's IPv6 ULA address first (or
/// an IPv6 address dialed directly) reaches nothing and stalls until the
/// dial times out, even though the same peer's IPv4 address connects.
func testTailnetPeerDialAddressPrefersIPv4ThenMagicDNSNameThenIPv6() {
    func peer(magicDNSName: String?, tailnetIPv4: String?, tailnetIPv6: String?) -> TailnetPeer {
        TailnetPeer(
            id: "n1",
            displayName: "some-machine",
            magicDNSName: magicDNSName,
            tailnetIPv4: tailnetIPv4,
            tailnetIPv6: tailnetIPv6,
            isOnline: true,
            isThisMachine: false
        )
    }

    let allThree = peer(
        magicDNSName: "mini.tail-example.ts.net",
        tailnetIPv4: "100.100.0.2",
        tailnetIPv6: "fd7a:115c:a1e0::2"
    )
    expect(
        allThree.dialAddress == "100.100.0.2",
        "a peer with all three addresses dials its tailnet IPv4 address, never the name or the IPv6 address"
    )

    let nameAndIPv6Only = peer(magicDNSName: "mini.tail-example.ts.net", tailnetIPv4: nil, tailnetIPv6: "fd7a:115c:a1e0::2")
    expect(
        nameAndIPv6Only.dialAddress == "mini.tail-example.ts.net",
        "with no tailnet IPv4 address, the MagicDNS name is dialed before the IPv6 address"
    )

    let ipv6Only = peer(magicDNSName: nil, tailnetIPv4: nil, tailnetIPv6: "fd7a:115c:a1e0::2")
    expect(
        ipv6Only.dialAddress == "fd7a:115c:a1e0::2",
        "with neither an IPv4 address nor a MagicDNS name, the IPv6 address is the only address left to dial"
    )

    let none = peer(magicDNSName: nil, tailnetIPv4: nil, tailnetIPv6: nil)
    expect(none.dialAddress == "", "a peer with no address at all yields an empty dial address, not a crash")
}

/// Carries an async result back out to a synchronous `wait()`, for a test
/// runner with no async entry point of its own.
private final class LockedBox<Value>: @unchecked Sendable {
    var value: Value?
}

import Foundation
import Network
import SensoriumCore
import SensoriumHost

/// "Allow connections from this network" admits a source on the same subnet
/// as one of this Mac's own non-tailnet interfaces, and nothing else beyond
/// the tailnet. Off, admission is exactly the tailnet rule.
func runHostLocalNetworkAdmissionTests() {
    let homeV4 = LocalSubnet(address: "192.0.2.10", netmask: "255.255.255.0")!
    let homeV6 = LocalSubnet(address: "2001:db8:1:2::10", netmask: "ffff:ffff:ffff:ffff::")!
    let linkLocal = LocalSubnet(address: "fe80::1c2b:3cff:fe4d:5e6f%en0", netmask: "ffff:ffff:ffff:ffff::")!
    let subnets = [homeV4, homeV6, linkLocal]

    do {
        expect(
            SourceAddressPolicy.isOnLinkSource("192.0.2.45", interfaces: subnets),
            "a source in this Mac's own IPv4 /24 is on-link"
        )
        expect(
            SourceAddressPolicy.isOnLinkSource("2001:db8:1:2::99", interfaces: subnets),
            "a source in this Mac's own global IPv6 /64 is on-link"
        )
        expect(
            SourceAddressPolicy.isOnLinkSource("fe80::aa:bbff:fecc:ddee%en0", interfaces: subnets),
            "a link-local source with a scope is on-link"
        )
        expect(
            !SourceAddressPolicy.isOnLinkSource("198.51.100.7", interfaces: subnets),
            "a private-looking source on another subnet is not on-link"
        )
        expect(
            !SourceAddressPolicy.isOnLinkSource("2001:db8:1:3::99", interfaces: subnets),
            "an IPv6 source on the neighbouring /64 is not on-link"
        )
        expect(
            !SourceAddressPolicy.isOnLinkSource("203.0.113.9", interfaces: subnets),
            "a routed public source is not on-link"
        )
        expect(
            !SourceAddressPolicy.isOnLinkSource("192.0.2.45", interfaces: []),
            "with no local interfaces nothing is on-link"
        )
        expect(
            !SourceAddressPolicy.isOnLinkSource("not an address", interfaces: subnets),
            "an unreadable source is not on-link"
        )
        print("PASS: the on-link classifier admits only this Mac's own subnets, IPv4, IPv6 and link-local")
    }

    do {
        // How the kernel hands back a link-local interface address: the
        // interface index (here 4) sits in bytes 2 and 3.
        var kernelForm: [UInt8] = [0xfe, 0x80, 0x00, 0x04] + Array(repeating: 0, count: 12)
        kernelForm[15] = 0x01
        let mask: [UInt8] = Array(repeating: 0xff, count: 8) + Array(repeating: 0, count: 8)
        let subnet = LocalSubnet(address: kernelForm, mask: mask)!
        expect(
            SourceAddressPolicy.isOnLinkSource("fe80::aa:bbff:fecc:ddee%en0", interfaces: [subnet]),
            "a link-local interface address in the kernel's scope-embedded form still matches a link-local source"
        )
        let current = LocalSubnetEnumerator.current()
        for loopback in ["127.0.0.1", "::1"] {
            expect(
                !SourceAddressPolicy.isOnLinkSource(loopback, interfaces: current),
                "this Mac's own interface list never makes \(loopback) on-link"
            )
        }
        print("PASS: link-local interface addresses compare without the kernel's embedded scope, and loopback is never on-link")
    }

    do {
        let sources = ["192.0.2.45", "2001:db8:1:2::99", "fe80::aa:bbff:fecc:ddee%en0"]
        for source in sources {
            expect(
                !HostConnectionAdmission.admits(
                    sourceHost: source, transport: .quic, allowLocalNetwork: false, localSubnets: subnets
                ),
                "with the setting off, the on-link source \(source) is refused"
            )
            expect(
                HostConnectionAdmission.admits(
                    sourceHost: source, transport: .quic, allowLocalNetwork: true, localSubnets: subnets
                ),
                "with the setting on, the on-link source \(source) is admitted"
            )
        }
        for source in ["198.51.100.7", "203.0.113.9", "127.0.0.1", "::1"] {
            expect(
                !HostConnectionAdmission.admits(
                    sourceHost: source, transport: .quic, allowLocalNetwork: true, localSubnets: subnets
                ),
                "with the setting on, \(source) is still refused"
            )
        }
        for allow in [false, true] {
            expect(
                HostConnectionAdmission.admits(
                    sourceHost: "100.64.1.4", transport: .quic, allowLocalNetwork: allow, localSubnets: subnets
                ),
                "a tailnet source is admitted with the setting \(allow ? "on" : "off")"
            )
        }
        expect(
            HostConnectionAdmission.admits(
                endpoint: .hostPort(host: "192.0.2.45", port: 7777),
                transport: .quic,
                allowLocalNetwork: true,
                localSubnets: subnets
            ),
            "an endpoint on this Mac's own subnet is admitted with the setting on"
        )
        print("PASS: admission takes this network's sources only while the setting is on, and the tailnet always")
    }
}

/// The QUIC listener is on every interface only while the setting is on, and
/// scoped to the tailnet interface while it is off.
func runHostLocalNetworkListenerParameterTests() {
    let tlsIdentity = try! HostTLSIdentity.generate(commonName: "Sensorium Host")
    let unscoped = try! HostNetworkListener.parameters(
        boundToTailnetAddress: "100.64.1.4",
        tlsIdentity: tlsIdentity,
        allowsLocalNetwork: true
    )
    expect(unscoped.requiredInterface == nil, "with the setting on, the listener is not scoped to any interface")
    expect(unscoped.requiredLocalEndpoint == nil, "with the setting on, the listener pins no local endpoint")
    expect(
        unscoped.defaultProtocolStack.transportProtocol is NWProtocolQUIC.Options,
        "with the setting on, the listener is still QUIC"
    )

    let scoped = try! HostNetworkListener.parameters(
        boundToTailnetAddress: "100.64.1.4",
        tlsIdentity: tlsIdentity,
        allowsLocalNetwork: false
    )
    expect(
        scoped.requiredInterface != nil || !TailnetInterfaceLocator.isAvailable(address: "100.64.1.4"),
        "with the setting off, the listener is scoped to the interface that owns the tailnet address"
    )

    do {
        _ = try HostNetworkListener.parameters(
            boundToTailnetAddress: "192.0.2.10",
            tlsIdentity: tlsIdentity,
            allowsLocalNetwork: true
        )
        expect(false, "with the setting on, a non-tailnet bind address is still refused")
    } catch {
        expect(
            error as? HostNetworkListenerError == .nonTailnetBindAddress,
            "with the setting on, a non-tailnet bind address is still refused, got \(error)"
        )
    }
    print("PASS: the listener is unscoped only while the setting is on, and still needs a tailnet address")
}

import SensoriumCore
import SensoriumClient
import Foundation
import Network
import Security

// Diagnostic-only QUIC binding harness. Binds a real listener on the
// Sensorium port, so it requires an explicit opt-in and never runs from any
// script or test.
let usage = """
usage: SensoriumQuicProbe --run <variant>
variants: requiredLocalEndpoint, requiredInterface, hostOnlyEndpoint,
hostOnlyReuse, fullEndpointReuse, ifaceLoopback, pinMatch, pinMismatch,
unconstrained, unconstrainedLoopback, reuse7777, ifaceBoth, ifaceClientLocal
"""
let arguments = CommandLine.arguments
guard let runIndex = arguments.firstIndex(of: "--run") else {
    print(usage)
    exit(1)
}
let environment = ProcessInfo.processInfo.environment
let address = environment["SENSORIUM_PROBE_TAILNET_HOST"] ?? "probe-host.example"
let interfaceName = environment["SENSORIUM_PROBE_TAILNET_INTERFACE"] ?? "utun4"
let port = NWEndpoint.Port(rawValue: 7777)!
let alpn = "com.sensorium.control-v1"
let variant = arguments.count > runIndex + 1 ? arguments[runIndex + 1] : "requiredLocalEndpoint"

setvbuf(stdout, nil, _IOLBF, 0)
let log: @Sendable (String) -> Void = { print("  \($0)") }

let identity = try HostTLSIdentity.generate(commonName: "Sensorium Probe")

func quicOptions(verifyAny: Bool) -> NWProtocolQUIC.Options {
    let quic = NWProtocolQUIC.Options()
    sec_protocol_options_add_tls_application_protocol(quic.securityProtocolOptions, alpn)
    if verifyAny {
        sec_protocol_options_set_verify_block(
            quic.securityProtocolOptions,
            { _, _, complete in complete(true) },
            DispatchQueue(label: "probe.verify")
        )
    }
    return quic
}

final class InterfaceBox: @unchecked Sendable {
    var value: NWInterface?
}

func tailnetInterface() -> NWInterface? {
    let monitor = NWPathMonitor()
    let ready = DispatchSemaphore(value: 0)
    let box = InterfaceBox()
    monitor.pathUpdateHandler = { path in
        box.value = path.availableInterfaces.first { $0.name == interfaceName }
        ready.signal()
    }
    monitor.start(queue: .global())
    _ = ready.wait(timeout: .now() + 2)
    monitor.cancel()
    return box.value
}

var listener: NWListener
switch variant {
case "requiredLocalEndpoint":
    let p = NWParameters(quic: quicOptions(verifyAny: false))
    sec_protocol_options_set_local_identity(
        p.defaultProtocolStack.applicationProtocols.compactMap { $0 as? NWProtocolQUIC.Options }.first!.securityProtocolOptions,
        sec_identity_create(try identity.makeSecIdentity())!
    )
    p.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
    listener = try NWListener(using: p)
case "requiredInterface":
    let quic = quicOptions(verifyAny: false)
    sec_protocol_options_set_local_identity(quic.securityProtocolOptions, sec_identity_create(try identity.makeSecIdentity())!)
    let p = NWParameters(quic: quic)
    guard let iface = tailnetInterface() else { fatalError("no \(interfaceName)") }
    p.requiredInterface = iface
    listener = try NWListener(using: p, on: port)
case "hostOnlyEndpoint":
    let quic = quicOptions(verifyAny: false)
    sec_protocol_options_set_local_identity(quic.securityProtocolOptions, sec_identity_create(try identity.makeSecIdentity())!)
    let p = NWParameters(quic: quic)
    p.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
    listener = try NWListener(using: p, on: port)
case "hostOnlyReuse":
    let quic = quicOptions(verifyAny: false)
    sec_protocol_options_set_local_identity(quic.securityProtocolOptions, sec_identity_create(try identity.makeSecIdentity())!)
    let p = NWParameters(quic: quic)
    p.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
    p.allowLocalEndpointReuse = true
    listener = try NWListener(using: p, on: port)
case "fullEndpointReuse":
    let quic = quicOptions(verifyAny: false)
    sec_protocol_options_set_local_identity(quic.securityProtocolOptions, sec_identity_create(try identity.makeSecIdentity())!)
    let p = NWParameters(quic: quic)
    p.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
    p.allowLocalEndpointReuse = true
    listener = try NWListener(using: p)
case "ifaceLoopback":
    let quic = quicOptions(verifyAny: false)
    sec_protocol_options_set_local_identity(quic.securityProtocolOptions, sec_identity_create(try identity.makeSecIdentity())!)
    let p = NWParameters(quic: quic)
    let monitor = NWPathMonitor(requiredInterfaceType: .loopback)
    let ready = DispatchSemaphore(value: 0)
    let box = InterfaceBox()
    monitor.pathUpdateHandler = { path in
        box.value = path.availableInterfaces.first { $0.name == "lo0" }
        ready.signal()
    }
    monitor.start(queue: .global())
    _ = ready.wait(timeout: .now() + 2)
    monitor.cancel()
    guard let loopback = box.value else { fatalError("no lo0 in available interfaces") }
    p.requiredInterface = loopback
    listener = try NWListener(using: p, on: port)
case "pinMatch", "pinMismatch", "unconstrained", "unconstrainedLoopback":
    // No requiredLocalEndpoint and no requiredInterface: nothing for the
    // accepted connection to inherit and re-bind. Tailnet-only admission moves
    // to accept time, exactly like the product listener's source check.
    let quic = quicOptions(verifyAny: false)
    sec_protocol_options_set_local_identity(quic.securityProtocolOptions, sec_identity_create(try identity.makeSecIdentity())!)
    let p = NWParameters(quic: quic)
    listener = try NWListener(using: p, on: port)
case "reuse7777":
    let quic = quicOptions(verifyAny: false)
    sec_protocol_options_set_local_identity(quic.securityProtocolOptions, sec_identity_create(try identity.makeSecIdentity())!)
    let p = NWParameters(quic: quic)
    guard let iface = tailnetInterface() else { fatalError("no \(interfaceName)") }
    p.requiredInterface = iface
    p.allowLocalEndpointReuse = true
    listener = try NWListener(using: p, on: port)
case "ifaceBoth", "ifaceClientLocal":
    let quic = quicOptions(verifyAny: false)
    sec_protocol_options_set_local_identity(quic.securityProtocolOptions, sec_identity_create(try identity.makeSecIdentity())!)
    let p = NWParameters(quic: quic)
    guard let iface = tailnetInterface() else { fatalError("no \(interfaceName)") }
    p.requiredInterface = iface
    listener = try NWListener(using: p, on: port)
default:
    fatalError("unknown variant")
}

print("== variant: \(variant)")
listener.stateUpdateHandler = { log("listener: \($0)") }
listener.newConnectionHandler = { connection in
    log("ACCEPTED from \(connection.endpoint)")
    connection.stateUpdateHandler = { state in
        log("  accepted: \(state) localEndpoint=\(String(describing: connection.currentPath?.localEndpoint))")
        if case .ready = state {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { data, _, _, error in
                log("  accepted receive: bytes=\(data?.count ?? -1) error=\(String(describing: error))")
            }
        }
    }
    connection.start(queue: .global())
}
listener.start(queue: .global())
Thread.sleep(forTimeInterval: 1.5)

let dialHost = ["unconstrainedLoopback", "pinMatch", "pinMismatch"].contains(variant) ? "127.0.0.1" : address
// The pin variants dial with the real viewer parameters, including the
// verify block NetworkControlConnection installs, against the live host
// identity.
let clientParameters: NWParameters
switch variant {
case "pinMatch":
    clientParameters = NetworkControlConnection.parameters(tlsCertificateHash: identity.certificateHash)
case "pinMismatch":
    var wrongPin = identity.certificateHash
    wrongPin[0] ^= 0xFF
    clientParameters = NetworkControlConnection.parameters(tlsCertificateHash: wrongPin)
default:
    clientParameters = NWParameters(quic: quicOptions(verifyAny: true))
}
if variant == "ifaceBoth", let iface = tailnetInterface() {
    clientParameters.requiredInterface = iface
}
if variant == "ifaceClientLocal" {
    clientParameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: .any)
}
if variant == "reuse7777" {
    clientParameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
    clientParameters.allowLocalEndpointReuse = true
}
let client = NWConnection(host: NWEndpoint.Host(dialHost), port: port, using: clientParameters)
client.stateUpdateHandler = { state in
    log("client: \(state) localEndpoint=\(String(describing: client.currentPath?.localEndpoint))")
    if case .ready = state {
        client.send(content: Data([7, 7, 7]), completion: .contentProcessed { log("client send error=\(String(describing: $0))") })
    }
}
client.start(queue: .global())
Thread.sleep(forTimeInterval: 6.0)
client.cancel(); listener.cancel()
Thread.sleep(forTimeInterval: 0.5)

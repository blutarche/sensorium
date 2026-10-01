import SensoriumCore
import Network
import Security

/// What the socket is actually doing. A listener that fails to bind must say so:
/// a silent failure looks like a running host that serves nobody.
public enum HostListenerState: Equatable, Sendable {
    case ready(port: UInt16)
    case failed(String)
    case cancelled
    /// The tailnet interface changed under the listener, or the listener
    /// stopped serving it, so a new listener is being built in its place.
    case rebuilding
    /// A connection turned away by the accept-time source policy. Reported so
    /// the person at this machine can tell a viewer dialling from the wrong
    /// network from a network that is down; both are otherwise silence.
    case refusedSource(address: String)
}

/// Turns a bind failure into words the person at this machine can act on.
/// `EADDRINUSE` is the one bind failure with a specific, actionable cause on
/// this machine -- another Sensorium process already holding the port --
/// so it gets its own sentence instead of `NWError`'s own description, which
/// names a POSIX error code and nothing else.
public enum HostListenerFailureDescription {
    public static func describe(_ error: NWError) -> String {
        if case .posix(.EADDRINUSE) = error {
            return "another Sensorium host is already running and holding this port. "
                + "Quit it (its menu-bar item, or Activity Monitor if it is not showing one), then try again."
        }
        return "\(error)"
    }
}

public enum HostNetworkListenerError: Error, Equatable {
    case nonTailnetBindAddress
    case invalidPort
    case invalidTLSIdentity
}

/// Which transport the host serves.
///
/// `quic` is the product transport. `tcpLocalVerification` exists because a
/// single machine cannot hairpin QUIC through the tailnet interface — the
/// host's replies to its own address are dropped before they reach the
/// viewer — so the live host/viewer verification runs over TCP on the same
/// bound tailnet address. Sessions on it are still Ed25519-authenticated and
/// the canvas signature still binds the host key; only the TLS layer differs.
public enum HostTransportKind: String, Equatable, Sendable {
    case quic
    case tcpLocalVerification
    /// QUIC with an unscoped listener that admits loopback sources at accept
    /// time. Exists because a same-machine dial cannot traverse the tailnet
    /// interface, so the QUIC product path is otherwise unverifiable on one
    /// machine. Explicit, never a fallback; LAN and public sources stay
    /// refused even here.
    case quicLocalVerification
}

/// Accept-time source admission, factored out of the listener so every
/// transport's policy is testable without a socket.
public enum HostConnectionAdmission {
    public static func admits(
        sourceHost: String,
        transport: HostTransportKind,
        allowLocalNetwork: Bool = false,
        localSubnets: [LocalSubnet] = []
    ) -> Bool {
        if SourceAddressPolicy.isTailnetSource(sourceHost) {
            return true
        }
        if allowLocalNetwork && SourceAddressPolicy.isOnLinkSource(sourceHost, interfaces: localSubnets) {
            return true
        }
        if transport == .quicLocalVerification {
            return sourceHost == "127.0.0.1" || sourceHost == "::1"
        }
        return false
    }

    public static func admits(
        endpoint: NWEndpoint,
        transport: HostTransportKind,
        allowLocalNetwork: Bool = false,
        localSubnets: [LocalSubnet] = []
    ) -> Bool {
        guard let source = sourceHost(of: endpoint) else {
            return false
        }
        return admits(
            sourceHost: source,
            transport: transport,
            allowLocalNetwork: allowLocalNetwork,
            localSubnets: localSubnets
        )
    }

    /// The source as the policy reads it, and as a refusal has to name it.
    public static func sourceHost(of endpoint: NWEndpoint) -> String? {
        guard case let .hostPort(host, _) = endpoint else {
            return nil
        }
        switch host {
        case let .ipv4(address):
            return address.debugDescription
        case let .ipv6(address):
            return address.debugDescription
        case let .name(name, _):
            return name
        @unknown default:
            return nil
        }
    }
}

public final class HostNetworkListener: @unchecked Sendable {
    /// Replaced when the QUIC listener is rebuilt; touched only on `queue`
    /// once started.
    private var listener: NWListener
    private let queue = DispatchQueue(label: "com.sensorium.host-listener")
    private let tailnetAddress: String
    private let port: UInt16
    private let tlsIdentity: HostTLSIdentity
    private var recovery: HostListenerRecoveryPolicy
    private var generation = 0
    private var pathMonitor: NWPathMonitor?
    private var stopped = false
    private var onState: (@Sendable (HostListenerState) -> Void)?
    private var onConnection: (@Sendable (NWConnection) -> Void)?
    /// "Allow connections from this network". Only ever true for the QUIC
    /// product transport, and touched only on `queue` once started.
    private var allowsLocalNetwork: Bool

    /// Scopes the socket to the interface that owns the tailnet address.
    ///
    /// Not `requiredLocalEndpoint`: a QUIC listener's accepted connections
    /// inherit that requirement, re-bind the listener's own address and port,
    /// and fail with EADDRINUSE before completing any handshake — for every
    /// viewer, remote ones included. Interface scoping keeps the port off the
    /// LAN, and the accept-time source policy plus the external PF anchor stand
    /// behind it.
    public static func parameters(
        boundToTailnetAddress address: String,
        tlsIdentity: HostTLSIdentity
    ) throws -> NWParameters {
        try parameters(
            boundToTailnetAddress: address,
            tlsIdentity: tlsIdentity,
            requiredInterface: TailnetInterfaceLocator.interface(owningAddress: address)
        )
    }

    /// With "Allow connections from this network" on, the port is on every
    /// interface and accept-time admission alone decides who gets in. The bind
    /// address must still be a tailnet one: hosting still needs Tailscale.
    public static func parameters(
        boundToTailnetAddress address: String,
        tlsIdentity: HostTLSIdentity,
        allowsLocalNetwork: Bool
    ) throws -> NWParameters {
        guard allowsLocalNetwork else {
            return try parameters(boundToTailnetAddress: address, tlsIdentity: tlsIdentity)
        }
        return try parameters(boundToTailnetAddress: address, tlsIdentity: tlsIdentity, requiredInterface: nil)
    }

    static func parameters(
        boundToTailnetAddress address: String,
        tlsIdentity: HostTLSIdentity,
        requiredInterface interface: NWInterface?
    ) throws -> NWParameters {
        guard SourceAddressPolicy.isTailnetSource(address) else {
            throw HostNetworkListenerError.nonTailnetBindAddress
        }
        let quic = NWProtocolQUIC.Options()
        // A dead viewer over UDP is silence; this turns 30s of it into a
        // failed connection. Clock-sync traffic every 10s keeps live
        // sessions alive.
        quic.idleTimeout = 30_000
        sec_protocol_options_add_tls_application_protocol(
            quic.securityProtocolOptions,
            "com.sensorium.control-v1"
        )
        let identity: sec_identity_t
        do {
            guard let created = sec_identity_create(try tlsIdentity.makeSecIdentity()) else {
                throw HostNetworkListenerError.invalidTLSIdentity
            }
            identity = created
        } catch let error as HostNetworkListenerError {
            throw error
        } catch {
            throw HostNetworkListenerError.invalidTLSIdentity
        }
        sec_protocol_options_set_local_identity(quic.securityProtocolOptions, identity)
        let parameters = NWParameters(quic: quic)
        if let interface {
            parameters.requiredInterface = interface
        }
        parameters.prohibitedInterfaceTypes = [.cellular]
        return parameters
    }

    /// TCP accepted connections do not re-bind an inherited local endpoint the
    /// way QUIC ones do, so the verification transport can — and does — keep
    /// the strict address-and-port bind.
    public static func parameters(
        boundToTailnetAddress address: String,
        port: UInt16,
        tlsIdentity: HostTLSIdentity,
        transport: HostTransportKind
    ) throws -> NWParameters {
        switch transport {
        case .quic:
            return try parameters(boundToTailnetAddress: address, tlsIdentity: tlsIdentity)
        case .quicLocalVerification:
            guard SourceAddressPolicy.isTailnetSource(address) else {
                throw HostNetworkListenerError.nonTailnetBindAddress
            }
            let quic = NWProtocolQUIC.Options()
            quic.idleTimeout = 30_000
            sec_protocol_options_add_tls_application_protocol(
                quic.securityProtocolOptions,
                "com.sensorium.control-v1"
            )
            guard let secIdentity = try? tlsIdentity.makeSecIdentity(),
                  let created = sec_identity_create(secIdentity) else {
                throw HostNetworkListenerError.invalidTLSIdentity
            }
            sec_protocol_options_set_local_identity(quic.securityProtocolOptions, created)
            return NWParameters(quic: quic)
        case .tcpLocalVerification:
            guard SourceAddressPolicy.isTailnetSource(address) else {
                throw HostNetworkListenerError.nonTailnetBindAddress
            }
            guard let port = NWEndpoint.Port(rawValue: port) else {
                throw HostNetworkListenerError.invalidPort
            }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
            return parameters
        }
    }

    private let transport: HostTransportKind

    public init(
        tailnetAddress: String,
        port: UInt16,
        tlsIdentity: HostTLSIdentity,
        transport: HostTransportKind = .quic,
        allowsLocalNetwork: Bool = false
    ) throws {
        self.transport = transport
        self.allowsLocalNetwork = transport == .quic && allowsLocalNetwork
        self.tailnetAddress = tailnetAddress
        self.port = port
        self.tlsIdentity = tlsIdentity
        switch transport {
        case .quicLocalVerification:
            guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
                throw HostNetworkListenerError.invalidPort
            }
            listener = try NWListener(
                using: try Self.parameters(
                    boundToTailnetAddress: tailnetAddress,
                    port: port,
                    tlsIdentity: tlsIdentity,
                    transport: transport
                ),
                on: listenerPort
            )
        case .tcpLocalVerification:
            // The TCP bind carries the port in `requiredLocalEndpoint`; passing
            // `on:` as well makes NWListener reject the pair with EINVAL.
            listener = try NWListener(
                using: try Self.parameters(
                    boundToTailnetAddress: tailnetAddress,
                    port: port,
                    tlsIdentity: tlsIdentity,
                    transport: transport
                )
            )
        case .quic:
            guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
                throw HostNetworkListenerError.invalidPort
            }
            // The tailnet interface must actually exist at bind time; falling
            // back to an unscoped listener would put the port on the LAN.
            guard TailnetInterfaceLocator.isAvailable(address: tailnetAddress) else {
                throw HostNetworkListenerError.nonTailnetBindAddress
            }
            listener = try NWListener(
                using: Self.parameters(
                    boundToTailnetAddress: tailnetAddress,
                    tlsIdentity: tlsIdentity,
                    allowsLocalNetwork: self.allowsLocalNetwork
                ),
                on: listenerPort
            )
        }
        recovery = HostListenerRecoveryPolicy(
            boundInterface: listener.parameters.requiredInterface.map(Self.identity(of:))
        )
    }

    /// Refuses non-tailnet sources before any session state exists. The bound
    /// address is the first layer, the PF anchor the outermost, and this the one
    /// that survives either being missing.
    ///
    /// The QUIC transport also follows the tailnet interface: when it is
    /// replaced, as it is whenever Tailscale restarts, the listener is rebuilt
    /// on the new one. Only the listener is replaced; connections it already
    /// accepted are left to end on their own. While "Allow connections from
    /// this network" is on the listener is unscoped, so tailnet churn does not
    /// touch it.
    public func start(
        onState: (@Sendable (HostListenerState) -> Void)? = nil,
        onConnection: @escaping @Sendable (NWConnection) -> Void
    ) {
        queue.sync {
            self.onState = onState
            self.onConnection = onConnection
            install(listener, generation: generation)
            listener.start(queue: queue)
            guard transport == .quic else { return }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                self?.pathChanged(path)
            }
            pathMonitor = monitor
            monitor.start(queue: queue)
        }
    }

    /// Rebuilds the QUIC listener for the new mode: unscoped when on, scoped to
    /// the tailnet interface when off. Turning it off never leaves the
    /// unscoped listener running, even when the tailnet interface cannot be
    /// found yet; the path monitor then rebuilds once it appears. Connections
    /// already accepted are the caller's to end.
    public func setAllowsLocalNetwork(_ allows: Bool) {
        queue.sync {
            guard transport == .quic, !stopped, allows != allowsLocalNetwork else { return }
            allowsLocalNetwork = allows
            if allows {
                listener.cancel()
                do {
                    guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
                        throw HostNetworkListenerError.invalidPort
                    }
                    let replacement = try NWListener(
                        using: Self.parameters(
                            boundToTailnetAddress: tailnetAddress,
                            tlsIdentity: tlsIdentity,
                            allowsLocalNetwork: true
                        ),
                        on: listenerPort
                    )
                    listener = replacement
                    install(replacement, generation: generation)
                    replacement.start(queue: queue)
                } catch let error as NWError {
                    onState?(.failed(HostListenerFailureDescription.describe(error)))
                } catch {
                    onState?(.failed("\(error)"))
                }
            } else {
                listener.cancel()
                onState?(.rebuilding)
                rebuild()
            }
        }
    }

    public func stop() {
        queue.sync {
            stopped = true
            pathMonitor?.cancel()
            pathMonitor = nil
            listener.cancel()
        }
    }

    private func install(_ listener: NWListener, generation: Int) {
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            // A listener replaced by a mode change or a rebuild still reports
            // its own cancellation; only the current one speaks for the host.
            guard let self, let listener, listener === self.listener else { return }
            let event: HostListenerRecoveryPolicy.ListenerEvent
            let reported: HostListenerState
            switch state {
            case .ready:
                event = .ready
                reported = .ready(port: listener.port?.rawValue ?? 0)
            case let .failed(error):
                event = .failed
                reported = .failed(HostListenerFailureDescription.describe(error))
            case .cancelled:
                event = .cancelled
                reported = .cancelled
            case .waiting:
                event = .waiting
                reported = .rebuilding
            default:
                return
            }
            // `HostListenerRecoveryPolicy` follows the tailnet interface; an
            // unscoped listener has no interface to follow.
            guard transport == .quic, !allowsLocalNetwork else {
                if event != .waiting {
                    onState?(reported)
                }
                return
            }
            switch recovery.listenerEvent(event, generation: generation) {
            case .none:
                break
            case .report:
                onState?(reported)
            case let .rebuild(afterSeconds):
                scheduleRebuild(afterSeconds: afterSeconds)
            }
        }
        listener.newConnectionHandler = { [weak self, transport] connection in
            let allowsLocalNetwork = self?.allowsLocalNetwork ?? false
            guard HostConnectionAdmission.admits(
                endpoint: connection.endpoint,
                transport: transport,
                allowLocalNetwork: allowsLocalNetwork,
                localSubnets: allowsLocalNetwork ? LocalSubnetEnumerator.current() : []
            ) else {
                self?.onState?(.refusedSource(
                    address: HostConnectionAdmission.sourceHost(of: connection.endpoint) ?? "an address it could not read"
                ))
                connection.cancel()
                return
            }
            self?.onConnection?(connection)
        }
    }

    private func pathChanged(_ path: NWPath) {
        guard !stopped, !allowsLocalNetwork else { return }
        let interface = Self.interface(owning: tailnetAddress, in: path)
        if case let .rebuild(afterSeconds) = recovery.interfaceObserved(interface.map(Self.identity(of:))) {
            scheduleRebuild(afterSeconds: afterSeconds)
        }
    }

    private func scheduleRebuild(afterSeconds: Double) {
        guard !stopped else { return }
        onState?(.rebuilding)
        queue.asyncAfter(deadline: .now() + afterSeconds) { [weak self] in
            self?.rebuild()
        }
    }

    private func rebuild() {
        guard !stopped, !allowsLocalNetwork else { return }
        guard let path = pathMonitor?.currentPath,
              let interface = Self.interface(owning: tailnetAddress, in: path) else {
            recovery.rebuildFoundNoInterface()
            return
        }
        listener.cancel()
        generation = recovery.rebuildBegan(on: Self.identity(of: interface))
        do {
            guard let listenerPort = NWEndpoint.Port(rawValue: port) else {
                throw HostNetworkListenerError.invalidPort
            }
            let replacement = try NWListener(
                using: Self.parameters(
                    boundToTailnetAddress: tailnetAddress,
                    tlsIdentity: tlsIdentity,
                    requiredInterface: interface
                ),
                on: listenerPort
            )
            listener = replacement
            install(replacement, generation: generation)
            replacement.start(queue: queue)
        } catch {
            if case let .rebuild(afterSeconds) = recovery.listenerEvent(.failed, generation: generation) {
                scheduleRebuild(afterSeconds: afterSeconds)
            }
        }
    }

    private static func interface(owning address: String, in path: NWPath) -> NWInterface? {
        guard let name = TailnetInterfaceLocator.interfaceName(owningAddress: address) else {
            return nil
        }
        return path.availableInterfaces.first { $0.name == name }
    }

    private static func identity(of interface: NWInterface) -> HostListenerInterfaceIdentity {
        HostListenerInterfaceIdentity(name: interface.name, index: interface.index)
    }
}

/// One network interface as Network.framework names it. The index tells a
/// recreated interface apart from the one it replaced, which can reuse the
/// same BSD name.
public struct HostListenerInterfaceIdentity: Equatable, Sendable {
    public let name: String
    public let index: Int

    public init(name: String, index: Int) {
        self.name = name
        self.index = index
    }
}

/// Decides when the host's QUIC listener has to be rebuilt.
///
/// The listener is scoped to the interface that owns the tailnet address.
/// When Tailscale restarts, that interface is torn down and a new one is
/// created, while the old listener keeps holding its port and accepts
/// nothing. The listener has to be rebuilt on the new interface: whenever
/// the tailnet address is seen on an interface other than the one the
/// listener was built on, or after it was seen on none at all, and whenever
/// the listener reports it is waiting for a network or has failed after it
/// was once ready.
///
/// Each rebuild starts a new generation, so late events from a replaced
/// listener are ignored rather than read as the host stopping.
public struct HostListenerRecoveryPolicy: Sendable {
    public enum ListenerEvent: Equatable, Sendable {
        case ready
        case waiting
        case failed
        case cancelled
    }

    public enum Decision: Equatable, Sendable {
        case none
        /// Pass the event on to whoever started the listener.
        case report
        case rebuild(afterSeconds: Double)
    }

    private static let maximumRetryDelaySeconds: Double = 30

    private var boundInterface: HostListenerInterfaceIdentity?
    private var interfaceLostSinceBind = false
    private var generation = 0
    private var everReady = false
    private var rebuildPending = false
    private var failedRebuilds = 0

    public init(boundInterface: HostListenerInterfaceIdentity?) {
        self.boundInterface = boundInterface
    }

    public mutating func interfaceObserved(_ interface: HostListenerInterfaceIdentity?) -> Decision {
        guard let interface else {
            interfaceLostSinceBind = true
            return .none
        }
        guard interfaceLostSinceBind || interface != boundInterface else {
            return .none
        }
        // A new interface is a fresh chance to bind, not one more retry.
        if !rebuildPending {
            failedRebuilds = 0
        }
        return requestRebuild()
    }

    public mutating func listenerEvent(_ event: ListenerEvent, generation: Int) -> Decision {
        guard generation == self.generation else {
            return .none
        }
        switch event {
        case .ready:
            everReady = true
            failedRebuilds = 0
            return .report
        case .cancelled:
            return .report
        case .waiting:
            return requestRebuild()
        case .failed:
            guard everReady || generation > 0 else {
                return .report
            }
            return requestRebuild()
        }
    }

    /// Records that a new listener is being built on `interface`, and returns
    /// the generation its events must carry.
    public mutating func rebuildBegan(on interface: HostListenerInterfaceIdentity) -> Int {
        rebuildPending = false
        boundInterface = interface
        interfaceLostSinceBind = false
        generation += 1
        return generation
    }

    /// A rebuild that found the tailnet address on no interface binds
    /// nothing: falling back to an unscoped listener would put the port on
    /// every network without the person at this machine asking for it. An
    /// unscoped listener exists only while "Allow connections from this
    /// network" is on, and `HostNetworkListener` bypasses this policy for it
    /// entirely. The next interface that carries the address triggers the
    /// rebuild.
    public mutating func rebuildFoundNoInterface() {
        rebuildPending = false
        interfaceLostSinceBind = true
    }

    private mutating func requestRebuild() -> Decision {
        guard !rebuildPending else {
            return .none
        }
        rebuildPending = true
        let delay = failedRebuilds == 0
            ? 0
            : min(Self.maximumRetryDelaySeconds, Double(1 << min(failedRebuilds - 1, 5)))
        failedRebuilds += 1
        return .rebuild(afterSeconds: delay)
    }
}

extension HostListenerRecoveryPolicy {
    public enum UnscopedDecision: Equatable, Sendable {
        case none
        case report
        case fallBackToTailnet
    }

    /// For the unscoped listener "Allow connections from this network" runs,
    /// which follows no interface and so bypasses the policy above. A failure
    /// falls back to the scoped tailnet listener rather than leaving the host
    /// with nothing listening at all.
    public static func unscopedListenerEvent(_ event: ListenerEvent) -> UnscopedDecision {
        switch event {
        case .waiting: return .none
        case .ready, .cancelled: return .report
        case .failed: return .fallBackToTailnet
        }
    }
}

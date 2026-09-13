import Foundation

/// Deterministic exponential backoff. No jitter: a single viewer reconnecting
/// to a single host has nothing to spread out, and jitter would make the
/// schedule untestable without injecting a clock or a generator.
public struct ReconnectPolicy: Equatable, Sendable {
    public let initialDelay: TimeInterval
    public let maximumDelay: TimeInterval
    public let multiplier: Double
    /// `nil` retries for as long as the user leaves the session open.
    public let maximumAttempts: Int?

    public init(
        initialDelay: TimeInterval,
        maximumDelay: TimeInterval,
        multiplier: Double,
        maximumAttempts: Int?
    ) {
        precondition(initialDelay > 0 && maximumDelay >= initialDelay && multiplier >= 1)
        self.initialDelay = initialDelay
        self.maximumDelay = maximumDelay
        self.multiplier = multiplier
        self.maximumAttempts = maximumAttempts
    }

    public static let remoteDefault = ReconnectPolicy(
        initialDelay: 0.5,
        maximumDelay: 8,
        multiplier: 2,
        maximumAttempts: nil
    )

    /// Attempts are one-based. Returns `nil` once the policy is exhausted.
    public func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 1 else {
            return nil
        }
        if let maximumAttempts, attempt > maximumAttempts {
            return nil
        }
        let raw = initialDelay * pow(multiplier, Double(attempt - 1))
        return min(raw, maximumDelay)
    }
}

public enum ConnectionSupervisorEvent: Equatable, Sendable {
    case connectRequested
    case connectSucceeded
    case connectFailed
    case transportLost
    case userDisconnected
}

public enum ConnectionSupervisorAction: Equatable, Sendable {
    case connect
    case reconnect(after: TimeInterval)
    case idle
    case giveUp
    case stop
}

/// Decides whether and when to redial. Holds no timer and reads no clock, so the
/// whole retry schedule is verifiable as a pure sequence.
public struct ConnectionSupervisor: Equatable, Sendable {
    private let policy: ReconnectPolicy
    private var attempt = 0
    private var isStopped = false

    public init(policy: ReconnectPolicy) {
        self.policy = policy
    }

    public mutating func handle(_ event: ConnectionSupervisorEvent) -> ConnectionSupervisorAction {
        guard !isStopped else {
            return .stop
        }
        switch event {
        case .connectRequested:
            attempt = 0
            return .connect
        case .connectSucceeded:
            attempt = 0
            return .idle
        case .connectFailed, .transportLost:
            attempt += 1
            guard let delay = policy.delay(forAttempt: attempt) else {
                isStopped = true
                return .giveUp
            }
            return .reconnect(after: delay)
        case .userDisconnected:
            isStopped = true
            return .stop
        }
    }
}

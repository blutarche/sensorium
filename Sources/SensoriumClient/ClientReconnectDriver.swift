import SensoriumCore
import Foundation

public enum ClientReconnectOutcome: Equatable, Sendable {
    /// A session connected and then ended. The caller decides whether that is
    /// the user leaving or a drop worth redialling.
    case sessionEnded
    case gaveUp
    case stopped
}

/// What one run of redialling did, reported as values rather than as text.
/// The words are `ViewerSessionFailureCopy`'s, so nothing downstream has to
/// edit a sentence that already has a system error's own wording inside it.
public enum ClientReconnectEvent: Equatable, Sendable {
    case attemptFailed(ViewerSessionFailure)
    case retrying(afterSeconds: TimeInterval)
}

/// Drives redialling on top of `ConnectionSupervisor`. It owns no socket and
/// reads no clock: the session attempt and the wait are both injected, so the
/// entire retry schedule is verifiable without a host to connect to.
public actor ClientReconnectDriver {
    private var supervisor: ConnectionSupervisor
    private let runSession: @Sendable () async throws -> Void
    private let sleep: @Sendable (TimeInterval) async -> Void
    private let onEvent: (@Sendable (ClientReconnectEvent) -> Void)?
    private var isStopped = false

    public init(
        policy: ReconnectPolicy,
        runSession: @escaping @Sendable () async throws -> Void,
        sleep: @escaping @Sendable (TimeInterval) async -> Void,
        onEvent: (@Sendable (ClientReconnectEvent) -> Void)? = nil
    ) {
        supervisor = ConnectionSupervisor(policy: policy)
        self.runSession = runSession
        self.sleep = sleep
        self.onEvent = onEvent
    }

    public func stop() {
        isStopped = true
        _ = supervisor.handle(.userDisconnected)
    }

    /// Returns once a session has connected and ended, the policy is exhausted,
    /// or the user quit. Redialling *after* a connected session ends is the
    /// caller's decision, so this never silently reopens a session the user
    /// closed on purpose.
    public func runUntilConnectedSessionEnds() async -> ClientReconnectOutcome {
        guard !isStopped else {
            return .stopped
        }
        _ = supervisor.handle(.connectRequested)
        while !isStopped {
            // Cancelling this run's task is what ends the wait between
            // attempts: `sleep` is asked to stop, and stopping it has to mean
            // the run is over rather than the next attempt starting early.
            // Checked before every attempt, so a run cancelled while parked in
            // its backoff dials nothing more.
            if Task.isCancelled {
                return .stopped
            }
            do {
                try await runSession()
                _ = supervisor.handle(.connectSucceeded)
                return .sessionEnded
            } catch {
                let failure = ViewerSessionFailure.classify(error)
                onEvent?(.attemptFailed(failure))
                // A refused or failed host-screen connect never auto-redials:
                // a host that refused this machine's screen refuses the same
                // dial again, so the retry policy below (backoff, give-up)
                // never applies to it. The caller reads this the same way it
                // reads `.stopped`.
                if case .hostScreenRefused = failure {
                    return .stopped
                }
                // A person at the host ended this session from that machine.
                // Redialling would put it straight back up and make Stop look
                // like it did nothing, so only a person at this end starts
                // another one -- the same reading the caller already gives a
                // refused host-screen connect.
                if case .stoppedByHost = failure {
                    return .stopped
                }
                // The host's own screens are asleep and would not wake, so
                // there is nothing on that machine to send. Redialling would
                // find the same dark screen and end the same way; a person
                // waking it is what changes the answer.
                if case .hostDisplaysAsleep = failure {
                    return .stopped
                }
                // A certificate pin or host key mismatch means the machine that
                // answered is not the machine this one paired with. Backing off
                // and redialling would just pin whatever answered next --
                // the wrong reflex for a security failure, so this stops
                // exactly like a refused host-screen connect above.
                if case .unverifiedHost = failure {
                    return .stopped
                }
                // One refused canvas stops: macOS would not create one under
                // any identity the host has, so the next dial is refused
                // exactly as this one was and only the host app being opened
                // again at that machine changes the answer. `canvas-not-offered`
                // is just as permanent -- only a person at the host turning
                // the setting on changes that answer, not a retry. Every
                // other reason keeps the policy below -- `canvas-creation-
                // in-progress` is a race with another connection's creation
                // that is over in a moment, and a reason this build has
                // never seen is not proof the host can never recover from it.
                if case let .canvasRefused(reason) = failure,
                   reason == CanvasRefusalReason.canvasUnavailable
                       || reason == CanvasRefusalReason.canvasNotOffered {
                    return .stopped
                }
                switch supervisor.handle(.connectFailed) {
                case let .reconnect(after):
                    onEvent?(.retrying(afterSeconds: after))
                    await sleep(after)
                case .giveUp:
                    return .gaveUp
                case .stop:
                    return .stopped
                case .connect, .idle:
                    continue
                }
            }
        }
        return .stopped
    }
}

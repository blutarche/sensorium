import Foundation
import SensoriumCore

/// What one unlock submission did, before the host's own answer arrives. Only
/// `.armed` means the arm and the unlock request reached the wire; every other
/// case is a fail-closed abort that sent no unlock request at all, so the
/// person is told to try again and the prompt stays up for it.
public enum HostScreenUnlockSubmitResult: Equatable, Sendable {
    /// The presence arm and the unlock request both left. The host's spoken
    /// answer (unlocked, wrong password, still `.presenceRequired`, ...) still
    /// arrives asynchronously through the receive loop.
    case armed
    /// A send threw before the arm or the unlock request could leave -- the
    /// connection dropped mid-submit. No unlock request went out.
    case couldNotSend
    /// The host never returned a challenge within the wire budget, or the
    /// connection dropped while waiting. No arm, no unlock request.
    case challengeTimedOut
    /// The live presence check confirming a person is at this machine was
    /// cancelled or failed, so no proof exists to arm with. Fail-closed: no arm, no unlock request.
    case presenceFailed
    /// A submission was already in flight. Nothing was sent for this one.
    case alreadyInFlight
}

/// The viewer half of an opt-in lock-screen unlock, from the moment a person
/// confirms the unlock with a password. It runs the fixed sequence the host
/// now requires -- request a single-use challenge, sign that exact challenge
/// with a live presence check, arm, then send the unlock request -- and owns
/// the one pending awaiter that correlates the host's `hostScreenUnlockChallenge`
/// reply back to the submission waiting for it.
///
/// At most one unlock is ever in flight, so a single pending continuation is
/// the whole correlation primitive; there is no keyed registry. It runs on the
/// main actor, the same isolation the runner's control-message dispatch runs
/// on, so that isolation alone guards the pending slot -- no separate lock.
///
/// The password crosses two awaits here (the challenge round trip, then the
/// signing) but is only ever a `run` parameter, never a stored property, so no
/// copy of it outlives one attempt.
@MainActor
public final class HostScreenUnlockArmFlow {
    /// The one submission's awaiter for a `hostScreenUnlockChallenge` reply.
    /// Non-nil only while a submit is blocked waiting for the host's challenge.
    private var pendingChallenge: CheckedContinuation<Data, Error>?
    private var inFlight = false

    /// The wire round-trip budget for the host to mint and return an unlock
    /// challenge. No human is in this exchange -- the host replies as soon as
    /// it mints the challenge -- so this is a short wire-latency wait, not the
    /// presence/human budget the connect-time `hostScreenGrant` timeout is.
    public static let challengeReplyTimeout: Duration = .seconds(5)

    public init() {}

    /// Runs the submit-time sequence and reports what it did. `send` puts one
    /// message on the wire; `sign` produces a presence proof over the exact
    /// challenge bytes it is given, which takes a live confirmation that a
    /// person is there. Both are
    /// injected so the sequence is verifiable without a socket or a real
    /// authenticator.
    public func run(
        password: Data,
        timeout: Duration = HostScreenUnlockArmFlow.challengeReplyTimeout,
        send: (SensoriumMessage) async throws -> Void,
        sign: (Data) async throws -> HostScreenPresenceProof
    ) async -> HostScreenUnlockSubmitResult {
        guard !inFlight else { return .alreadyInFlight }
        inFlight = true
        defer { inFlight = false }

        do {
            try await send(.hostScreenUnlockChallengeRequest)
        } catch {
            return .couldNotSend
        }

        let challenge: Data
        do {
            challenge = try await awaitChallenge(timeout: timeout)
        } catch {
            return .challengeTimedOut
        }

        // Fail closed: a cancelled or failed live presence check produces no
        // proof, so nothing is armed and no password is put on the wire.
        let proof: HostScreenPresenceProof
        do {
            proof = try await sign(challenge)
        } catch {
            return .presenceFailed
        }

        do {
            try await send(.hostScreenUnlockArm(presence: proof))
            try await send(.hostScreenUnlockRequest(password: password))
        } catch {
            return .couldNotSend
        }
        return .armed
    }

    /// Waits for the host's single-use challenge, bounded by `timeout`. The
    /// pending slot is set here and cleared by whichever resolves first --
    /// `deliverChallenge`, the timeout, or `abandonPendingUnlock` -- all on the
    /// main actor, so the slot needs no lock of its own.
    private func awaitChallenge(timeout: Duration) async throws -> Data {
        let deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.failPendingChallenge()
        }
        defer { deadline.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            pendingChallenge = continuation
        }
    }

    /// The host's `hostScreenUnlockChallenge` reply, handed in from the receive
    /// loop. Resumes the one submission waiting for it. A late or duplicate
    /// challenge that arrives after the awaiter is gone is ignored -- no
    /// pending slot, no resume, no crash.
    public func deliverChallenge(_ challenge: Data) {
        guard let continuation = pendingChallenge else { return }
        pendingChallenge = nil
        continuation.resume(returning: challenge)
    }

    /// Resolves a submission still waiting for a challenge as a failure, for a
    /// connection that dropped before the reply arrived. A no-op when nothing
    /// is waiting.
    public func abandonPendingUnlock() {
        failPendingChallenge()
    }

    private func failPendingChallenge() {
        guard let continuation = pendingChallenge else { return }
        pendingChallenge = nil
        continuation.resume(throwing: ChallengeUnavailable())
    }

    private struct ChallengeUnavailable: Error {}
}

import Foundation
import SensoriumCore

/// The viewer's plain words for a host-screen unlock, kept out of any AppKit
/// view so the mapping is verifiable without a window. docs/ux-spec.md: "There
/// is no error whose remedy is a command, a file, or another app" -- every
/// line here is a sentence a person reads, never a token.
public enum HostScreenUnlockCopy {
    /// What the viewer shows after one unlock attempt. The `failed` case's
    /// internal reason is deliberately not surfaced: it is an operator-log
    /// token, not a sentence, and the remedy a person has is the same either
    /// way -- try again.
    public static func noticeLine(for outcome: HostScreenUnlockOutcome) -> String {
        switch outcome {
        case .unlocked:
            return "The host is unlocked."
        case .wrongPassword:
            return "That password did not unlock the host. Try again."
        case .screenSharingUnavailable:
            return "This machine could not reach its own screen-sharing service to unlock."
        case .notLocked:
            return "The host is already unlocked."
        case .notAuthorized:
            return "This session is not allowed to unlock the host."
        case .tooManyAttempts:
            return "Too many wrong passwords. The host stopped accepting unlock attempts. Someone at the host can re-arm this machine to allow more."
        case .passwordTooLong:
            return "That password is too long for this unlock method. Type it at the login window instead."
        case .presenceRequired:
            return "Confirm you are here to unlock the host, then try again."
        case .failed:
            return "The host could not be unlocked. Try again."
        }
    }

    /// Shown when the unlock request could not even be put on the wire -- the
    /// connection dropped before the send. A plain sentence whose only remedy is
    /// to try again; it names no wire error and carries none of the password.
    public static let couldNotSendNotice =
        "The unlock request could not be sent. Try again."

    /// Shown when the live presence check that confirms a person is at this
    /// machine was cancelled or failed, so no proof exists to arm the unlock
    /// with. Distinct from a wrong password:
    /// the remedy is to confirm presence again, not to retype anything.
    public static let presenceCancelledNotice =
        "Presence confirmation was cancelled or failed. Try unlocking again."

    /// Shown when the host never returned an unlock challenge in time, or the
    /// connection dropped while waiting for it. Nothing was sent; the remedy is
    /// to try again.
    public static let challengeTimedOutNotice =
        "The host did not answer the unlock request in time. Try again."

    /// The notice a submit's own result asks for, before the host's spoken
    /// answer arrives. `nil` for `.armed`, whose outcome comes later through the
    /// ordinary unlock-result path, and `nil` for `.alreadyInFlight`, a second
    /// submit rejected while the first is still pending: the first owns the
    /// prompt and re-enables it on its own resolution, so the rejected one must
    /// say nothing and leave that state alone. The switch stays exhaustive so a
    /// new result case is a compile error here rather than a silently unnoticed
    /// submit.
    public static func submitNotice(for result: HostScreenUnlockSubmitResult) -> String? {
        switch result {
        case .armed, .alreadyInFlight:
            return nil
        case .couldNotSend:
            return couldNotSendNotice
        case .challengeTimedOut:
            return challengeTimedOutNotice
        case .presenceFailed:
            return presenceCancelledNotice
        }
    }

    /// The raw UTF-8 bytes of a typed password, so the caller sends bytes it can
    /// zero rather than a `String` it cannot.
    public static func passwordBytes(from typed: String) -> Data {
        Data(typed.utf8)
    }

    /// Whether a lock-state report means the viewer should offer the unlock
    /// prompt. A separate function, trivial as it is, so the rule the panel and
    /// the tests share has one home.
    public static func shouldOfferUnlockPrompt(locked: Bool) -> Bool {
        locked
    }
}

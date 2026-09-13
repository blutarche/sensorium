import Foundation
import SensoriumCore

/// The two acceptable strengths a viewer's presence credential can report --
/// `docs/host-screen-design.md` §6.3. The raw values are the exact strings the host's
/// `HostScreenCredentialStrength` decodes from the wire; the two enums exist
/// on either side of the same contract without either target importing the
/// other's type.
public enum PresenceCredentialStrength: String, Equatable, Sendable {
    case hardwareBound
    case softwarePresence
}

/// Why `register()` could not produce a credential. Never a reason to fail
/// pairing: a credential is never required for pairing to succeed. A
/// machine that hits either case still pairs and uses the session canvas; it
/// only cannot be armed for a host screen.
public enum PresenceCredentialRegistrationError: Error, Equatable, Sendable {
    /// This machine has no Secure Enclave to hold the key in -- an Intel machine
    /// without a T2 chip, or a virtual machine.
    case noSecureEnclave
    /// The Secure Enclave or Keychain declined to create or reload the key.
    /// `reason` is whatever the platform reported, carried for a log, never
    /// shown to the user verbatim.
    case keystoreFailed(reason: String)
}

/// One sentence for each outcome `register()` can reach, worded the way
/// `docs/ux-spec.md` requires: no internal vocabulary, no raw platform
/// reason, an action the reader can act on when there is one.
public enum PresenceCredentialRegistrationCopy {
    public static func line(for error: any Error) -> String {
        switch error as? PresenceCredentialRegistrationError {
        case .noSecureEnclave:
            return "This machine cannot confirm that a person is at it, so a host can only allow it to see a "
                + "virtual display, never a host screen."
        case .keystoreFailed:
            return "This machine could not set up a way to confirm that a person is at it right now, so a host "
                + "can only allow it to see a virtual display, never a host screen."
        case nil:
            return "This machine could not set up a way to confirm that a person is at it, so a host can only "
                + "allow it to see a virtual display, never a host screen."
        }
    }

    public static let successLine =
        "This machine can confirm that a person is at it, so a host may allow it to see a host screen."
}

/// The whole presence-credential contract, from the viewer's side: a
/// keypair the operating system or an authenticator will not use without a
/// live human confirming at that moment. `register()` creates or loads it and reports
/// what this machine actually holds; `sign()` proves possession of it over a
/// challenge the host issued. Neither method ever answers without the
/// operation it names actually happening -- there is no cached or offline
/// signature.
public protocol PresenceCredentialProviding: Sendable {
    /// What this conformance will report if `register()` succeeds -- known
    /// before calling it, because it is a property of which conformance this
    /// is, not of any one call's outcome.
    var strength: PresenceCredentialStrength { get }

    func register() async throws -> PresenceCredentialRegistration
    /// Raw `r || s`, the shape `PresenceCredentialVerifier` (Sources/
    /// SensoriumHost/PresenceCredentialVerifier.swift) verifies -- not a
    /// platform envelope. Session-time use of this method is part 2.
    func sign(challenge: Data) async throws -> Data
}

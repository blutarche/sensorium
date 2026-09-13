import Foundation
import SensoriumCore

/// The viewer's own recovery from a stored identity it could not read: the
/// failure screen offers the fix itself rather than a dead end naming a
/// command-line flag.
///
/// `DeviceIdentityReplacing` is the seam over the store's own
/// `replaceWithFreshIdentity()`, so a test drives `replace(using:)` against
/// a fake and never writes a real key.
public enum ViewerIdentityRecovery {
    /// The read this app makes at launch and on every "Try again".
    public static func load(
        using provider: any DeviceIdentityProviding
    ) -> Result<DeviceIdentity, ViewerIdentityFailure> {
        do {
            return .success(try provider.loadOrCreate())
        } catch {
            return .failure(.unreadable(reason: IdentityFailureReason.describe(error)))
        }
    }

    /// The one mapping from `IdentityLoadOutcome` to `ViewerIdentityFailure`
    /// this app has: shared by the ordinary identity load and the replace
    /// path below so the two can never drift into naming the same outcome
    /// two different ways.
    public static func map(_ outcome: IdentityLoadOutcome) -> Result<DeviceIdentity, ViewerIdentityFailure> {
        switch outcome {
        case let .loaded(identity):
            return .success(identity)
        case let .failed(reason):
            return .failure(.unreadable(reason: reason))
        }
    }

    /// "Make a new key". `.success` is the state machine's "normal first
    /// run" step: there is nothing saved for a brand new device key to
    /// reuse, so the caller proceeds exactly as it would have if the very
    /// first load had simply succeeded.
    public static func replace(
        using replacing: any DeviceIdentityReplacing
    ) -> Result<DeviceIdentity, ViewerIdentityFailure> {
        do {
            return .success(try replacing.replaceWithFreshIdentity())
        } catch {
            return .failure(.unreadable(reason: IdentityFailureReason.describe(error)))
        }
    }
}

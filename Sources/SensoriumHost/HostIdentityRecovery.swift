import Foundation
import SensoriumCore

/// Which of this machine's two identities the replacement stopped at, if it
/// did not finish.
public enum HostIdentityReplacementOutcome: Equatable, Sendable {
    case replaced
    case deviceIdentityFailed(String)
    case hostTLSIdentityFailed(String)
}

/// "Make a new key" on the host window: mints a fresh key for each of this
/// machine's two identities, and writes neither file until both keys exist.
/// A host carrying one new key and one old one is recognised by no paired
/// viewer and repaired by no retry.
public enum HostIdentityRecovery {
    public static func replaceIdentities(
        device: any DeviceIdentityReplacing,
        tls: any HostTLSIdentityReplacing
    ) -> HostIdentityReplacementOutcome {
        let freshDevice: DeviceIdentity
        do {
            freshDevice = try device.makeReplacementIdentity()
        } catch {
            return .deviceIdentityFailed(IdentityFailureReason.describe(error))
        }

        let freshTLS: HostTLSIdentity
        do {
            freshTLS = try tls.makeReplacementIdentity()
        } catch {
            return .hostTLSIdentityFailed(IdentityFailureReason.describe(error))
        }

        do {
            try device.store(freshDevice)
        } catch {
            return .deviceIdentityFailed(IdentityFailureReason.describe(error))
        }
        do {
            try tls.store(freshTLS)
        } catch {
            return .hostTLSIdentityFailed(IdentityFailureReason.describe(error))
        }
        return .replaced
    }
}

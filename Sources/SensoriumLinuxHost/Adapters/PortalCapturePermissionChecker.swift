#if os(Linux)
import SensoriumHost

/// The Linux screen-sharing grant as the shared capture gate reads it:
/// granted only while the launch-time portal session is open with a monitor.
///
/// Asking never opens the portal's dialog from here. The dialog belongs to
/// the host window, where the person at the host chooses to allow screen
/// sharing again; a session's gate only reads the grant.
public final class PortalCapturePermissionChecker: ScreenCapturePermissionChecking {
    private let grantState: PortalGrantState

    public init(grantState: PortalGrantState) {
        self.grantState = grantState
    }

    public func check(prompt: Bool) -> Bool {
        grantState.isGranted
    }
}
#endif

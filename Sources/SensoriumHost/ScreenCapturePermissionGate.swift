public enum ScreenCapturePermissionStatus: Equatable {
    case granted
    case approvalRequired
}

/// Boundary around the platform's screen-capture trust: Screen Recording on
/// macOS, the screen-sharing grant on Linux. Status reads never present UI;
/// the caller must explicitly choose to request approval.
public protocol ScreenCapturePermissionChecking: AnyObject {
    func check(prompt: Bool) -> Bool
}

/// There is no default checker here: each platform supplies the one that asks
/// its own system, so a host cannot be built whose permission check was
/// silently skipped.
public final class ScreenCapturePermissionGate {
    private let checker: any ScreenCapturePermissionChecking

    public init(checker: any ScreenCapturePermissionChecking) {
        self.checker = checker
    }

    public var currentStatus: ScreenCapturePermissionStatus {
        checker.check(prompt: false) ? .granted : .approvalRequired
    }

    @discardableResult
    public func requestApproval() -> ScreenCapturePermissionStatus {
        checker.check(prompt: true) ? .granted : .approvalRequired
    }
}

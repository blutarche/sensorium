import CoreGraphics

public enum ScreenCapturePermissionStatus: Equatable {
    case granted
    case approvalRequired
}

/// Boundary around macOS Screen Recording trust. Status reads never present UI;
/// the caller must explicitly choose to request approval.
public protocol ScreenCapturePermissionChecking: AnyObject {
    func check(prompt: Bool) -> Bool
}

public final class SystemScreenCapturePermissionChecker: ScreenCapturePermissionChecking {
    public init() {}

    public func check(prompt: Bool) -> Bool {
        prompt ? CGRequestScreenCaptureAccess() : CGPreflightScreenCaptureAccess()
    }
}

public final class ScreenCapturePermissionGate {
    private let checker: any ScreenCapturePermissionChecking

    public init(checker: any ScreenCapturePermissionChecking = SystemScreenCapturePermissionChecker()) {
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

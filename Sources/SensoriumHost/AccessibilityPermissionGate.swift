public enum AccessibilityPermissionStatus: Equatable {
    case granted
    case approvalRequired
}

/// Boundary around the platform's input-injection trust. Reading status never
/// presents UI; only an explicit user-initiated request may ask the system to
/// open its approval flow. This type never grants permission itself.
public protocol AccessibilityPermissionChecking: AnyObject {
    func check(prompt: Bool) -> Bool
}

public final class AccessibilityPermissionGate {
    private let checker: any AccessibilityPermissionChecking

    public init(checker: any AccessibilityPermissionChecking) {
        self.checker = checker
    }

    public var currentStatus: AccessibilityPermissionStatus {
        checker.check(prompt: false) ? .granted : .approvalRequired
    }

    @discardableResult
    public func requestApproval() -> AccessibilityPermissionStatus {
        checker.check(prompt: true) ? .granted : .approvalRequired
    }
}

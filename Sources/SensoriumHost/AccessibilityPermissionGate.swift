@preconcurrency import ApplicationServices

public enum AccessibilityPermissionStatus: Equatable {
    case granted
    case approvalRequired
}

/// Boundary around macOS Accessibility trust. Reading status never presents UI;
/// only an explicit user-initiated request may ask macOS to open its approval
/// flow. This type never grants permission itself.
public protocol AccessibilityPermissionChecking: AnyObject {
    func check(prompt: Bool) -> Bool
}

public final class SystemAccessibilityPermissionChecker: AccessibilityPermissionChecking {
    public init() {}

    public func check(prompt: Bool) -> Bool {
        if prompt {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        }
        return AXIsProcessTrusted()
    }
}

public final class AccessibilityPermissionGate {
    private let checker: any AccessibilityPermissionChecking

    public init(checker: any AccessibilityPermissionChecking = SystemAccessibilityPermissionChecker()) {
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

#if os(macOS)
@preconcurrency import ApplicationServices

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

extension AccessibilityPermissionGate {
    public convenience init() {
        self.init(checker: SystemAccessibilityPermissionChecker())
    }
}
#endif

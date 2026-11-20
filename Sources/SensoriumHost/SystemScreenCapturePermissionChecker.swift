#if os(macOS)
import CoreGraphics

public final class SystemScreenCapturePermissionChecker: ScreenCapturePermissionChecking {
    public init() {}

    public func check(prompt: Bool) -> Bool {
        prompt ? CGRequestScreenCaptureAccess() : CGPreflightScreenCaptureAccess()
    }
}

extension ScreenCapturePermissionGate {
    public convenience init() {
        self.init(checker: SystemScreenCapturePermissionChecker())
    }
}
#endif

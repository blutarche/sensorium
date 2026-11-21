import SensoriumHost

/// A screen-capture permission check that answers as scripted, so a test never
/// asks the machine it runs on.
final class ScriptedScreenCaptureChecker: ScreenCapturePermissionChecking, @unchecked Sendable {
    var isGranted: Bool

    init(isGranted: Bool) {
        self.isGranted = isGranted
    }

    func check(prompt: Bool) -> Bool {
        isGranted
    }
}

func grantedScreenCapturePermission() -> ScreenCapturePermissionGate {
    ScreenCapturePermissionGate(checker: ScriptedScreenCaptureChecker(isGranted: true))
}

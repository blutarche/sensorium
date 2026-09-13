import Foundation

public struct HostPermissionRequestResult: Equatable {
    public let screenCapture: ScreenCapturePermissionStatus
    public let accessibility: AccessibilityPermissionStatus

    public var isReadyForViewerControl: Bool {
        screenCapture == .granted && accessibility == .granted
    }

    public init(
        screenCapture: ScreenCapturePermissionStatus,
        accessibility: AccessibilityPermissionStatus
    ) {
        self.screenCapture = screenCapture
        self.accessibility = accessibility
    }
}

/// Explicit, user-initiated host permission action. This has no listener,
/// display, pairing, or session side effects.
public enum HostPermissionRequester {
    public static func request(
        screenCapture: ScreenCapturePermissionGate = ScreenCapturePermissionGate(),
        accessibility: AccessibilityPermissionGate = AccessibilityPermissionGate()
    ) -> HostPermissionRequestResult {
        HostPermissionRequestResult(
            screenCapture: screenCapture.requestApproval(),
            accessibility: accessibility.requestApproval()
        )
    }
}

/// Whether this process is attached to a controlling terminal. macOS TCC
/// attributes a check performed by an unsigned/raw binary to its
/// *responsible* parent process rather than to the binary itself; run
/// directly from a terminal, that responsible parent is the terminal app, not
/// `sensoriumd`. A Launch-Services launch (Finder double-click, `open`) has no
/// controlling terminal, which is the only distinction this process can
/// observe about itself — there is no public API for the underlying
/// responsible-process/Launch-Services attribution directly.
public enum HostPermissionLaunchContext: Equatable, Sendable {
    case terminalAttached
    case notTerminalAttached
}

public final class SystemTerminalLaunchDetector {
    public init() {}

    public var launchContext: HostPermissionLaunchContext {
        isatty(fileno(stdin)) != 0 ? .terminalAttached : .notTerminalAttached
    }
}

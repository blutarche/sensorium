/// Names exactly which of the two host-pollable permissions changed, so a log
/// line can say what changed and what to do about it. Remote Desktop
/// (macOS 14+) is deliberately absent here: Apple exposes no public API to
/// query it, so nothing in this file can honestly monitor it — see
/// `HostPermissionReport`.
public enum HostPermissionKind: String, Equatable, Sendable {
    case screenRecording = "Screen Recording"
    case accessibility = "Accessibility"
}

public enum HostPermissionTransition: Equatable, Sendable {
    case lost(HostPermissionKind)
    case recovered(HostPermissionKind)

    /// A self-contained line: what changed and what to do about it, so it
    /// reads correctly even torn out of surrounding log context.
    public var logLine: String {
        switch self {
        case let .lost(kind):
            // The row to switch on reads `Sensorium Host`, from the host
            // bundle's CFBundleName. The person at this machine told to look
            // for "Sensorium" looks for a row that is not in that list, or
            // finds the viewer's.
            return "\(kind.rawValue) permission was revoked while the host was running. " +
                "This host will fail to serve \(kind == .accessibility ? "remote input" : "video") " +
                "until you approve it again in System Settings > Privacy & Security > \(kind.rawValue). " +
                "The row there is named Sensorium Host, and the host has to be relaunched afterwards."
        case let .recovered(kind):
            return "\(kind.rawValue) permission was approved again; the host detected it while running."
        }
    }
}

/// Polls the same status reads `HostPermissionRequester` uses on demand, on a
/// timer, so a host running unattended detects a revoked or newly granted
/// permission instead of failing silently between sessions. `poll()` never
/// presents UI — the same rule as the gates it wraps — and reports a
/// transition exactly once, on the call after the status actually changed,
/// never on a subsequent poll that finds the same status.
@MainActor
public final class HostPermissionMonitor {
    /// Screen Recording/Accessibility trust changes are a rare, user-driven
    /// event; this interval catches a revocation or a fresh approval well
    /// within a normal session without polling meaningfully harder than the
    /// event actually occurs.
    public static let defaultPollIntervalSeconds: Double = 30

    private let screenCapture: ScreenCapturePermissionGate
    private let accessibility: AccessibilityPermissionGate
    private let onTransition: (HostPermissionTransition) -> Void
    private var lastScreenCaptureStatus: ScreenCapturePermissionStatus
    private var lastAccessibilityStatus: AccessibilityPermissionStatus

    public init(
        screenCapture: ScreenCapturePermissionGate,
        accessibility: AccessibilityPermissionGate,
        onTransition: @escaping (HostPermissionTransition) -> Void
    ) {
        self.screenCapture = screenCapture
        self.accessibility = accessibility
        self.onTransition = onTransition
        lastScreenCaptureStatus = screenCapture.currentStatus
        lastAccessibilityStatus = accessibility.currentStatus
    }

    public func poll() {
        let screenCaptureStatus = screenCapture.currentStatus
        if screenCaptureStatus != lastScreenCaptureStatus {
            lastScreenCaptureStatus = screenCaptureStatus
            onTransition(screenCaptureStatus == .granted ? .recovered(.screenRecording) : .lost(.screenRecording))
        }
        let accessibilityStatus = accessibility.currentStatus
        if accessibilityStatus != lastAccessibilityStatus {
            lastAccessibilityStatus = accessibilityStatus
            onTransition(accessibilityStatus == .granted ? .recovered(.accessibility) : .lost(.accessibility))
        }
    }
}

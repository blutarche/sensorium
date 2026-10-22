/// Names exactly which host-pollable permission or service changed, so a log
/// line can say what changed and what to do about it. Remote Desktop
/// (macOS 14+) is deliberately absent here: Apple exposes no public API to
/// query it, so nothing in this file can honestly monitor it — see
/// `HostPermissionReport`.
public enum HostPermissionKind: String, Equatable, Sendable {
    case screenRecording = "Screen Recording"
    case accessibility = "Accessibility"
    case screenSharing = "Screen Sharing"
}

public enum HostPermissionTransition: Equatable, Sendable {
    case lost(HostPermissionKind)
    case recovered(HostPermissionKind)

    /// A self-contained line: what changed and what to do about it, so it
    /// reads correctly even torn out of surrounding log context.
    public var logLine: String {
        switch self {
        case .lost(.screenSharing):
            // Not a permission: nothing was revoked, and the switch lives in
            // Sharing rather than Privacy & Security.
            return "Screen Sharing is off. Until you turn it on in System Settings > General > Sharing, " +
                "your other machine cannot type at this machine\u{2019}s lock screen."
        case .recovered(.screenSharing):
            return "Screen Sharing is on."
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
    private let screenSharing: any ScreenSharingProbing
    private var lastScreenSharingStatus: ScreenSharingStatus = .notChecked

    public init(
        screenCapture: ScreenCapturePermissionGate,
        accessibility: AccessibilityPermissionGate,
        screenSharing: any ScreenSharingProbing,
        onTransition: @escaping (HostPermissionTransition) -> Void
    ) {
        self.screenCapture = screenCapture
        self.accessibility = accessibility
        self.screenSharing = screenSharing
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

    /// Probes Screen Sharing off the main actor -- a loopback connect can
    /// block for up to its timeout -- and reports a change the same way
    /// `poll()` does. The first call always reports, since nothing was known
    /// before it. Kept apart from `poll()` because it suspends.
    public func pollScreenSharing() async {
        let probe = screenSharing
        let isOn = await Task.detached(priority: .utility) {
            probe.isScreenSharingOn()
        }.value
        let status: ScreenSharingStatus = isOn ? .on : .off
        if status != lastScreenSharingStatus {
            lastScreenSharingStatus = status
            onTransition(isOn ? .recovered(.screenSharing) : .lost(.screenSharing))
        }
    }
}

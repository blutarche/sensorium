import Foundation
import SensoriumHost

/// A probe whose answer a test sets, and which records the thread it ran on.
final class FakeScreenSharingProbe: ScreenSharingProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var answer = false
    private var ranOnMainThread: [Bool] = []

    func set(_ isOn: Bool) {
        lock.withLock { answer = isOn }
    }

    var callsOnMainThread: [Bool] {
        lock.withLock { ranOnMainThread }
    }

    func isScreenSharingOn() -> Bool {
        let onMain = Thread.isMainThread
        return lock.withLock {
            ranOnMainThread.append(onMain)
            return answer
        }
    }
}

/// Records every address and port the real probe asks to connect to.
private final class ConnectRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(String, UInt16)] = []
    var accepts = false

    var targets: [(String, UInt16)] {
        lock.withLock { recorded }
    }

    func connect(_ address: String, _ port: UInt16, _ timeoutSeconds: Double) -> Bool {
        lock.withLock { recorded.append((address, port)) }
        return accepts
    }
}

@MainActor
func runHostScreenSharingAlertTests() async {
    let issuedAt = Date(timeIntervalSince1970: 1_000)
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    // Not knowing yet is not the same as off: nothing is asked of the person
    // at this machine until a probe has actually found the service off.
    let notChecked = HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted)
        .presentation(now: issuedAt)
    expect(
        notChecked.alerts.isEmpty,
        "a host that has not probed Screen Sharing yet shows no Screen Sharing alert"
    )

    let sharingOff = HostOperatorStatus(
        connection: .hosting(address: "203.0.113.42"),
        permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted, screenSharing: .off)
    ).presentation(now: issuedAt)
    expect(
        sharingOff.alerts.map(\.kind) == [.screenSharing],
        "Screen Sharing found off shows exactly one Screen Sharing alert -- got: \(sharingOff.alerts.map(\.kind))"
    )
    if let alert = sharingOff.alerts.first {
        expect(alert.title == "Open Sharing Settings", "the menu item reads in Title Case -- got: \(alert.title)")
        expect(
            alert.windowButtonTitle == "Open Sharing settings",
            "the window button reads in sentence case -- got: \(alert.windowButtonTitle)"
        )
        expect(
            alert.detail == "Until you turn on Screen Sharing, your other machine cannot type at this machine\u{2019}s lock screen.",
            "the detail names what stops working, in the panel's own typography -- got: \(alert.detail)"
        )
        expect(
            alert.settingsURL == "x-apple.systempreferences:com.apple.preferences.sharing?Services_ScreenSharing",
            "the alert opens the Sharing pane at Screen Sharing -- got: \(alert.settingsURL)"
        )
        expect(
            !alert.detail.contains("Mac") && !alert.title.contains("Mac"),
            "the copy says this machine and your other machine, never a product category"
        )
    }
    expect(
        sharingOff.indicator == .attention,
        "a missing Screen Sharing turns the menu-bar icon to attention, as a missing Accessibility grant does"
    )
    let accessibilityOff = HostOperatorStatus(
        connection: .hosting(address: "203.0.113.42"),
        permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .approvalRequired)
    ).presentation(now: issuedAt)
    expect(
        sharingOff.indicator == accessibilityOff.indicator
            && sharingOff.eyebrow == accessibilityOff.eyebrow
            && sharingOff.headline == accessibilityOff.headline
            && sharingOff.screenRecordingReplacesStatusCard == accessibilityOff.screenRecordingReplacesStatusCard,
        "Screen Sharing off leaves the status card exactly as Accessibility missing does"
    )

    let sharingOn = HostOperatorStatus(
        connection: .hosting(address: "203.0.113.42"),
        permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted, screenSharing: .on)
    ).presentation(now: issuedAt)
    expect(sharingOn.alerts.isEmpty, "Screen Sharing found on shows no alert")
    expect(sharingOn.indicator == .idle, "Screen Sharing found on leaves the icon at rest")

    let allMissing = HostOperatorStatus(
        connection: .hosting(address: "203.0.113.42"),
        permissions: HostPermissionRequestResult(
            screenCapture: .approvalRequired,
            accessibility: .approvalRequired,
            screenSharing: .off
        )
    ).presentation(now: issuedAt)
    expect(
        allMissing.alerts.map(\.kind) == [.screenRecording, .accessibility, .screenSharing],
        "Screen Sharing is listed after Accessibility -- got: \(allMissing.alerts.map(\.kind))"
    )

    // The store folds the monitor's transitions in, and an unrelated
    // permission changing never resets what the probe found.
    let store = HostOperatorStatusStore(permissions: granted)
    store.apply(.lost(.screenSharing))
    expect(
        store.status.presentation(now: issuedAt).alerts.map(\.kind) == [.screenSharing],
        "a probe finding Screen Sharing off raises the alert"
    )
    store.apply(.lost(.accessibility))
    store.apply(.recovered(.accessibility))
    store.apply(.lost(.screenRecording))
    store.apply(.recovered(.screenRecording))
    expect(
        store.status.permissions.screenSharing == .off,
        "Accessibility and Screen Recording changing leave Screen Sharing as the probe last found it"
    )
    store.apply(.recovered(.screenSharing))
    expect(
        store.status.presentation(now: issuedAt).alerts.isEmpty,
        "a probe finding Screen Sharing on again takes the alert away"
    )

    let lostLine = HostPermissionTransition.lost(.screenSharing).logLine
    expect(
        lostLine.contains("Screen Sharing") && lostLine.contains("lock screen")
            && !lostLine.contains("revoked") && !lostLine.contains("Privacy & Security"),
        "the log line for Screen Sharing off says what stops working and where to turn it on -- got: \(lostLine)"
    )

    // The monitor: the probe runs off the main actor, and each change is
    // reported once.
    let probe = FakeScreenSharingProbe()
    var transitions: [HostPermissionTransition] = []
    let screenCaptureChecker = FakeScreenCapturePermissionChecker()
    screenCaptureChecker.isAuthorized = true
    let accessibilityChecker = FakeAccessibilityPermissionChecker()
    accessibilityChecker.isTrusted = true
    let monitor = HostPermissionMonitor(
        screenCapture: ScreenCapturePermissionGate(checker: screenCaptureChecker),
        accessibility: AccessibilityPermissionGate(checker: accessibilityChecker),
        screenSharing: probe,
        onTransition: { transitions.append($0) }
    )
    expect(probe.callsOnMainThread.isEmpty, "constructing the monitor probes nothing")
    monitor.poll()
    expect(probe.callsOnMainThread.isEmpty, "the synchronous permission poll never probes Screen Sharing")

    await monitor.pollScreenSharing()
    expect(
        transitions == [.lost(.screenSharing)],
        "the first probe always reports what it found -- got: \(transitions)"
    )
    expect(
        probe.callsOnMainThread == [false],
        "the probe runs off the main actor -- got: \(probe.callsOnMainThread)"
    )
    await monitor.pollScreenSharing()
    expect(transitions == [.lost(.screenSharing)], "an unchanged finding is reported once")
    probe.set(true)
    await monitor.pollScreenSharing()
    expect(
        transitions == [.lost(.screenSharing), .recovered(.screenSharing)],
        "Screen Sharing turned on is reported once -- got: \(transitions)"
    )
    expect(
        probe.callsOnMainThread.allSatisfy { !$0 },
        "every probe runs off the main actor -- got: \(probe.callsOnMainThread)"
    )

    // The real probe, its socket replaced: it only ever asks for this
    // machine's own loopback Screen Sharing port, and reads a refused
    // connection as off and an accepted one as on.
    let recorder = ConnectRecorder()
    let realProbe = LoopbackScreenSharingProbe(connect: recorder.connect)
    expect(!realProbe.isScreenSharingOn(), "a refused loopback connection reads as Screen Sharing off")
    recorder.accepts = true
    expect(realProbe.isScreenSharingOn(), "an accepted loopback connection reads as Screen Sharing on")
    expect(
        recorder.targets.count == 2 && recorder.targets.allSatisfy { $0.0 == "127.0.0.1" && $0.1 == 5900 },
        "the probe targets 127.0.0.1:5900 and nothing else -- got: \(recorder.targets)"
    )
    expect(
        LoopbackScreenSharingProbe.address == "127.0.0.1" && LoopbackScreenSharingProbe.port == 5900,
        "the probe's one target is this machine's loopback Screen Sharing port"
    )
    expect(
        LoopbackScreenSharingProbe.timeoutSeconds > 0 && LoopbackScreenSharingProbe.timeoutSeconds <= 2,
        "the probe gives up quickly -- got: \(LoopbackScreenSharingProbe.timeoutSeconds)"
    )

    let reportLines = HostPermissionReport.lines(
        result: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted, screenSharing: .off),
        launchContext: .notTerminalAttached
    )
    expect(
        reportLines.contains("Screen Sharing: off"),
        "request-permissions reports Screen Sharing's state when it is known -- got: \(reportLines)"
    )

    let requestScreenCaptureChecker = FakeScreenCapturePermissionChecker()
    requestScreenCaptureChecker.isAuthorized = true
    let requestAccessibilityChecker = FakeAccessibilityPermissionChecker()
    requestAccessibilityChecker.isTrusted = true
    let requestProbe = FakeScreenSharingProbe()
    let requested = HostPermissionRequester.request(
        screenCapture: ScreenCapturePermissionGate(checker: requestScreenCaptureChecker),
        accessibility: AccessibilityPermissionGate(checker: requestAccessibilityChecker),
        screenSharing: requestProbe
    )
    expect(
        requested.screenSharing == .off && requestProbe.callsOnMainThread.count == 1,
        "request-permissions probes Screen Sharing once and carries what it found -- got: \(requested.screenSharing)"
    )
    expect(
        requested.isReadyForViewerControl,
        "Screen Sharing off does not make request-permissions report the host unready"
    )
}

import CoreGraphics
import Foundation
import SensoriumHost

/// `CoreGraphicsHostScreenRelockPoster` posts macOS's own Lock Screen
/// shortcut, Control-Command-Q, at the hid tap -- the same tap a system
/// hotkey needs to reach the window server ahead of the session tap.
func runHostScreenRelockPosterTests() {
    let recorder = RecordedRelockPosts()
    // An explicit spy, not the default `MutableHostInjectedHIDActivity.shared`:
    // this poster's own `relock()` below really does post at `.cghidEventTap`,
    // and the shared singleton must never carry state one test group leaves
    // behind into another that reads real `hidSystemState` through it.
    let poster = CoreGraphicsHostScreenRelockPoster(hostInjectedHIDActivity: SpyRelockPosterHIDActivity()) { event, tap in
        recorder.record(keyCode: event.getIntegerValueField(.keyboardEventKeycode), tap: tap, flags: event.flags)
    }

    expect(poster.relock(), "a relock that builds and posts both events reports success")

    expect(recorder.all.count == 2, "the shortcut is a key down and a key up, posted as two events")
    expect(recorder.all.allSatisfy { $0.tap == .cghidEventTap }, "both events reach the hid tap")
    expect(recorder.all.allSatisfy { $0.keyCode == 12 }, "both events carry kVK_ANSI_Q, the Lock Screen shortcut's key")
    expect(
        recorder.all.allSatisfy { $0.flags == [.maskControl, .maskCommand] },
        "both events carry exactly Control and Command, matching the documented shortcut"
    )

    print("PASS: the relock poster posts Control-Command-Q's key down and key up at the hid tap")

    let activity = SpyRelockPosterHIDActivity()
    let recordingPoster = CoreGraphicsHostScreenRelockPoster(
        hostInjectedHIDActivity: activity,
        postEvent: { _, _ in }
    )
    recordingPoster.relock()
    expect(
        activity.recordCount == 2,
        "each of the two posted events records into the host-injected hid activity, so a real person's later input is not confused with this one"
    )
    expect(
        activity.sampleCount == 2,
        "each of the two posted events samples before it records, so a real person's earlier input is not lost to it"
    )
    print("PASS: the relock poster samples and records each event it posts into the host-injected hid activity")
}

private final class RecordedRelockPosts: @unchecked Sendable {
    private(set) var all: [(keyCode: Int64, tap: CGEventTapLocation, flags: CGEventFlags)] = []

    func record(keyCode: Int64, tap: CGEventTapLocation, flags: CGEventFlags) {
        all.append((keyCode, tap, flags))
    }
}

private final class SpyRelockPosterHIDActivity: HostInjectedHIDActivity, @unchecked Sendable {
    private(set) var recordCount = 0
    private(set) var sampleCount = 0
    func recordPost() { recordCount += 1 }
    func secondsSinceLastPost() -> TimeInterval? { nil }
    func sampleBeforePost() { sampleCount += 1 }
    func secondsSinceProvenHardwareActivity() -> TimeInterval? { nil }
}

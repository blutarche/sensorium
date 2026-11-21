#if os(Linux)
import Foundation
import SensoriumHost
import SensoriumLinuxHost

/// A pill or tray stand-in that can be made to refuse.
@MainActor
final class StubIndicatorSurface: IndicatorPresenting {
    var onStop: (() -> Void)?
    var presented: [String] = []
    var dismissals = 0
    var failure: IndicatorError?

    func present(deviceName: String) throws {
        if let failure { throw failure }
        presented.append(deviceName)
    }

    func dismiss() {
        dismissals += 1
    }
}

@MainActor
private func badge(pill: StubIndicatorSurface, tray: StubIndicatorSurface) -> (HostScreenBadgeState, any HostScreenBadgeDisplaying) {
    let state = HostScreenBadgeState(content: HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Monitor"))
    let display = LinuxIndicatorBadge(state: state, indicator: LinuxHostIndicator(pill: pill, tray: tray))
    return (state, display)
}

@MainActor
private func testTheBadgeShowsAndHidesTheIndicatorNamingTheDevice() async {
    let pill = StubIndicatorSurface()
    let tray = StubIndicatorSurface()
    let (_, display) = badge(pill: pill, tray: tray)
    do {
        try display.show()
    } catch {
        expect(false, "the pill could be shown, so show succeeds, threw \(error)")
    }
    expect(pill.presented == ["Kestrel Laptop Pro"], "the pill names the connected device")
    expect(tray.presented == ["Kestrel Laptop Pro"], "the tray item names the connected device")
    display.hide()
    expect(pill.dismissals == 1 && tray.dismissals == 1, "hide takes both down")
}

@MainActor
private func testABadgeWhosePillCannotShowThrowsSoTheSessionIsRefused() async {
    let pill = StubIndicatorSurface()
    pill.failure = .layerShellUnavailable
    let (_, display) = badge(pill: pill, tray: StubIndicatorSurface())
    do {
        try display.show()
        expect(false, "a pill that cannot be shown must make show throw")
    } catch {
        expect(error as? IndicatorError == .layerShellUnavailable, "the indicator's own reason is passed on, saw \(error)")
    }
}

@MainActor
private func testStopOnTheIndicatorStopsTheBadgeState() async {
    let pill = StubIndicatorSurface()
    let (state, display) = badge(pill: pill, tray: StubIndicatorSurface())
    var stops = 0
    state.onStop = { stops += 1 }
    try? display.show()
    pill.onStop?()
    pill.onStop?()
    expect(state.hasStopped, "the pill's Stop is the badge's Stop")
    expect(stops == 1, "Stop ends the session once, saw \(stops)")
}

func indicatorBadgeTests() -> [NamedTest] { [
    ("the badge shows and hides the indicator naming the device", testTheBadgeShowsAndHidesTheIndicatorNamingTheDevice),
    ("a badge whose pill cannot show throws, so the session is refused", testABadgeWhosePillCannotShowThrowsSoTheSessionIsRefused),
    ("Stop on the indicator stops the badge state", testStopOnTheIndicatorStopsTheBadgeState)
] }
#endif

#if os(Linux)
import Foundation
import SensoriumLinuxHost

/// A stand-in for the pill or the tray that records what it was asked.
@MainActor
private final class RecordingSurface: IndicatorPresenting {
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

private func globals(_ interfaces: [String]) -> [WaylandGlobal] {
    interfaces.enumerated().map { WaylandGlobal(name: UInt32($0.offset + 1), interface: $0.element, version: 4) }
}

@MainActor
enum ShowTests {
    static let all: [(String, () async -> Void)] = [
        ("a compositor without layer shell cannot show the pill", testACompositorWithoutLayerShellCannotShowThePill),
        ("a display nobody serves cannot show the pill", testADisplayNobodyServesCannotShowThePill),
        ("show throws when the pill cannot be shown, and shows nothing", testShowThrowsWhenThePillCannotBeShown),
        ("a missing tray does not refuse the session", testAMissingTrayDoesNotRefuseTheSession),
        ("Stop from the pill or the tray stops once, and only while shown", testStopFromEitherSurfaceStopsOnce)
    ]

    static func testACompositorWithoutLayerShellCannotShowThePill() async {
        let complete = ["wl_compositor", "wl_shm", "wl_output", "wl_seat", "zwlr_layer_shell_v1"]
        do {
            try LayerShellSupport.check(globals(complete))
        } catch {
            expect(false, "a compositor with every global can show the pill, got \(error)")
        }
        func refusal(_ interfaces: [String]) -> IndicatorError? {
            do {
                try LayerShellSupport.check(globals(interfaces))
                return nil
            } catch {
                return error as? IndicatorError
            }
        }
        let withoutLayerShell = complete.filter { $0 != "zwlr_layer_shell_v1" }
        expect(refusal(withoutLayerShell) == .layerShellUnavailable, "no layer-shell global means no pill")
        expect(refusal([]) == .layerShellUnavailable, "an empty registry has no layer shell")
        expect(refusal(complete.filter { $0 != "wl_output" }) == .noOutputs, "no output means nowhere to show the pill")
        expect(refusal(complete.filter { $0 != "wl_shm" }) == .compositorIncomplete("wl_shm"), "no shared memory means nothing to draw with")
        expect(refusal(complete.filter { $0 != "wl_compositor" }) == .compositorIncomplete("wl_compositor"), "no compositor global means no surface")
    }

    static func testADisplayNobodyServesCannotShowThePill() async {
        let presenter = LayerShellPillPresenter(displayName: "sensorium-test-no-such-display")
        do {
            try presenter.present(deviceName: "Studio Desktop")
            expect(false, "showing on a display nobody serves must throw")
        } catch let error as IndicatorError {
            if case .noDisplay = error {} else { expect(false, "the refusal names the missing display, got \(error)") }
        } catch {
            expect(false, "the refusal is an IndicatorError, got \(error)")
        }
        presenter.dismiss()
    }

    static func testShowThrowsWhenThePillCannotBeShown() async {
        let pill = RecordingSurface()
        let tray = RecordingSurface()
        pill.failure = .layerShellUnavailable
        let indicator = LinuxHostIndicator(pill: pill, tray: tray)
        do {
            try indicator.show(deviceName: "Studio Desktop")
            expect(false, "show must throw when the pill cannot be shown")
        } catch {
            expect((error as? IndicatorError) == .layerShellUnavailable, "show throws the pill's own error")
        }
        expect(tray.presented.isEmpty, "no tray item appears for a session that is refused")
        indicator.hide()
        expect(tray.dismissals == 0 && pill.dismissals == 0, "hiding what never showed touches nothing")
    }

    static func testAMissingTrayDoesNotRefuseTheSession() async {
        let pill = RecordingSurface()
        let tray = RecordingSurface()
        tray.failure = .surfaceRefused
        let indicator = LinuxHostIndicator(pill: pill, tray: tray)
        do {
            try indicator.show(deviceName: "Studio Desktop")
        } catch {
            expect(false, "a tray that cannot be shown must not refuse the session, got \(error)")
        }
        expect(pill.presented == ["Studio Desktop"], "the pill is shown")
    }

    static func testStopFromEitherSurfaceStopsOnce() async {
        let pill = RecordingSurface()
        let tray = RecordingSurface()
        let indicator = LinuxHostIndicator(pill: pill, tray: tray)
        var stops = 0
        indicator.onStop = { stops += 1 }

        pill.onStop?()
        expect(stops == 0, "Stop before the indicator is shown does nothing")

        try? indicator.show(deviceName: "Studio Desktop")
        expect(pill.presented == ["Studio Desktop"] && tray.presented == ["Studio Desktop"], "both surfaces name the device")
        pill.onStop?()
        tray.onStop?()
        pill.onStop?()
        expect(stops == 1, "Stop stops once however many times it is pressed")

        indicator.hide()
        expect(pill.dismissals >= 1 && tray.dismissals >= 1, "hide removes both surfaces")
        pill.onStop?()
        expect(stops == 1, "Stop after hide does nothing")

        try? indicator.show(deviceName: "Another Desktop")
        tray.onStop?()
        expect(stops == 2, "a new session's Stop works again")
        indicator.hide()
    }
}
#endif

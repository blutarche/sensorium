import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// A host-screen session on a headless host: the controller moving its
/// surface onto the sharp screen or onto a placeholder that came back under a
/// new ID, and the coordinator streaming, recovering and ending around the
/// sharp screen. Built on `SharpScreenManagerTests.swift`'s fake headless
/// host; nothing here creates or changes a real display.

private let sharpModeEntry = HostScreenModeEntry(
    modeID: "3840x2160@1920x1080@60",
    width: 1920,
    height: 1080,
    pixelWidth: 3840,
    pixelHeight: 2160,
    refreshRate: 60,
    isHiDPI: true
)

private let sharpOtherModeEntry = HostScreenModeEntry(
    modeID: "2560x1440@1280x720@60",
    width: 1280,
    height: 720,
    pixelWidth: 2560,
    pixelHeight: 1440,
    refreshRate: 60,
    isHiDPI: true
)

/// Offers this connection its host screen and asks for the first entry,
/// straight through the controller.
@MainActor
private func admitFirstOffered(_ controller: HostSessionController) -> SessionSurfaceGeometry? {
    guard case let .hostScreenList(entries, _) = try! controller.offerHostScreenList(),
          let entry = entries.first,
          case let .hostScreenReady(geometry, _) = try! controller.handle(
              .hostScreenRequest(token: entry.opaqueToken, resumeTicket: nil)
          ) else {
        return nil
    }
    return geometry
}

@MainActor
func runSharpScreenSessionTests() async {
    do {
        let host = FakeHeadlessHost()
        let modes = FakeHostScreenModeController()
        let injectors = FakeInputInjectorFactory()
        let wake = DisplayWakeController(power: FakeDisplayPower(), displays: { host.read() }, wait: { _ in })
        let controller = armedHostScreenController(
            displays: host.list, displayWake: wake, log: { _ in },
            modeController: modes, inputInjectorFactory: injectors
        )
        let placeholderID = host.placeholderID
        let admitted = admitFirstOffered(controller)
        expect(
            admitted == SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1080, backingScale: 1),
            "the session is admitted on the placeholder at its own 1x geometry, got \(String(describing: admitted))"
        )
        _ = try! host.create(configuration: SharpScreen.configuration, identity: SharpScreen.identity)
        let sharpID = host.sharpID!
        modes.modesByDisplay[sharpID] = [sharpModeEntry, sharpOtherModeEntry]
        modes.currentModeIDByDisplay[sharpID] = sharpModeEntry.modeID

        let rebound = controller.rebindHostScreen(toDisplayID: sharpID, isSharpScreen: true)
        expect(
            rebound == SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1080, backingScale: 2),
            "moved onto the sharp screen, the session is at 1920x1080 and 2x, got \(String(describing: rebound))"
        )
        expect(controller.hostScreenDisplayID == sharpID, "the session now names the sharp screen's display")
        expect(controller.hostScreenGeometry == rebound, "and its geometry")
        expect(controller.hostScreenDisplayLabel == "External Display", "the label the viewer chose is unchanged")
        expect(
            controller.hostScreenDisplayIdentity == HostScreenDisplayIdentity(placeholderSnapshot(id: placeholderID)),
            "and so is the identity the session was admitted for"
        )
        expect(
            injectors.requestedDisplayIDs == [placeholderID, sharpID],
            "input is posted against the sharp screen from now on, got \(injectors.requestedDisplayIDs)"
        )
        expect(controller.hostScreenModeListMessage() == nil, "a session on the sharp screen offers the viewer no display modes")
        let reply = try! controller.handle(.hostScreenModeRequest(modeID: sharpOtherModeEntry.modeID))
        expect(
            reply == .hostScreenModeRefused(reason: HostScreenModeRefusalReason.unknown),
            "a mode change asked for anyway is refused, got \(String(describing: reply))"
        )
        expect(modes.applied.isEmpty, "and the sharp screen's mode is never touched")
        _ = try! controller.handle(.goodbye(reason: GoodbyeReason.stoppedByHost))
        expect(modes.restoredDisplayIDs.isEmpty, "and nothing is restored at the end")
    }
    print("PASS: a session moved onto the sharp screen streams it at 2x, posts input to it, and never changes its mode")

    do {
        let host = FakeHeadlessHost()
        let injectors = FakeInputInjectorFactory()
        let wake = DisplayWakeController(power: FakeDisplayPower(), displays: { host.read() }, wait: { _ in })
        let controller = armedHostScreenController(
            displays: host.list, displayWake: wake, log: { _ in }, inputInjectorFactory: injectors
        )
        let original = host.placeholderID
        expect(admitFirstOffered(controller) != nil, "the session is admitted on the placeholder")
        expect(!controller.rebindHostScreenToReplacedPlaceholder(), "a placeholder still under its own ID is left alone")
        host.renumberPlaceholder()
        expect(controller.hostScreenTargetAvailability() == .notOnline, "the placeholder's old ID is gone")
        expect(
            controller.rebindHostScreenToReplacedPlaceholder(),
            "a session on the placeholder follows it to its new ID"
        )
        expect(controller.hostScreenDisplayID == host.placeholderID, "the session names the new ID")
        expect(controller.hostScreenTargetAvailability() == nil, "and its target is available again")
        expect(injectors.requestedDisplayIDs == [original, host.placeholderID], "input follows it too")

        host.monitorConnected = true
        expect(!controller.rebindHostScreenToReplacedPlaceholder(), "with a monitor connected there is no placeholder to follow")
    }
    print("PASS: a session on macOS's placeholder screen follows it when it comes back under a new ID, and only then")

    do {
        let list = FakeDisplayList([monitorSnapshot(id: 2)])
        let wake = DisplayWakeController(power: FakeDisplayPower(), displays: { list.read() }, wait: { _ in })
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        expect(admitFirstOffered(controller) != nil, "the session is admitted on the monitor")
        list.displays = [placeholderSnapshot(id: 4)]
        expect(
            !controller.rebindHostScreenToReplacedPlaceholder(),
            "a session on a monitor never moves onto the placeholder that replaced it"
        )
        expect(controller.hostScreenDisplayID == 2, "it still names the monitor")
    }
    print("PASS: a session on a monitor is never moved onto macOS's placeholder screen")
}

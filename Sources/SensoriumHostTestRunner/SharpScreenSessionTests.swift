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

/// Every display ID the host-screen media factory was asked to capture,
/// which is also the display the badge and the session record name.
@MainActor
private final class MediaDisplayRecorder {
    private(set) var displayIDs: [UInt32] = []
    func record(_ id: UInt32) { displayIDs.append(id) }
}

/// A host-screen connection on a headless host, wired the way `sensoriumd`
/// wires one: a process-wide sharp-screen manager shared with the
/// coordinator, and a controller reading the same display list.
@MainActor
private struct SharpScreenSessionFixture {
    let host: FakeHeadlessHost
    let manager: SharpScreenManager
    let managerLog: DiagnosticsRecorder
    let modes: FakeHostScreenModeController
    let controller: HostSessionController
    let coordinator: HostSessionCoordinator
    let media: FakeScalableCanvasMedia
    let mediaDisplays: MediaDisplayRecorder
    let events: DiagnosticsRecorder
    let unrecoverable: DiagnosticsRecorder
    let power: FakeDisplayPower

    init(
        host: FakeHeadlessHost = FakeHeadlessHost(),
        manager: SharpScreenManager? = nil,
        runtimeAvailable: Bool = true,
        recoveryBoundSeconds: Double = 0.2
    ) {
        self.host = host
        let managerLog = DiagnosticsRecorder()
        self.managerLog = managerLog
        let manager = manager ?? makeSharpScreenManager(
            host: host, log: managerLog, runtimeAvailable: runtimeAvailable
        )
        self.manager = manager
        let modes = FakeHostScreenModeController()
        modes.modesByDisplay[host.placeholderID] = [HostScreenModeEntry(
            modeID: "1920x1080@1920x1080@60", width: 1920, height: 1080,
            pixelWidth: 1920, pixelHeight: 1080, refreshRate: 60, isHiDPI: false
        )]
        modes.currentModeIDByDisplay[host.placeholderID] = "1920x1080@1920x1080@60"
        for id in UInt32(20)...UInt32(30) {
            modes.modesByDisplay[id] = [sharpModeEntry, sharpOtherModeEntry]
            modes.currentModeIDByDisplay[id] = sharpModeEntry.modeID
        }
        self.modes = modes
        let power = FakeDisplayPower()
        self.power = power
        let wake = DisplayWakeController(power: power, displays: { host.read() }, wait: { _ in })
        let controller = armedHostScreenController(
            displays: host.list, displayWake: wake, log: { _ in }, modeController: modes
        )
        self.controller = controller
        let media = FakeScalableCanvasMedia()
        self.media = media
        let mediaDisplays = MediaDisplayRecorder()
        self.mediaDisplays = mediaDisplays
        let events = DiagnosticsRecorder()
        self.events = events
        let unrecoverable = DiagnosticsRecorder()
        self.unrecoverable = unrecoverable
        coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            onEvent: { events.record($0) },
            onStreamUnrecoverable: { unrecoverable.record($0) },
            hostScreenMediaFactory: { _, displayID in
                mediaDisplays.record(displayID)
                return media
            },
            hostScreenCaptureRecoveryBoundSeconds: recoveryBoundSeconds,
            hostScreenCaptureRecoveryPollSeconds: 0.05,
            hostScreenCaptureRecoveryWait: { _ in },
            sharpScreens: manager
        )
    }

    /// Offers and asks for the first entry through the coordinator, the way
    /// `HostNetworkSession` does, and returns everything written back.
    func start() async -> [SensoriumMessage] {
        guard case let .hostScreenList(entries, _) = try! controller.offerHostScreenList(),
              let entry = entries.first else {
            expect(false, "the fixture's offer names a display")
            return []
        }
        var written: [SensoriumMessage] = []
        _ = try! await coordinator.handle(.hostScreenRequest(token: entry.opaqueToken, resumeTicket: nil)) { message in
            written.append(message)
        }
        return written
    }
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
        // A sharp screen an earlier host left behind, which this process
        // does not manage, admitted directly.
        let list = FakeDisplayList([sharpScreenSnapshot(id: 30)])
        let modes = FakeHostScreenModeController()
        modes.modesByDisplay[30] = [sharpModeEntry, sharpOtherModeEntry]
        modes.currentModeIDByDisplay[30] = sharpModeEntry.modeID
        let wake = DisplayWakeController(power: FakeDisplayPower(), displays: { list.read() }, wait: { _ in })
        let controller = armedHostScreenController(
            displays: list, displayWake: wake, log: { _ in }, modeController: modes
        )
        let admitted = admitFirstOffered(controller)
        expect(
            admitted == SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1080, backingScale: 2),
            "the leftover sharp screen is admitted at its own 2x geometry, got \(String(describing: admitted))"
        )
        expect(controller.hostScreenModeListMessage() == nil, "a leftover sharp screen offers the viewer no display modes")
        let reply = try! controller.handle(.hostScreenModeRequest(modeID: sharpOtherModeEntry.modeID))
        expect(
            reply == .hostScreenModeRefused(reason: HostScreenModeRefusalReason.unknown),
            "a mode change on it is refused, got \(String(describing: reply))"
        )
        expect(modes.applied.isEmpty, "and its mode is never touched")
    }
    print("PASS: a sharp screen an earlier host left behind streams at its one size, with no mode changes")

    do {
        let host = FakeHeadlessHost()
        let injectors = FakeInputInjectorFactory()
        let wake = DisplayWakeController(power: FakeDisplayPower(), displays: { host.read() }, wait: { _ in })
        let controller = armedHostScreenController(
            displays: host.list, displayWake: wake, log: { _ in }, inputInjectorFactory: injectors
        )
        let original = host.placeholderID
        expect(admitFirstOffered(controller) != nil, "the session is admitted on the placeholder")
        expect(
            controller.rebindHostScreenToReplacedPlaceholder() == .notNeeded,
            "a placeholder still under its own ID is left alone"
        )
        host.renumberPlaceholder()
        expect(controller.hostScreenTargetAvailability() == .notOnline, "the placeholder's old ID is gone")
        expect(
            controller.rebindHostScreenToReplacedPlaceholder() == .rebound(displayID: host.placeholderID),
            "a session on the placeholder follows it to its new ID"
        )
        expect(controller.hostScreenDisplayID == host.placeholderID, "the session names the new ID")
        expect(controller.hostScreenTargetAvailability() == nil, "and its target is available again")
        expect(injectors.requestedDisplayIDs == [original, host.placeholderID], "input follows it too")

        let followed = host.placeholderID
        host.list.displays = [canvasSnapshot(id: 91)]
        expect(
            controller.rebindHostScreenToReplacedPlaceholder() == .notFound,
            "with no placeholder online and no monitor, there is nothing to follow yet"
        )
        host.monitorConnected = true
        let reply = controller.rebindHostScreenToReplacedPlaceholder()
        expect(
            reply == .replacedByMonitor,
            "with a monitor connected the placeholder is not coming back, got \(reply)"
        )
        expect(controller.hostScreenDisplayID == followed, "and the session is left where it was")
    }
    print("PASS: a session on macOS's placeholder screen follows it when it comes back under a new ID, and only then")

    do {
        let list = FakeDisplayList([monitorSnapshot(id: 2)])
        let wake = DisplayWakeController(power: FakeDisplayPower(), displays: { list.read() }, wait: { _ in })
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        expect(admitFirstOffered(controller) != nil, "the session is admitted on the monitor")
        list.displays = [placeholderSnapshot(id: 4)]
        expect(
            controller.rebindHostScreenToReplacedPlaceholder() == .notNeeded,
            "a session on a monitor never moves onto the placeholder that replaced it"
        )
        expect(controller.hostScreenDisplayID == 2, "it still names the monitor")
    }
    print("PASS: a session on a monitor is never moved onto macOS's placeholder screen")

    do {
        let fixture = SharpScreenSessionFixture()
        let placeholderID = fixture.host.placeholderID
        let written = await fixture.start()
        guard case let .hostScreenReady(geometry, _) = written.first else {
            expect(false, "the session is admitted, got \(written)")
            return
        }
        let sharpID = fixture.host.sharpID
        expect(sharpID != nil, "a session on macOS's placeholder screen creates the sharp screen")
        expect(
            geometry == SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1080, backingScale: 2),
            "the viewer is told the sharp screen's 2x geometry, got \(geometry)"
        )
        expect(
            fixture.mediaDisplays.displayIDs == [sharpID ?? 0],
            "capture, the badge and the session record all name the sharp screen, got \(fixture.mediaDisplays.displayIDs)"
        )
        expect(fixture.media.startedDisplayIDs == [sharpID ?? 0], "and capture starts on it")
        expect(
            !written.contains { if case .hostScreenModeList = $0 { return true } else { return false } },
            "no display modes are offered for it, got \(written)"
        )
        expect(fixture.controller.hostScreenDisplayLabel == "External Display", "the session keeps the label the viewer chose")
        expect(
            fixture.controller.hostScreenDisplayIdentity == HostScreenDisplayIdentity(placeholderSnapshot(id: placeholderID)),
            "and the identity it was admitted for"
        )
        expect(
            fixture.events.messages.contains { $0.hasPrefix("host screen started for") },
            "the session starts as any host-screen session does, got \(fixture.events.messages)"
        )

        _ = try! await fixture.coordinator.handle(.goodbye(reason: GoodbyeReason.stoppedByHost)) { _ in }
        expect(fixture.host.destroyedHandles.isEmpty, "the sharp screen outlives the session for the grace period")
        _ = await waitUntil(timeoutSeconds: 2) { !fixture.host.destroyedHandles.isEmpty }
        expect(
            fixture.host.destroyedHandles == [VirtualDisplayHandle(rawValue: sharpID ?? 0)],
            "and is released once it has passed, got \(fixture.host.destroyedHandles)"
        )
    }
    print("PASS: a host-screen session on macOS's placeholder screen streams the sharp screen at 2x, under the label the viewer chose")

    do {
        let host = FakeHeadlessHost()
        host.sharpScreenReportsNoMode = true
        let fixture = SharpScreenSessionFixture(host: host)
        let original = host.placeholderID
        let written = await fixture.start()
        guard case let .hostScreenReady(geometry, _) = written.first else {
            expect(false, "the session is still admitted when the sharp screen is not usable, got \(written)")
            return
        }
        expect(
            geometry == SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1080, backingScale: 1),
            "it streams the placeholder at its own 1x geometry, got \(geometry)"
        )
        expect(host.placeholderID != original, "the placeholder came back under a new ID")
        expect(
            fixture.mediaDisplays.displayIDs == [host.placeholderID],
            "and the session streams it there, not the ID it was admitted on, got \(fixture.mediaDisplays.displayIDs)"
        )
        expect(
            fixture.managerLog.messages.filter { $0.contains("sharp screen not used") }.count == 1,
            "the host log says once why the sharp screen was not used, got \(fixture.managerLog.messages)"
        )
        expect(!fixture.coordinator.hasEnded, "and the session goes on")
    }
    print("PASS: a session whose sharp screen never becomes usable streams the placeholder as today, under its new ID")

    do {
        let fixture = SharpScreenSessionFixture()
        _ = await fixture.start()
        let sharpID = fixture.host.sharpID ?? 0
        fixture.host.monitorConnected = true
        fixture.manager.displaysChanged()
        _ = await waitUntil(timeoutSeconds: 2) { !fixture.unrecoverable.messages.isEmpty }
        expect(fixture.coordinator.hasEnded, "a monitor connected mid-session ends the session on the sharp screen")
        expect(
            fixture.unrecoverable.messages == [SharpScreenManager.monitorConnectedReason],
            "with the plain monitor reason, got \(fixture.unrecoverable.messages)"
        )
        expect(
            fixture.events.messages.contains { $0.contains(SharpScreenManager.monitorConnectedReason) },
            "which the host log carries, got \(fixture.events.messages)"
        )
        expect(fixture.media.stopCount == 1, "its capture is stopped, got \(fixture.media.stopCount)")
        expect(
            fixture.host.destroyedHandles == [VirtualDisplayHandle(rawValue: sharpID)],
            "and the sharp screen is released, got \(fixture.host.destroyedHandles)"
        )
    }
    print("PASS: a monitor connected mid-session ends the session on the sharp screen with a plain reason")

    do {
        let fixture = SharpScreenSessionFixture(recoveryBoundSeconds: 30)
        _ = await fixture.start()
        let sharpID = fixture.host.sharpID ?? 0
        let declarationsBefore = fixture.power.userActivityDeclarations
        fixture.media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { fixture.media.keyFrameRequestCount > 0 }
        expect(
            fixture.media.startedDisplayIDs == [sharpID, sharpID],
            "a capture that stops on the sharp screen is restarted on it, got \(fixture.media.startedDisplayIDs)"
        )
        expect(
            fixture.power.userActivityDeclarations == declarationsBefore,
            "without waking monitors this host does not have"
        )
        expect(!fixture.coordinator.hasEnded, "and the session goes on")

        fixture.host.sharpScreenVanished = true
        fixture.media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { fixture.coordinator.hasEnded && !fixture.unrecoverable.messages.isEmpty }
        expect(fixture.coordinator.hasEnded, "a sharp screen that went away ends the session at once, not after the recovery bound")
        expect(
            fixture.unrecoverable.messages == [SharpScreenManager.vanishedReason],
            "with a plain reason, got \(fixture.unrecoverable.messages)"
        )
    }
    print("PASS: a session on the sharp screen recovers through the manager, and ends at once when it is gone")

    do {
        let fixture = SharpScreenSessionFixture(runtimeAvailable: false, recoveryBoundSeconds: 30)
        let original = fixture.host.placeholderID
        _ = await fixture.start()
        expect(fixture.mediaDisplays.displayIDs == [original], "with no runtime the session streams the placeholder")
        fixture.host.renumberPlaceholder()
        fixture.media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { fixture.media.keyFrameRequestCount > 0 }
        expect(
            fixture.media.startedDisplayIDs == [original, fixture.host.placeholderID],
            "a placeholder that came back under a new ID is followed there, got \(fixture.media.startedDisplayIDs)"
        )
        expect(fixture.controller.hostScreenDisplayID == fixture.host.placeholderID, "and the session names it")
        expect(!fixture.coordinator.hasEnded, "the session goes on")

        fixture.host.monitorConnected = true
        fixture.media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { fixture.coordinator.hasEnded && !fixture.unrecoverable.messages.isEmpty }
        expect(fixture.coordinator.hasEnded, "a monitor replacing the placeholder ends the session at once, not after the bound")
        expect(
            fixture.unrecoverable.messages == [SharpScreenManager.monitorConnectedReason],
            "with the plain monitor reason, got \(fixture.unrecoverable.messages)"
        )
    }
    print("PASS: a session on macOS's placeholder screen follows it to a new ID, and ends at once when a monitor replaces it")

    do {
        let host = FakeHeadlessHost()
        let managerLog = DiagnosticsRecorder()
        let manager = makeSharpScreenManager(host: host, log: managerLog, releaseGraceSeconds: 60)
        let first = SharpScreenSessionFixture(host: host, manager: manager)
        _ = await first.start()
        let sharpID = host.sharpID ?? 0
        _ = try! await first.coordinator.handle(.goodbye(reason: GoodbyeReason.stoppedByHost)) { _ in }

        // The viewer reconnects within the grace period, on a new connection.
        let second = SharpScreenSessionFixture(host: host, manager: manager)
        guard case let .hostScreenList(entries, _) = try! second.controller.offerHostScreenList() else {
            expect(false, "the reconnect is offered a list")
            return
        }
        expect(
            entries.map(\.label) == ["External Display"]
                && entries.first?.displayIdentity == HostScreenDisplayIdentity(placeholderSnapshot(id: 4)).wireStableIdentifier,
            "the sharp screen is offered as the placeholder was, got \(entries)"
        )
        let written = await second.start()
        guard case let .hostScreenReady(geometry, _) = written.first else {
            expect(false, "the reconnect is admitted, got \(written)")
            return
        }
        expect(
            geometry == SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1080, backingScale: 2),
            "at the sharp screen's 2x geometry, got \(geometry)"
        )
        expect(second.mediaDisplays.displayIDs == [sharpID], "on the same sharp screen, got \(second.mediaDisplays.displayIDs)")
        expect(host.attemptedIdentities.count == 1, "nothing new is created for it")
        expect(
            !written.contains { if case .hostScreenModeList = $0 { return true } else { return false } },
            "and it offers no display modes, got \(written)"
        )
        let reply = try! second.controller.handle(.hostScreenModeRequest(modeID: sharpOtherModeEntry.modeID))
        expect(
            reply == .hostScreenModeRefused(reason: HostScreenModeRefusalReason.unknown),
            "a mode change on it is refused, got \(String(describing: reply))"
        )
        _ = await waitUntil(timeoutSeconds: 0.2) { !host.destroyedHandles.isEmpty }
        expect(host.destroyedHandles.isEmpty, "and it stays while the reconnected session uses it")
    }
    print("PASS: a viewer reconnecting within the grace period streams the same sharp screen, still with no mode changes")
}

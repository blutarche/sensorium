import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// A host-screen capture that stops on its own mid-session: ScreenCaptureKit's
/// own `SCStreamDelegate` signal, from a monitor that idled to sleep, briefly
/// went off the bus, or lost the "primary" role in a hardware mirror set to a
/// sibling display. The session survives and the capture is rebuilt on the
/// same display once it is confirmed available again -- these drive that
/// recovery directly, the same way `HostScreenFidelityTests.swift` drives the
/// tick-based silent-capture recovery beside it.
///
/// `armedHostScreenController` and `sleepingDisplaySnapshot` are
/// `DisplayWakeTests.swift`'s own fixtures, shared here rather than copied.

private let recoveryDisplayID: UInt32 = 3

@MainActor
private func recoveryTestDisplay(asleep: Bool = false, mirrorsDisplay: UInt32 = 0) -> DisplaySnapshot {
    DisplaySnapshot(
        id: recoveryDisplayID,
        pixelWidth: 5120,
        pixelHeight: 2880,
        modeWidth: 2560,
        modeHeight: 1440,
        modePixelWidth: 5120,
        modePixelHeight: 2880,
        bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        online: true,
        asleep: asleep,
        mirrorsDisplay: mirrorsDisplay,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

/// What a capture that cannot build against a display briefly unavailable --
/// still asleep, off the bus -- throws, standing in for ScreenCaptureKit's
/// own refusal.
private struct RecoveryStartError: Error {}

/// Blocks the first caller of `block()` until a test calls `release()`, so a
/// test can park an in-flight async operation at a known point and drive
/// something else while it waits there. Every call after the first passes
/// straight through, since `DisplayWakeController`'s settle wait can poll
/// more than once once the gate has done its job.
@MainActor
private final class RecoveryGate {
    private(set) var isWaiting = false
    private var hasBlockedOnce = false
    private var continuation: CheckedContinuation<Void, Never>?

    func block() async {
        guard !hasBlockedOnce else { return }
        hasBlockedOnce = true
        isWaiting = true
        await withCheckedContinuation { (k: CheckedContinuation<Void, Never>) in
            continuation = k
        }
        isWaiting = false
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

/// The mode this fixture's display starts on, and one a person might switch
/// to, matching `recoveryTestDisplay`'s own logical and pixel size.
private let recoveryCurrentMode = HostScreenModeEntry(
    modeID: "5120x2880@2560x1440@60",
    width: 2560,
    height: 1440,
    pixelWidth: 5120,
    pixelHeight: 2880,
    refreshRate: 60,
    isHiDPI: true
)

private let recoveryTargetMode = HostScreenModeEntry(
    modeID: "3840x2160@1920x1080@60",
    width: 1920,
    height: 1080,
    pixelWidth: 3840,
    pixelHeight: 2160,
    refreshRate: 60,
    isHiDPI: true
)

@MainActor
private func recoveryModeController() -> FakeHostScreenModeController {
    let modes = FakeHostScreenModeController()
    modes.modesByDisplay[recoveryDisplayID] = [recoveryCurrentMode, recoveryTargetMode]
    modes.currentModeIDByDisplay[recoveryDisplayID] = recoveryCurrentMode.modeID
    return modes
}

/// Admits a host-screen session on `controller` and brings its capture up
/// through `coordinator`, the same sequence `HostNetworkSession` drives.
@MainActor
private func startRecoveryHostScreenSession(
    controller: HostSessionController,
    coordinator: HostSessionCoordinator
) async throws {
    guard case let .hostScreenList(displays) = try controller.offerHostScreenList(), let entry = displays.first else {
        expect(false, "the fixture's offer names at least one display")
        return
    }
    // The reply comes back through the writer, and a fixture with a mode
    // controller writes its mode list and lock state straight after it, so
    // the first written message -- not the last, and not `handle`'s own
    // return, which this path answers through the writer instead -- is the
    // one that says the session was admitted.
    var written: [SensoriumMessage] = []
    _ = try await coordinator.handle(.hostScreenRequest(token: entry.opaqueToken, resumeTicket: nil)) { message in
        written.append(message)
    }
    guard case .hostScreenReady = written.first else {
        expect(false, "the fixture's host-screen request is admitted, got \(written)")
        return
    }
}

@MainActor
func runHostScreenCaptureRecoveryTests() async {
    do {
        // A capture that stops on its own is restarted on the same display
        // once it is available again, and the viewer gets a key frame.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let wake = DisplayWakeController(power: power, displays: { list.read() }, wait: { _ in })
        let events = DiagnosticsRecorder()
        let unrecoverable = DiagnosticsRecorder()
        let media = FakeScalableCanvasMedia()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            onEvent: { events.record($0) },
            onStreamUnrecoverable: { unrecoverable.record($0) },
            hostScreenMediaFactory: { _ in media },
            hostScreenCaptureRecoveryBoundSeconds: 0.2,
            hostScreenCaptureRecoveryPollSeconds: 0.05,
            hostScreenCaptureRecoveryWait: { _ in }
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)
        expect(media.startedDisplayIDs == [recoveryDisplayID], "the session's first capture starts on its own display")

        media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { media.keyFrameRequestCount > 0 }

        expect(
            media.startedDisplayIDs == [recoveryDisplayID, recoveryDisplayID],
            "the rebuilt capture starts again on the same display this session was admitted for, got \(media.startedDisplayIDs)"
        )
        expect(media.stopCount == 1, "the dead capture is stopped exactly once before the rebuild, got \(media.stopCount)")
        expect(
            media.keyFrameRequestCount == 1,
            "the viewer is sent a key frame the moment the picture is back, got \(media.keyFrameRequestCount)"
        )
        expect(!coordinator.hasEnded, "the session survives a capture that comes back")
        expect(unrecoverable.messages.isEmpty, "and nothing tells the viewer this session is unrecoverable")
        expect(
            events.messages.contains("host-screen display 3 capture recovered"),
            "the host log says the capture recovered, got \(events.messages)"
        )
    }
    print("PASS: a capture that stops on its own is restarted on the same display once it is available again, and the viewer gets a key frame")

    do {
        // A display that never comes back ends the session with the existing
        // reason after the bound.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let wake = DisplayWakeController(power: power, displays: { list.read() }, wait: { _ in })
        let events = DiagnosticsRecorder()
        let unrecoverable = DiagnosticsRecorder()
        let media = FakeScalableCanvasMedia()
        let availability = HostCaptureAvailability()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            onEvent: { events.record($0) },
            onStreamUnrecoverable: { unrecoverable.record($0) },
            hostScreenMediaFactory: { _ in media },
            captureAvailability: availability,
            hostScreenCaptureRecoveryBoundSeconds: 0.15,
            hostScreenCaptureRecoveryPollSeconds: 0.05,
            hostScreenCaptureRecoveryWait: { _ in }
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)

        // Gone for good: not merely asleep, not online at all any more.
        list.displays = []
        media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { coordinator.hasEnded }

        expect(coordinator.hasEnded, "a target display gone for good ends the session after the bound")
        expect(
            unrecoverable.messages == [GoodbyeReason.hostDisplaysAsleep],
            "with the same reason an unavailable host screen already ends a session with, got \(unrecoverable.messages)"
        )
        expect(
            events.messages.contains { $0.contains("did not come back") && $0.contains("not online") },
            "the host log names why, got \(events.messages)"
        )
        expect(
            !availability.isUnavailable,
            "a display that never came back is not this process losing its own ability to capture"
        )
        expect(
            media.startedDisplayIDs == [recoveryDisplayID],
            "and no capture is ever attempted against a display that was never found again, got \(media.startedDisplayIDs)"
        )
    }
    print("PASS: a display that never comes back ends the session with the existing reason after the bound")

    do {
        // A display that turned into a mirror member is never captured in
        // its place.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let wake = DisplayWakeController(power: power, displays: { list.read() }, wait: { _ in })
        let events = DiagnosticsRecorder()
        let unrecoverable = DiagnosticsRecorder()
        let media = FakeScalableCanvasMedia()
        let availability = HostCaptureAvailability()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            onEvent: { events.record($0) },
            onStreamUnrecoverable: { unrecoverable.record($0) },
            hostScreenMediaFactory: { _ in media },
            captureAvailability: availability,
            hostScreenCaptureRecoveryBoundSeconds: 0.2,
            hostScreenCaptureRecoveryPollSeconds: 0.05,
            hostScreenCaptureRecoveryWait: { _ in }
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)

        // The mirror set's "primary" role flipped onto another member: this
        // session's own display is online and awake, but now shows another
        // display's picture, never its own.
        list.displays = [recoveryTestDisplay(mirrorsDisplay: 7)]
        media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { coordinator.hasEnded }

        expect(coordinator.hasEnded, "a display that is now a mirror member ends the session")
        expect(
            unrecoverable.messages == [GoodbyeReason.hostDisplaysAsleep],
            "with the same reason an unavailable host screen already ends a session with, got \(unrecoverable.messages)"
        )
        expect(
            events.messages.contains { $0.contains("did not come back") && $0.contains("mirrored") },
            "the host log names why, got \(events.messages)"
        )
        expect(
            !availability.isUnavailable,
            "a display that became a mirror member is not this process losing its own ability to capture"
        )
        expect(
            media.startedDisplayIDs == [recoveryDisplayID],
            "and it is never captured in its place -- only the session's original start ever asked for it, got \(media.startedDisplayIDs)"
        )
    }
    print("PASS: a display that turned into a mirror member is never captured in its place")

    do {
        // A live host-screen session re-declares activity on the injected
        // interval, and stops at session end.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let wake = DisplayWakeController(power: power, displays: { list.read() }, wait: { _ in })
        let media = FakeScalableCanvasMedia()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            hostScreenMediaFactory: { _ in media },
            hostScreenKeepAwakeRedeclareIntervalSeconds: 5
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)

        let baseline = power.userActivityDeclarations
        await coordinator.tickFidelity(atSeconds: 0)
        expect(
            power.userActivityDeclarations == baseline + 1,
            "the first tick of a live host-screen session re-declares activity, got \(power.userActivityDeclarations - baseline)"
        )
        await coordinator.tickFidelity(atSeconds: 1)
        expect(
            power.userActivityDeclarations == baseline + 1,
            "a tick inside the injected interval does not re-declare again"
        )
        await coordinator.tickFidelity(atSeconds: 5)
        expect(
            power.userActivityDeclarations == baseline + 2,
            "a tick at the injected interval re-declares again"
        )
        await coordinator.tickFidelity(atSeconds: 6)
        expect(power.userActivityDeclarations == baseline + 2, "and again waits out the interval before the next one")
        await coordinator.tickFidelity(atSeconds: 10)
        expect(power.userActivityDeclarations == baseline + 3, "and the interval keeps repeating for as long as the session is live")

        _ = try? await coordinator.handleWritingResponse(.goodbye(reason: "viewer-left"))
        await coordinator.tickFidelity(atSeconds: 20)
        expect(
            power.userActivityDeclarations == baseline + 3,
            "no further re-declaration happens once the session has ended, got \(power.userActivityDeclarations - baseline)"
        )
    }
    print("PASS: a live host-screen session re-declares activity on the injected interval, and stops at session end")

    do {
        // After the session ends, the declaration is released.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let wake = DisplayWakeController(power: power, displays: { list.read() }, wait: { _ in })
        let media = FakeScalableCanvasMedia()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            hostScreenMediaFactory: { _ in media },
            hostScreenKeepAwakeRedeclareIntervalSeconds: 1
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)

        await coordinator.tickFidelity(atSeconds: 0)
        await coordinator.tickFidelity(atSeconds: 1)
        await coordinator.tickFidelity(atSeconds: 2)
        expect(
            power.isUserActivityDeclared,
            "several re-declarations into a live session, this machine still reads as in use"
        )
        expect(power.allowedSleepCount == 0, "the hold lasts as long as the session does")

        _ = try? await coordinator.handleWritingResponse(.goodbye(reason: "viewer-left"))

        expect(power.allowedSleepCount == 1, "the session ending drops the display-sleep hold")
        expect(
            !power.isUserActivityDeclared,
            "and releases the user-activity declaration outright, whatever periodic re-declaring it did while it was live"
        )
    }
    print("PASS: after a host-screen session ends, the user-activity declaration is released")

    do {
        // A mode change arriving while recovery is in flight neither ends
        // the session nor races it: it is deferred until recovery reaches
        // its own outcome, and only then is it processed.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let gate = RecoveryGate()
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { [gate] _ in await gate.block() },
            pollSeconds: 1,
            settleSeconds: 3
        )
        let events = DiagnosticsRecorder()
        let media = FakeScalableCanvasMedia()
        let modes = recoveryModeController()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in }, modeController: modes)
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { _ in media },
            hostScreenCaptureRecoveryBoundSeconds: 5,
            hostScreenCaptureRecoveryPollSeconds: 0.05,
            hostScreenCaptureRecoveryWait: { _ in }
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)

        // The display drops asleep, and a capture rebuilt against it in
        // that state fails the way ScreenCaptureKit itself would.
        list.displays = [recoveryTestDisplay(asleep: true)]
        media.startFailure = RecoveryStartError()
        media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { gate.isWaiting }
        expect(gate.isWaiting, "recovery is parked waiting for the display to settle")

        // A mode change reaches this connection while recovery is still
        // in flight against the very display it names.
        var modeWritten: [SensoriumMessage] = []
        let modeTask = Task { @MainActor in
            _ = try? await coordinator.handle(
                SensoriumMessage.hostScreenModeRequest(modeID: recoveryTargetMode.modeID)
            ) { message in
                modeWritten.append(message)
            }
        }
        // A window for a request that is not deferred to reach the
        // controller and race recovery's own rebuild while the display is
        // still the one this whole scenario turns on: still asleep.
        _ = await waitUntil(timeoutSeconds: 0.3) { modes.applied.count > 0 }

        // The display comes back for real, and the gate lets recovery's
        // own settle wait complete.
        media.startFailure = nil
        list.displays = [recoveryTestDisplay(asleep: false)]
        gate.release()
        _ = await waitUntil(timeoutSeconds: 2) { !modeWritten.isEmpty || coordinator.hasEnded }
        await modeTask.value

        expect(
            !coordinator.hasEnded,
            "a mode change against a display that was briefly asleep does not end a session recovery would have kept, got hasEnded=\(coordinator.hasEnded)"
        )
        expect(
            modeWritten.contains { if case .hostScreenModeApplied = $0 { return true } else { return false } },
            "and the deferred mode change is still processed once recovery has settled, got \(modeWritten)"
        )
        expect(
            !events.messages.contains { $0.contains("could not restart at the new display mode") },
            "no rebuild attempted while the display was still asleep is ever reported as a failure, got \(events.messages)"
        )
    }
    print("PASS: a mode change arriving mid-recovery neither ends the session nor races the rebuild recovery is already driving")

    do {
        // A mode request reaching this connection while recovery owns the
        // surface returns at once rather than blocking `handle` on
        // recovery's own outcome -- blocking there would block this
        // connection's whole read loop behind it, starving every other
        // frame on the wire. A goodbye delivered right after it is parked
        // is processed without waiting for recovery either.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let gate = RecoveryGate()
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { [gate] _ in await gate.block() },
            pollSeconds: 1,
            settleSeconds: 3
        )
        let media = FakeScalableCanvasMedia()
        let modes = recoveryModeController()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in }, modeController: modes)
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            hostScreenMediaFactory: { _ in media },
            hostScreenCaptureRecoveryBoundSeconds: 5,
            hostScreenCaptureRecoveryPollSeconds: 0.05,
            hostScreenCaptureRecoveryWait: { _ in }
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)

        // The display drops asleep, so recovery's first attempt is gated
        // on the wake controller's own settle wait rather than resolving
        // at once.
        list.displays = [recoveryTestDisplay(asleep: true)]
        media.startFailure = RecoveryStartError()
        media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { gate.isWaiting }
        expect(gate.isWaiting, "recovery is parked waiting for the display to settle")

        var parkedHandleReturned = false
        let parkedTask = Task { @MainActor in
            _ = try? await coordinator.handle(
                SensoriumMessage.hostScreenModeRequest(modeID: recoveryTargetMode.modeID)
            ) { _ in }
            parkedHandleReturned = true
        }
        _ = await waitUntil(timeoutSeconds: 1) { parkedHandleReturned }
        expect(parkedHandleReturned, "a mode request parked behind recovery returns at once, not once recovery settles")
        expect(modes.applied.isEmpty, "and the controller never even saw it while recovery still owns the surface")
        await parkedTask.value

        var goodbyeReturned = false
        let goodbyeTask = Task { @MainActor in
            _ = try? await coordinator.handle(.goodbye(reason: "viewer-left")) { _ in }
            goodbyeReturned = true
        }
        _ = await waitUntil(timeoutSeconds: 1) { goodbyeReturned }
        expect(goodbyeReturned, "a goodbye delivered right after a parked mode request is processed without waiting for recovery")
        expect(coordinator.hasEnded, "and actually ends the session")
        await goodbyeTask.value

        gate.release()
    }
    print("PASS: a mode request parked behind recovery returns at once, and a goodbye right after it is processed without waiting for recovery")

    do {
        // Once recovery succeeds, a parked mode request is replayed through
        // the same path a live one would take: the controller applies it
        // and `.hostScreenModeApplied` is written.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let gate = RecoveryGate()
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { [gate] _ in await gate.block() },
            pollSeconds: 1,
            settleSeconds: 3
        )
        let events = DiagnosticsRecorder()
        let media = FakeScalableCanvasMedia()
        let modes = recoveryModeController()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in }, modeController: modes)
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { _ in media },
            hostScreenCaptureRecoveryBoundSeconds: 5,
            hostScreenCaptureRecoveryPollSeconds: 0.05,
            hostScreenCaptureRecoveryWait: { _ in }
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)

        list.displays = [recoveryTestDisplay(asleep: true)]
        media.startFailure = RecoveryStartError()
        media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { gate.isWaiting }
        expect(gate.isWaiting, "recovery is parked waiting for the display to settle")

        var written: [SensoriumMessage] = []
        let parkedTask = Task { @MainActor in
            _ = try? await coordinator.handle(
                SensoriumMessage.hostScreenModeRequest(modeID: recoveryTargetMode.modeID)
            ) { message in written.append(message) }
        }
        await parkedTask.value
        expect(written.isEmpty, "nothing is written for a parked request until recovery settles")
        expect(modes.applied.isEmpty, "and the controller has not seen it either")

        // The display comes back for real, and the gate lets recovery's
        // own settle wait complete.
        media.startFailure = nil
        list.displays = [recoveryTestDisplay(asleep: false)]
        gate.release()
        _ = await waitUntil(timeoutSeconds: 2) { !written.isEmpty }

        expect(
            written.contains { if case .hostScreenModeApplied = $0 { return true } else { return false } },
            "the parked request is applied once recovery settles, and .hostScreenModeApplied is written, got \(written)"
        )
        expect(
            modes.applied.map(\.modeID) == [recoveryTargetMode.modeID],
            "through the controller, exactly once, got \(modes.applied)"
        )
        expect(!coordinator.hasEnded, "the session survives")
    }
    print("PASS: a mode request parked behind recovery is applied once recovery settles, and .hostScreenModeApplied is written")

    do {
        // Two mode requests parked back to back while recovery is in
        // flight leave only the second applied: latest wins.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let gate = RecoveryGate()
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { [gate] _ in await gate.block() },
            pollSeconds: 1,
            settleSeconds: 3
        )
        let media = FakeScalableCanvasMedia()
        let modes = recoveryModeController()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in }, modeController: modes)
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            hostScreenMediaFactory: { _ in media },
            hostScreenCaptureRecoveryBoundSeconds: 5,
            hostScreenCaptureRecoveryPollSeconds: 0.05,
            hostScreenCaptureRecoveryWait: { _ in }
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)

        list.displays = [recoveryTestDisplay(asleep: true)]
        media.startFailure = RecoveryStartError()
        media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { gate.isWaiting }
        expect(gate.isWaiting, "recovery is parked waiting for the display to settle")

        var firstWritten: [SensoriumMessage] = []
        let firstTask = Task { @MainActor in
            _ = try? await coordinator.handle(
                SensoriumMessage.hostScreenModeRequest(modeID: recoveryTargetMode.modeID)
            ) { message in firstWritten.append(message) }
        }
        await firstTask.value

        var secondWritten: [SensoriumMessage] = []
        let secondTask = Task { @MainActor in
            _ = try? await coordinator.handle(
                SensoriumMessage.hostScreenModeRequest(modeID: recoveryCurrentMode.modeID)
            ) { message in secondWritten.append(message) }
        }
        await secondTask.value

        expect(firstWritten.isEmpty, "the first of two back-to-back parks never gets a reply of its own, got \(firstWritten)")
        expect(secondWritten.isEmpty, "and neither does the second, yet, since recovery has not settled")
        expect(modes.applied.isEmpty, "neither reaches the controller until recovery settles")

        media.startFailure = nil
        list.displays = [recoveryTestDisplay(asleep: false)]
        gate.release()
        _ = await waitUntil(timeoutSeconds: 2) { !secondWritten.isEmpty }

        expect(firstWritten.isEmpty, "the first, overwritten park is dropped outright, never replayed, got \(firstWritten)")
        expect(
            secondWritten.contains { if case .hostScreenModeApplied = $0 { return true } else { return false } },
            "only the second park is replayed and applied, got \(secondWritten)"
        )
        expect(
            modes.applied.map(\.modeID) == [recoveryCurrentMode.modeID],
            "through the controller exactly once, for the second request alone, got \(modes.applied)"
        )
        expect(!coordinator.hasEnded, "the session survives")
    }
    print("PASS: two mode requests parked back to back behind recovery leave only the second applied")

    do {
        // A stream-scale change whose settle timer fires while recovery
        // owns the host-screen surface is dropped rather than
        // reconfiguring the dead capture, and the viewer's latest
        // preference reaches the recovered capture once recovery restarts
        // it.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let gate = RecoveryGate()
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { [gate] _ in await gate.block() },
            pollSeconds: 1,
            settleSeconds: 3
        )
        let events = DiagnosticsRecorder()
        let unrecoverable = DiagnosticsRecorder()
        let media = FakeScalableCanvasMedia()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            onEvent: { events.record($0) },
            onStreamUnrecoverable: { unrecoverable.record($0) },
            hostScreenMediaFactory: { _ in media },
            hostScreenCaptureRecoveryBoundSeconds: 5,
            hostScreenCaptureRecoveryPollSeconds: 0.05,
            hostScreenCaptureRecoveryWait: { _ in }
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)

        list.displays = [recoveryTestDisplay(asleep: true)]
        media.startFailure = RecoveryStartError()
        media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { gate.isWaiting }
        expect(gate.isWaiting, "recovery is parked waiting for the display to settle")

        let scalesBeforeSettle = media.reconfiguredScales.count
        // Matches `recoveryTestDisplay`'s own logical and pixel size, and
        // is exactly `HostScreenFidelityTests`'s own hardware-encoder-ceiling
        // fixture: a viewer asking for its full 5120x2880 pixels resolves
        // to 1.6x, the largest frame this display's hardware encoder
        // accepts, well above the opening scale a restart always opens at.
        _ = try? await coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 5120, pixelHeight: 2880, surfaceID: nil, maximumScale: nil)
        )
        // The settle timer's own debounce window, given time to fire while
        // recovery still owns the surface.
        try? await Task.sleep(for: .milliseconds(600))
        expect(
            media.reconfiguredScales.count == scalesBeforeSettle,
            "a settle timer firing mid-recovery never reconfigures the dead capture, got \(media.reconfiguredScales)"
        )
        expect(!coordinator.hasEnded, "and does not end the session either")
        expect(unrecoverable.messages.isEmpty, "nor tells the viewer the stream is unrecoverable")

        media.startFailure = nil
        list.displays = [recoveryTestDisplay(asleep: false)]
        gate.release()
        _ = await waitUntil(timeoutSeconds: 2) { media.keyFrameRequestCount > 0 }

        expect(!coordinator.hasEnded, "the session survives, and recovers")
        expect(
            await waitUntil(timeoutSeconds: 2) { media.currentStreamScale == 1.6 },
            "the recovered capture carries the viewer's latest stream-scale preference, got \(media.currentStreamScale)"
        )
        expect(
            events.messages.contains("host-screen display 3 capture recovered"),
            "the host log still says the capture recovered, got \(events.messages)"
        )
    }
    print("PASS: a stream-scale change whose settle timer fires mid-recovery neither ends the session nor touches the dead capture, and the recovered capture carries the new scale")

    do {
        // The recovery bound is wall-clock time, not a fixed count of
        // retries: with production-realistic settle and wake waits, a
        // display that never comes back gives up close to the bound,
        // not after thirty retries' worth of nested waiting.
        final class TestClock {
            var seconds: Double = 0
            func advance(_ by: Double) { seconds += by }
        }
        let clock = TestClock()
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { [clock] seconds in clock.advance(seconds) },
            timeoutSeconds: DisplayWakeController.defaultWakeSeconds,
            pollSeconds: DisplayWakeController.defaultPollSeconds,
            settleSeconds: DisplayWakeController.defaultSettleSeconds
        )
        let unrecoverable = DiagnosticsRecorder()
        let media = FakeScalableCanvasMedia()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            onStreamUnrecoverable: { unrecoverable.record($0) },
            hostScreenMediaFactory: { _ in media },
            hostScreenCaptureRecoveryBoundSeconds: 30,
            hostScreenCaptureRecoveryPollSeconds: 1,
            hostScreenCaptureRecoveryWait: { [clock] seconds in clock.advance(seconds) },
            hostScreenNowSecondsProvider: { [clock] in clock.seconds }
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)

        // Asleep only once the session is already live on it: an asleep
        // display is never offered in the first place.
        list.displays = [recoveryTestDisplay(asleep: true)]
        media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { coordinator.hasEnded }

        expect(coordinator.hasEnded, "a display that never comes back still ends the session")
        expect(
            unrecoverable.messages == [GoodbyeReason.hostDisplaysAsleep],
            "with the existing reason, got \(unrecoverable.messages)"
        )
        expect(
            clock.seconds < 60,
            "the bound is elapsed wall-clock time including the nested settle and wake waits, so giving up takes on the "
                + "order of the thirty-second bound, not thirty retries' worth of them -- got \(clock.seconds)s simulated"
        )
    }
    print("PASS: the recovery bound is wall-clock time, not a fixed count of retries")

    do {
        // A mode request arriving while a parked request's own replay is
        // still rebuilding capture parks behind it rather than racing it:
        // only one rebuild runs at a time, and the later request is
        // applied once the one already in flight finishes.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let gate = RecoveryGate()
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { [gate] _ in await gate.block() },
            pollSeconds: 1,
            settleSeconds: 3
        )
        let media = FakeScalableCanvasMedia()
        let modes = recoveryModeController()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in }, modeController: modes)
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            hostScreenMediaFactory: { _ in media },
            hostScreenCaptureRecoveryBoundSeconds: 5,
            hostScreenCaptureRecoveryPollSeconds: 0.05,
            hostScreenCaptureRecoveryWait: { _ in }
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)
        expect(media.startedDisplayIDs.count == 1, "the session's own start is call 1, got \(media.startedDisplayIDs.count)")

        // Recovery's first attempt is gated on the display waking, so the
        // request sent next parks behind it -- becoming what the replay,
        // once recovery succeeds, rebuilds capture for.
        list.displays = [recoveryTestDisplay(asleep: true)]
        media.startFailure = RecoveryStartError()
        media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { gate.isWaiting }
        expect(gate.isWaiting, "recovery is parked waiting for the display to settle")

        var replayWritten: [SensoriumMessage] = []
        let replayTask = Task { @MainActor in
            _ = try? await coordinator.handle(
                SensoriumMessage.hostScreenModeRequest(modeID: recoveryTargetMode.modeID)
            ) { message in replayWritten.append(message) }
        }
        await replayTask.value
        expect(replayWritten.isEmpty, "the request parks rather than answering while recovery owns the surface")

        // Recovery's own restart (call 2) succeeds; the parked request's
        // own replay rebuild (call 3) is held mid-flight, so a request
        // arriving during it can be observed racing or parking.
        media.holdStartOnCall = 3
        media.startFailure = nil
        list.displays = [recoveryTestDisplay(asleep: false)]
        gate.release()
        _ = await waitUntil(timeoutSeconds: 2) { media.isHoldingStart }
        expect(media.isHoldingStart, "the replay's own rebuild is mid-flight, held at its own start call")
        expect(
            media.startedDisplayIDs.count == 3,
            "call 1, recovery's own restart, and the replay's held call, got \(media.startedDisplayIDs.count)"
        )

        var secondWritten: [SensoriumMessage] = []
        let secondTask = Task { @MainActor in
            _ = try? await coordinator.handle(
                SensoriumMessage.hostScreenModeRequest(modeID: recoveryCurrentMode.modeID)
            ) { message in secondWritten.append(message) }
        }
        // A window for a request arriving mid-rebuild to race it, if
        // nothing is stopping it.
        try? await Task.sleep(for: .milliseconds(200))

        expect(
            media.startedDisplayIDs.count == 3,
            "a request arriving while the replay's own rebuild is still in flight must not start a second, "
                + "concurrent one, got \(media.startedDisplayIDs.count)"
        )
        expect(secondWritten.isEmpty, "and is not yet answered, since it has not been processed")

        media.releaseHeldStart()
        await secondTask.value
        _ = await waitUntil(timeoutSeconds: 2) { !secondWritten.isEmpty }

        expect(
            replayWritten.contains { if case .hostScreenModeApplied = $0 { return true } else { return false } },
            "the replay's own rebuild finishes and is answered once its held call returns, got \(replayWritten)"
        )
        expect(
            secondWritten.contains { if case .hostScreenModeApplied = $0 { return true } else { return false } },
            "the later request is applied once the rebuild already in flight finishes, got \(secondWritten)"
        )
        expect(
            modes.applied.map(\.modeID) == [recoveryTargetMode.modeID, recoveryCurrentMode.modeID],
            "the replay ran first and the later request second, never concurrently, got \(modes.applied.map(\.modeID))"
        )
        expect(!coordinator.hasEnded, "the session survives")
    }
    print("PASS: a mode request arriving while a replay's own rebuild is still in flight parks rather than racing it")

    do {
        // A settle dropped while a parked request's own replay rebuilds
        // capture is reapplied once the whole drain finishes, mirroring
        // recovery's own restart.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([recoveryTestDisplay()])
        let gate = RecoveryGate()
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { [gate] _ in await gate.block() },
            pollSeconds: 1,
            settleSeconds: 3
        )
        let media = FakeScalableCanvasMedia()
        let modes = recoveryModeController()
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in }, modeController: modes)
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            hostScreenMediaFactory: { _ in media },
            hostScreenCaptureRecoveryBoundSeconds: 5,
            hostScreenCaptureRecoveryPollSeconds: 0.05,
            hostScreenCaptureRecoveryWait: { _ in }
        )
        try! await startRecoveryHostScreenSession(controller: controller, coordinator: coordinator)

        // Recovery's first attempt gates on the display waking, so this
        // request parks behind it until the replay rebuilds for it.
        list.displays = [recoveryTestDisplay(asleep: true)]
        media.startFailure = RecoveryStartError()
        media.simulateCaptureStoppedOnItsOwn()
        _ = await waitUntil(timeoutSeconds: 2) { gate.isWaiting }
        expect(gate.isWaiting, "recovery is parked waiting for the display to settle")

        let parkedTask = Task { @MainActor in
            _ = try? await coordinator.handle(
                SensoriumMessage.hostScreenModeRequest(modeID: recoveryTargetMode.modeID)
            ) { _ in }
        }
        await parkedTask.value

        // Recovery's restart (call 2) succeeds; the parked request's own
        // replay (call 3) is held mid-flight, exposing the settle below.
        media.holdStartOnCall = 3
        media.startFailure = nil
        list.displays = [recoveryTestDisplay(asleep: false)]
        gate.release()
        _ = await waitUntil(timeoutSeconds: 2) { media.isHoldingStart }
        expect(media.isHoldingStart, "the replay's own rebuild is mid-flight, held at its own start call")

        let scalesBeforeSettle = media.reconfiguredScales.count
        // The drain already switched the display to `recoveryTargetMode`,
        // so 5120x2880 now resolves to that mode's own ceiling, 2.0x, not
        // the original mode's.
        _ = try? await coordinator.handleWritingResponse(
            .viewerDrawableSize(pixelWidth: 5120, pixelHeight: 2880, surfaceID: nil, maximumScale: nil)
        )
        // The settle's own debounce window, given time to fire while the
        // rebuild above still holds the surface.
        try? await Task.sleep(for: .milliseconds(600))
        expect(
            media.reconfiguredScales.count == scalesBeforeSettle,
            "a settle timer firing while a drained request's own rebuild is still in flight never reconfigures "
                + "the capture that rebuild is replacing, got \(media.reconfiguredScales)"
        )

        media.releaseHeldStart()
        _ = await waitUntil(timeoutSeconds: 2) { media.currentStreamScale == 2.0 }

        expect(
            media.currentStreamScale == 2.0,
            "the viewer's latest requested scale is reapplied once the whole drain finishes, got \(media.currentStreamScale)"
        )
        expect(!coordinator.hasEnded, "the session survives")
    }
    print("PASS: a stream-scale settle firing while a drained request's own rebuild is in flight is dropped, and reapplied once the drain finishes")
}

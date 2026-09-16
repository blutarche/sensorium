import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// A stand-in for this machine's power management, so nothing here ever
/// touches real power state. Records what was asked of macOS and nothing
/// else; whether a display then wakes is decided by the display list the
/// test hands the controller alongside this.
@MainActor
final class FakeDisplayPower: DisplayPowerControlling {
    private(set) var userActivityDeclarations = 0
    private(set) var preventedSleepNames: [String] = []
    private(set) var allowedSleepCount = 0

    func declareUserActivity() {
        userActivityDeclarations += 1
    }

    func preventDisplaySleep(named name: String) {
        preventedSleepNames.append(name)
    }

    func allowDisplaySleep() {
        allowedSleepCount += 1
    }
}

/// A display list a test can change between reads, which is what a display
/// waking up looks like to the code under test.
@MainActor
final class FakeDisplayList {
    var displays: [DisplaySnapshot]
    private(set) var readCount = 0

    init(_ displays: [DisplaySnapshot]) {
        self.displays = displays
    }

    func read() -> [DisplaySnapshot] {
        readCount += 1
        return displays
    }
}

@MainActor
func sleepingDisplaySnapshot(id: UInt32 = 7, asleep: Bool) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 5120,
        pixelHeight: 2880,
        modeWidth: 2560,
        modeHeight: 1440,
        modePixelWidth: 5120,
        modePixelHeight: 2880,
        bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        online: true,
        asleep: asleep,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

/// An authenticated controller armed for this machine, wired so the same
/// mutable display list the wake controller polls is what the offer reads.
/// A display showing another display's picture, never its own. Online and
/// physically there, so only the mirror flag keeps it out of an offer.
@MainActor
func mirroringDisplaySnapshot(id: UInt32 = 9, asleep: Bool, mirrors: UInt32 = 7) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 2560,
        pixelHeight: 1440,
        modeWidth: 2560,
        modeHeight: 1440,
        modePixelWidth: 2560,
        modePixelHeight: 1440,
        bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        online: true,
        asleep: asleep,
        mirrorsDisplay: mirrors,
        builtin: false,
        main: false,
        vendorNumber: 1553,
        modelNumber: 41
    )
}

/// A session canvas of this host's own making, asleep or awake. Never a
/// host-screen target, so never something to wake either.
@MainActor
func sleepingCanvasSnapshot(id: UInt32 = 11, asleep: Bool) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 3840,
        pixelHeight: 2160,
        modeWidth: 1920,
        modeHeight: 1080,
        modePixelWidth: 3840,
        modePixelHeight: 2160,
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        online: true,
        asleep: asleep,
        builtin: false,
        main: false,
        vendorNumber: CanvasDisplayIdentity.vendorID,
        modelNumber: 0x31
    )
}

@MainActor
func armedHostScreenController(
    displays: FakeDisplayList,
    displayWake: DisplayWakeController,
    log: @escaping @MainActor (String) -> Void
) -> HostSessionController {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: deviceKey,
            deviceName: "Kestrel MacBook Pro",
            minimumCredentialStrength: .hardwareBound,
            armedAt: Date()
        )
    ])
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { displays.read() },
        displayWake: displayWake,
        log: log
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))
    return controller
}

/// A canvas session on a machine with nothing asleep, sharing `wake` with
/// whatever else a test builds from it.
@MainActor
func makeAwakeCanvasCoordinator(wake: DisplayWakeController) -> HostSessionCoordinator {
    HostSessionCoordinator(
        controller: HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined,
            displayWake: wake
        ),
        media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
        videoSink: FakeVideoSink(),
        workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() }
    )
}

private final class WakeTestApprovingVerifier: HostScreenPresenceProofVerifying, @unchecked Sendable {
    func verify(
        proof: HostScreenPresenceProof,
        devicePublicKey: Data,
        minimumStrength: HostScreenCredentialStrength?,
        challenge: Data
    ) -> Bool {
        true
    }
}

/// A coordinator already offered `display` for host screen, with the token
/// that names it, so a test can admit a host-screen session in one step.
@MainActor
func makeWakeHostScreenFixture(
    display: DisplaySnapshot,
    wake: DisplayWakeController,
    availability: HostCaptureAvailability,
    onStreamUnrecoverable: @escaping @Sendable (String) -> Void,
    hostScreenMediaFactory: @escaping (VideoEncoderConfiguration) -> any CanvasMediaStreaming
) -> (coordinator: HostSessionCoordinator, token: Data) {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: deviceKey,
            deviceName: "Kestrel MacBook Pro",
            minimumCredentialStrength: .hardwareBound,
            armedAt: Date()
        )
    ])
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenPresenceProofVerifier: WakeTestApprovingVerifier(),
        displayWake: wake,
        log: { _ in }
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))
    let coordinator = HostSessionCoordinator(
        controller: controller,
        media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
        videoSink: FakeVideoSink(),
        workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
        flowReportSeconds: 1,
        onStreamUnrecoverable: onStreamUnrecoverable,
        hostScreenMediaFactory: hostScreenMediaFactory,
        captureAvailability: availability
    )
    guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList(),
          let entry = displays.first else {
        expect(false, "the fixture's own offer names the display it was armed for")
        return (coordinator, Data())
    }
    return (coordinator, entry.opaqueToken)
}

@MainActor
func runDisplayWakeTests() async {
    do {
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(id: 7, asleep: true)])
        let controller = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in list.displays = [sleepingDisplaySnapshot(id: 7, asleep: false)] },
            timeoutSeconds: 5,
            pollSeconds: 0.1
        )
        let woke = await controller.wakeDisplays()
        expect(
            power.userActivityDeclarations == 1,
            "a session starting against a sleeping display tells macOS a person is active, got \(power.userActivityDeclarations)"
        )
        expect(woke, "and reports the display awake once it reads awake")
    }

    print("PASS: a session start with a sleeping display declares user activity and waits for it to wake")

    do {
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(id: 7, asleep: true)])
        var waits = 0
        let controller = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in waits += 1 },
            timeoutSeconds: 0.5,
            pollSeconds: 0.1
        )
        let woke = await controller.wakeDisplays()
        expect(!woke, "a display that never wakes is reported as still asleep rather than waited on forever")
        expect(waits == 5, "and the wait is bounded by the time it was given, got \(waits) polls")
        expect(
            power.userActivityDeclarations == 1,
            "with one activity declaration, not one per poll, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: a display that stays asleep ends a bounded wait rather than holding a session open")

    do {
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(id: 7, asleep: false)])
        let controller = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in },
            timeoutSeconds: 5,
            pollSeconds: 0.1
        )
        let woke = await controller.wakeDisplays()
        expect(woke, "a machine with nothing asleep needs no waking")
        expect(
            power.userActivityDeclarations == 0,
            "and no power call is made at all, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: a session start on an awake machine makes no power call")

    do {
        let power = FakeDisplayPower()
        let controller = DisplayWakeController(
            power: power,
            displays: { [] },
            wait: { _ in }
        )
        controller.holdDisplaysAwake()
        controller.holdDisplaysAwake()
        expect(
            power.preventedSleepNames == ["Sensorium session is live"],
            "two sessions hold this machine's displays awake under one assertion, named so a person can read it, got \(power.preventedSleepNames)"
        )
        expect(controller.isHoldingDisplaysAwake, "and the hold is readable while it is held")
        controller.releaseDisplaysAwake()
        expect(
            power.allowedSleepCount == 0,
            "one session ending leaves the other session's hold standing, got \(power.allowedSleepCount)"
        )
        expect(controller.isHoldingDisplaysAwake, "because a session is still live")
        controller.releaseDisplaysAwake()
        expect(
            power.allowedSleepCount == 1,
            "the last session ending is what drops it, got \(power.allowedSleepCount)"
        )
        expect(!controller.isHoldingDisplaysAwake, "after which this machine idles its displays as it did before")
        controller.releaseDisplaysAwake()
        expect(
            power.allowedSleepCount == 1,
            "and a release with nothing left holding changes nothing, got \(power.allowedSleepCount)"
        )
    }

    print("PASS: the prevent-sleep hold is counted, so the last session to end is the one that drops it")

    do {
        // The field failure: the host's own monitor had idled to sleep, so
        // the display it was armed for read asleep and the offer refused a
        // screen that was physically right there.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(asleep: true)])
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in list.displays = [sleepingDisplaySnapshot(asleep: false)] },
            timeoutSeconds: 5,
            pollSeconds: 0.1
        )
        var loggedLines: [String] = []
        let controller = armedHostScreenController(
            displays: list, displayWake: wake, log: { loggedLines.append($0) }
        )
        guard case let .hostScreenList(displays, _) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "an armed display that was merely asleep is offered once it has been woken")
            return
        }
        expect(
            displays.count == 1,
            "the woken display is offered rather than refused, got \(displays.count)"
        )
        expect(
            power.userActivityDeclarations == 1,
            "and waking it is what made that possible, got \(power.userActivityDeclarations)"
        )
        expect(
            loggedLines.contains("Sensorium host: offered 1 host screens to Kestrel MacBook Pro: External Display"),
            "with a clean offer line and no gap line, got \(loggedLines)"
        )
    }

    print("PASS: an armed host screen that is asleep is woken first and then offered")

    do {
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(asleep: true)])
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in },
            timeoutSeconds: 0.3,
            pollSeconds: 0.1
        )
        var loggedLines: [String] = []
        let controller = armedHostScreenController(
            displays: list, displayWake: wake, log: { loggedLines.append($0) }
        )
        guard case let .hostScreenList(displays, _) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "a display that would not wake still produces an offer, with nothing in it")
            return
        }
        expect(displays.isEmpty, "a display that would not wake is offered to no one, got \(displays.count)")
        expect(
            loggedLines == [
                "Sensorium host: did not offer host screen \"External Display\" to Kestrel MacBook Pro: asleep"
            ],
            "and the gap still reads asleep, got \(loggedLines)"
        )
    }

    print("PASS: a host screen that stays asleep after being woken is refused exactly as before")

    do {
        // A canvas Sensorium created is never a host-screen target, so a
        // sleeping one is no reason to touch this machine's power state.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([
            sleepingDisplaySnapshot(asleep: false),
            sleepingCanvasSnapshot(asleep: true)
        ])
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in },
            timeoutSeconds: 5,
            pollSeconds: 0.1
        )
        let controller = armedHostScreenController(
            displays: list, displayWake: wake, log: { _ in }
        )
        guard case let .hostScreenList(displays, _) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "the awake display is still offered with a canvas asleep beside it")
            return
        }
        expect(
            displays.map(\.label) == ["External Display"],
            "the canvas is not offered and the physical display still is, got \(displays.map(\.label))"
        )
        expect(
            power.userActivityDeclarations == 0,
            "and a sleeping canvas reaches no power call on this machine, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: a sleeping canvas Sensorium created is never woken")

    do {
        let power = FakeDisplayPower()
        let list = FakeDisplayList([
            sleepingDisplaySnapshot(asleep: true),
            sleepingCanvasSnapshot(asleep: true)
        ])
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in
                list.displays = [
                    sleepingDisplaySnapshot(asleep: false),
                    sleepingCanvasSnapshot(asleep: true)
                ]
            },
            timeoutSeconds: 0.5,
            pollSeconds: 0.1
        )
        let controller = armedHostScreenController(
            displays: list, displayWake: wake, log: { _ in }
        )
        guard case let .hostScreenList(displays, _) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "the woken physical display is offered")
            return
        }
        expect(
            displays.map(\.label) == ["External Display"],
            "a canvas that stays asleep does not hold up the display that woke, got \(displays.map(\.label))"
        )
        expect(
            power.userActivityDeclarations == 1,
            "the physical display asleep beside it is still what the wake was for, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: a physical display wakes while a sleeping canvas beside it is left alone")

    do {
        // A display mirroring another one shows that display's picture and
        // is never offerable, so waking it would be a power call made for a
        // screen no session could ever stream.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([
            sleepingDisplaySnapshot(asleep: false),
            mirroringDisplaySnapshot(asleep: true)
        ])
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in },
            timeoutSeconds: 5,
            pollSeconds: 0.1
        )
        let controller = armedHostScreenController(
            displays: list, displayWake: wake, log: { _ in }
        )
        guard case let .hostScreenList(displays, _) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "the display being mirrored is still offered")
            return
        }
        expect(
            displays.map(\.label) == ["External Display"],
            "the mirror is not offered and the display it mirrors still is, got \(displays.map(\.label))"
        )
        expect(
            power.userActivityDeclarations == 0,
            "and a sleeping mirror reaches no power call on this machine, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: a sleeping display that mirrors another one is never woken")

    do {
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(asleep: true)])
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in list.displays = [sleepingDisplaySnapshot(asleep: false)] },
            timeoutSeconds: 5,
            pollSeconds: 0.1
        )
        let coordinator = HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined,
                displayWake: wake
            ),
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        expect(
            power.userActivityDeclarations == 1,
            "a session canvas starts against a woken machine, since a sleeping one draws nothing to capture, got \(power.userActivityDeclarations)"
        )
        expect(
            power.preventedSleepNames == [DisplayWakeController.assertionName],
            "and the live session holds this machine's displays awake, got \(power.preventedSleepNames)"
        )
        expect(power.allowedSleepCount == 0, "the hold lasts as long as the session does")
        _ = try? await coordinator.handleWritingResponse(.goodbye(reason: "viewer-left"))
        expect(
            power.allowedSleepCount == 1,
            "and is dropped when the session ends, got \(power.allowedSleepCount)"
        )
    }

    print("PASS: a session holds this machine's displays awake from start to end")

    do {
        let power = FakeDisplayPower()
        let wake = DisplayWakeController(
            power: power,
            displays: { [sleepingDisplaySnapshot(asleep: false)] },
            wait: { _ in }
        )
        let coordinator = HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined,
                displayWake: wake
            ),
            media: onlyOnSurfaceZero(FailingCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() }
        )
        _ = try? await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        expect(
            coordinator.hasEnded,
            "capture that cannot start ends the session, which is the path this is about"
        )
        expect(
            power.allowedSleepCount == 1,
            "a session that ended on an error leaves this machine idling its displays as it found them, got \(power.allowedSleepCount)"
        )
    }

    print("PASS: a session that ends on an error drops the hold on this machine's displays")

    do {
        // The whole field failure in one scenario: the machine's displays
        // idled to sleep mid-session, capture went on delivering nothing,
        // and the host gave up on its own ability to capture at all. A
        // sleeping display explains the silence, and quitting the host does
        // not fix it.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(asleep: false)])
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in list.displays = [sleepingDisplaySnapshot(asleep: false)] },
            timeoutSeconds: 5,
            pollSeconds: 0.1
        )
        let media = FakeScalableCanvasMedia()
        let availability = HostCaptureAvailability()
        let events = DiagnosticsRecorder()
        let unrecoverable = DiagnosticsRecorder()
        let coordinator = HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined,
                displayWake: wake
            ),
            media: onlyOnSurfaceZero(media),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            streamScaleSettleSeconds: 0.05,
            flowReportSeconds: 1,
            onEvent: { events.record($0) },
            onStreamUnrecoverable: { unrecoverable.record($0) },
            captureAvailability: availability
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        // The displays idle to sleep now, with the session already live.
        list.displays = [sleepingDisplaySnapshot(asleep: true)]
        for second in 0...4 {
            await coordinator.tickFidelity(atSeconds: Double(second))
        }
        expect(
            media.reconfiguredScales.count == 2,
            "a stream still silent after one rebuild is built once more, this time against woken displays, got \(media.reconfiguredScales.count)"
        )
        expect(
            !coordinator.hasEnded && !availability.isUnavailable,
            "and the session is not given up on while a sleeping display explains the silence"
        )
        expect(
            power.userActivityDeclarations >= 1,
            "which means the displays were actually woken, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: capture delivering nothing against a sleeping display wakes it and builds the stream again")

    do {
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(asleep: false)])
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in },
            timeoutSeconds: 0.2,
            pollSeconds: 0.1
        )
        let media = FakeScalableCanvasMedia()
        let availability = HostCaptureAvailability()
        let events = DiagnosticsRecorder()
        let unrecoverable = DiagnosticsRecorder()
        let coordinator = HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                keyConfinement: .unconfined,
                displayWake: wake
            ),
            media: onlyOnSurfaceZero(media),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
            streamScaleSettleSeconds: 0.05,
            flowReportSeconds: 1,
            onEvent: { events.record($0) },
            onStreamUnrecoverable: { unrecoverable.record($0) },
            captureAvailability: availability
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        list.displays = [sleepingDisplaySnapshot(asleep: true)]
        for second in 0...6 {
            await coordinator.tickFidelity(atSeconds: Double(second))
        }
        expect(
            coordinator.hasEnded,
            "a stream still silent after the displays would not wake ends the session"
        )
        expect(
            unrecoverable.messages == [GoodbyeReason.hostDisplaysAsleep],
            "and names sleeping displays as the reason, not a host that needs relaunching, got \(unrecoverable.messages)"
        )
        expect(
            events.messages.contains(HostCaptureAvailability.displaysAsleepLogLine),
            "the host log says the displays were asleep, got \(events.messages)"
        )
        expect(
            !events.messages.contains(HostCaptureAvailability.operatorLogLine),
            "and never tells the person at this machine to quit and open the host again, got \(events.messages)"
        )
        expect(
            !availability.isUnavailable,
            "a sleeping display is not this process losing the ability to capture, so later sessions are not refused"
        )
    }

    print("PASS: a session ended by displays that would not wake says so, and does not blame the host process")

    do {
        let power = FakeDisplayPower()
        let wake = DisplayWakeController(power: power, displays: { [] }, wait: { _ in })
        let factory = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined,
            displayWake: wake
        )
        expect(
            factory.makeController().displayWake === wake && factory.makeController().displayWake === wake,
            "every connection this machine accepts shares the one assertion this process holds on its displays"
        )

        // Two connections, each with a live session of its own. The one that
        // ends first must not take the other one's screen out from under it.
        let first = makeAwakeCanvasCoordinator(wake: wake)
        let second = makeAwakeCanvasCoordinator(wake: wake)
        _ = try! await first.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        _ = try! await second.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        expect(
            power.preventedSleepNames.count == 1,
            "two live sessions hold this machine's displays awake under one assertion, got \(power.preventedSleepNames.count)"
        )
        _ = try? await first.handleWritingResponse(.goodbye(reason: "viewer-left"))
        expect(
            power.allowedSleepCount == 0,
            "the session that ended first leaves the other one's screen on, got \(power.allowedSleepCount)"
        )
        _ = try? await second.handleWritingResponse(.goodbye(reason: "viewer-left"))
        expect(
            power.allowedSleepCount == 1,
            "and this machine idles its displays again once the last session has ended, got \(power.allowedSleepCount)"
        )
    }

    print("PASS: one connection ending does not drop the hold another connection's live session is standing on")

    do {
        let power = FakeDisplayPower()
        let wake = DisplayWakeController(
            power: power,
            displays: { [sleepingDisplaySnapshot(asleep: true)] },
            wait: { _ in }
        )
        let coordinator = HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                requireAuthentication: true,
                keyConfinement: .unconfined,
                displayWake: wake
            ),
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() }
        )
        _ = try? await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        expect(
            power.userActivityDeclarations == 0,
            "a request from a machine that has not proved who it is reaches no power call on this one, got \(power.userActivityDeclarations)"
        )
        expect(
            power.preventedSleepNames.isEmpty,
            "and holds nothing awake for a session that was never admitted, got \(power.preventedSleepNames)"
        )
    }

    print("PASS: an unauthenticated request wakes nothing on this machine")

    do {
        // Two displays, and the one this session is streaming is awake. The
        // other one sleeping says nothing about why this capture is silent.
        let captured = sleepingDisplaySnapshot(id: 7, asleep: false)
        let power = FakeDisplayPower()
        let wake = DisplayWakeController(
            power: power,
            displays: { [captured, sleepingDisplaySnapshot(id: 9, asleep: true)] },
            wait: { _ in }
        )
        let hostScreenMedia = FakeScalableCanvasMedia()
        let availability = HostCaptureAvailability()
        let unrecoverable = DiagnosticsRecorder()
        let fixture = makeWakeHostScreenFixture(
            display: captured,
            wake: wake,
            availability: availability,
            onStreamUnrecoverable: { unrecoverable.record($0) },
            hostScreenMediaFactory: { _ in hostScreenMedia }
        )
        guard case .hostScreenReady = try! await fixture.coordinator.handleFirstResponse(.hostScreenRequest(
            token: fixture.token,
            presence: .signed(
                credentialID: Data([0x01]),
                credentialFormat: "apple-secure-enclave-p256",
                signature: Data([0x02])
            )
        )) else {
            expect(false, "the fixture admits its own host-screen request")
            return
        }
        for second in 0...4 {
            await fixture.coordinator.tickFidelity(atSeconds: Double(second))
        }
        expect(
            unrecoverable.messages == [GoodbyeReason.captureUnavailable],
            "a silent host-screen capture of an awake display is not explained by some other display sleeping, got \(unrecoverable.messages)"
        )
        expect(
            availability.isUnavailable,
            "and is recorded as this process losing capture, which is what it is"
        )
    }

    print("PASS: a host-screen session reads only the display it captures when it asks whether sleep explains the silence")
}

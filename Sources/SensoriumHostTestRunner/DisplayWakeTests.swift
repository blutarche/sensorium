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
    private(set) var endedUserActivityCount = 0
    /// Mirrors the one assertion `IOKitDisplayPower` actually holds: true from
    /// a declare until the next end, whatever the raw call counts above are.
    private(set) var isUserActivityDeclared = false

    func declareUserActivity() {
        userActivityDeclarations += 1
        isUserActivityDeclared = true
    }

    func preventDisplaySleep(named name: String) {
        preventedSleepNames.append(name)
    }

    func allowDisplaySleep() {
        allowedSleepCount += 1
    }

    func endUserActivity() {
        endedUserActivityCount += 1
        isUserActivityDeclared = false
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
            deviceName: "Kestrel Laptop Pro",
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
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey,
        hostCertificateHash: nil
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))
    return controller
}

private final class WakeGateActivitySignal: HostLocalActivitySignal, @unchecked Sendable {
    var reading: HostLocalActivityReading = .idleFor(0)
    func currentReading() -> HostLocalActivityReading { reading }
}

private final class WakeGatePresenceGate: HostScreenPresenceGating, @unchecked Sendable {
    var outcome: HostScreenPresenceOutcome
    init(outcome: HostScreenPresenceOutcome) { self.outcome = outcome }
    func ask(content: HostScreenBadgeContent) -> HostScreenPresenceOutcome { outcome }
}

/// A connection armed with asking first switched on, wired with `wake` so a
/// test can watch what a request the presence gate answers does to this
/// machine's power state, not just to the reply the viewer gets.
@MainActor
private func makeDecliningWakeFixture(
    display: DisplaySnapshot,
    wake: DisplayWakeController,
    outcome: HostScreenPresenceOutcome
) -> (coordinator: HostSessionCoordinator, token: Data) {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: deviceKey,
            deviceName: "Kestrel Laptop Pro",
            armedAt: Date(),
            asksWhenSomeoneIsUsingThisMachine: true
        )
    ])
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        inputInjectorFactory: FakeInputInjectorFactory(),
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenPresenceActivitySignal: WakeGateActivitySignal(),
        hostScreenPresenceGate: WakeGatePresenceGate(outcome: outcome),
        displayWake: wake,
        log: { _ in }
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey,
        hostCertificateHash: nil
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))
    let coordinator = HostSessionCoordinator(
        controller: controller,
        media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
        videoSink: FakeVideoSink(),
        workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() }
    )
    guard case let .hostScreenList(displays) = try! controller.offerHostScreenList(),
          let entry = displays.first else {
        expect(false, "the fixture's own offer names the display it was armed for")
        return (coordinator, Data())
    }
    return (coordinator, entry.opaqueToken)
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

/// A coordinator already offered `display` for host screen, with the token
/// that names it, so a test can admit a host-screen session in one step.
@MainActor
func makeWakeHostScreenFixture(
    display: DisplaySnapshot,
    wake: DisplayWakeController,
    availability: HostCaptureAvailability,
    onStreamUnrecoverable: @escaping @Sendable (String) -> Void,
    hostScreenMediaFactory: @escaping (VideoEncoderConfiguration) -> any CanvasMediaStreaming
) -> (coordinator: HostSessionCoordinator, controller: HostSessionController, token: Data) {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: deviceKey,
            deviceName: "Kestrel Laptop Pro",
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
        displayWake: wake,
        log: { _ in }
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey,
        hostCertificateHash: nil
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
    guard case let .hostScreenList(displays) = try! controller.offerHostScreenList(),
          let entry = displays.first else {
        expect(false, "the fixture's own offer names the display it was armed for")
        return (coordinator, controller, Data())
    }
    return (coordinator, controller, entry.opaqueToken)
}

/// The display macOS reports when no monitor is drawing: what a Mac mini
/// with its monitors powered off by display sleep, or with none attached,
/// has online. Awake, unnamed, and not a canvas of this host's own making.
@MainActor
func headlessStandInSnapshot(id: UInt32 = 429) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 1920,
        pixelHeight: 1080,
        modeWidth: 1920,
        modeHeight: 1080,
        modePixelWidth: 1920,
        modePixelHeight: 1080,
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
        online: true,
        asleep: false,
        builtin: false,
        main: true,
        vendorNumber: 0x756E_6B6E,
        modelNumber: 0x7669_7274,
        name: nil
    )
}

/// A controller whose one device is authenticated or not, and armed or
/// not, for the tests that prove a wake never reaches past those gates.
@MainActor
func wakeGateController(
    displays: FakeDisplayList,
    displayWake: DisplayWakeController,
    authenticate: Bool,
    armed: Bool,
    connections: HostDeviceConnectionRegistry? = nil
) -> (controller: HostSessionController, deviceKey: Data) {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let arming = HostScreenArming(devices: armed ? [
        HostScreenDeviceArming(devicePublicKey: deviceKey, deviceName: "Kestrel Laptop Pro", armedAt: Date())
    ] : [])
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { displays.read() },
        deviceConnectionRegistry: connections,
        displayWake: displayWake,
        log: { _ in }
    )
    if authenticate {
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey,
            hostCertificateHash: nil
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
        ))
    }
    return (controller, deviceKey)
}

/// A display this machine no longer has online, sharing `sleepingDisplaySnapshot`'s
/// own vendor/model pair -- and so the same `HostScreenDisplayIdentity` -- so
/// a token minted for the online display still names this one once it goes
/// offline.
@MainActor
func offlineDisplaySnapshot(id: UInt32 = 7) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 5120,
        pixelHeight: 2880,
        modeWidth: 2560,
        modeHeight: 1440,
        modePixelWidth: 5120,
        modePixelHeight: 2880,
        bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        online: false,
        asleep: false,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

/// An arming record a test can flip after a connection has already
/// authenticated, or already been offered, without touching either.
@MainActor
private final class WakeGateArmingBox {
    var arming: HostScreenArming
    init(_ arming: HostScreenArming) { self.arming = arming }
}

/// A connection armed or not, with its own arming record a test can flip
/// after hello, after an offer, or after a request -- unlike
/// `wakeGateController` and `armedHostScreenController`, whose arming is
/// fixed for the fixture's whole life.
@MainActor
private func makeMutableArmingWakeFixture(
    display: DisplaySnapshot,
    wake: DisplayWakeController,
    armed: Bool,
    resumeTicketStore: (any HostScreenResumeTicketStoring)? = nil
) -> (coordinator: HostSessionCoordinator, controller: HostSessionController, armingBox: WakeGateArmingBox, deviceKey: Data) {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let armingBox = WakeGateArmingBox(HostScreenArming(devices: armed ? [
        HostScreenDeviceArming(devicePublicKey: deviceKey, deviceName: "Kestrel Laptop Pro", armedAt: Date())
    ] : []))
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        inputInjectorFactory: FakeInputInjectorFactory(),
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { armingBox.arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenResumeTicketStore: resumeTicketStore,
        displayWake: wake,
        log: { _ in }
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey,
        hostCertificateHash: nil
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))
    let coordinator = HostSessionCoordinator(
        controller: controller,
        media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
        videoSink: FakeVideoSink(),
        workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() }
    )
    return (coordinator, controller, armingBox, deviceKey)
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
        expect(
            power.endedUserActivityCount == 0,
            "the user-activity declaration is untouched by a hold release; nothing here ever woke a display, so nothing was ever declared, got \(power.endedUserActivityCount)"
        )
        controller.releaseDisplaysAwake()
        expect(
            power.allowedSleepCount == 1,
            "and a release with nothing left holding changes nothing, got \(power.allowedSleepCount)"
        )
    }
    print("PASS: the prevent-sleep hold is counted, so the last session to end is the one that drops it")

    do {
        // `releaseEveryHold()` is the belt-and-braces path this process
        // registers for its own shutdown, not a per-session teardown -- it
        // must leave nothing declared no matter what, so it releases the
        // user-activity declaration outright rather than only when its own
        // bookkeeping says a wake is still owed one.
        let power = FakeDisplayPower()
        let controller = DisplayWakeController(
            power: power,
            displays: { [] },
            wait: { _ in }
        )
        controller.holdDisplaysAwake()
        controller.holdDisplaysAwake()
        controller.releaseEveryHold()
        expect(
            power.allowedSleepCount == 1,
            "releaseEveryHold drops every session's hold at once, whatever the count, got \(power.allowedSleepCount)"
        )
        expect(
            !power.isUserActivityDeclared,
            "and leaves nothing declared, even though nothing here ever woke a display to declare it in the first place"
        )
        expect(!controller.isHoldingDisplaysAwake, "after which nothing is holding this machine's displays awake")
        controller.releaseEveryHold()
        expect(
            power.allowedSleepCount == 1,
            "a second releaseEveryHold with nothing left holding changes nothing, got \(power.allowedSleepCount)"
        )
    }

    print("PASS: releaseEveryHold also releases the user-activity declaration, whatever the hold count was")

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
        guard case let .hostScreenList(displays) = try! await controller.offerHostScreenListWakingDisplays() else {
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
            loggedLines.contains("Sensorium host: offered 1 host screens to Kestrel Laptop Pro: External Display"),
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
        guard case let .hostScreenList(displays) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "a display that would not wake still produces an offer, with nothing in it")
            return
        }
        expect(displays.isEmpty, "a display that would not wake is offered to no one, got \(displays.count)")
        expect(
            loggedLines == [
                "Sensorium host: did not offer host screen \"External Display\" to Kestrel Laptop Pro: asleep"
            ],
            "and the gap still reads asleep, got \(loggedLines)"
        )
    }

    print("PASS: a host screen that stays asleep after being woken is refused exactly as before")

    do {
        // A canvas Sensorium created is never a host-screen target, so a
        // sleeping one is never offered, whatever the wake does.
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
        guard case let .hostScreenList(displays) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "the awake display is still offered with a canvas asleep beside it")
            return
        }
        expect(
            displays.map(\.label) == ["External Display"],
            "the canvas is not offered and the physical display still is, got \(displays.map(\.label))"
        )
        expect(
            power.userActivityDeclarations == 1,
            "and the offer declares user activity once, as every armed offer does, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: a sleeping canvas Sensorium created is never offered")

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
        guard case let .hostScreenList(displays) = try! await controller.offerHostScreenListWakingDisplays() else {
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
        // is never offerable, however awake it gets.
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
        guard case let .hostScreenList(displays) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "the display being mirrored is still offered")
            return
        }
        expect(
            displays.map(\.label) == ["External Display"],
            "the mirror is not offered and the display it mirrors still is, got \(displays.map(\.label))"
        )
        expect(
            power.userActivityDeclarations == 1,
            "and the offer declares user activity once, as every armed offer does, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: a sleeping display that mirrors another one is never offered")

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
            !power.isUserActivityDeclared,
            "the wake that started this session has already finished, so its declaration is already released even though the session is still live"
        )
        expect(
            power.preventedSleepNames == [DisplayWakeController.assertionName],
            "and the live session holds this machine's displays awake on its own, independent of that declaration, got \(power.preventedSleepNames)"
        )
        expect(power.allowedSleepCount == 0, "the hold lasts as long as the session does")
        _ = try? await coordinator.handleWritingResponse(.goodbye(reason: "viewer-left"))
        expect(
            power.allowedSleepCount == 1,
            "and is dropped when the session ends, got \(power.allowedSleepCount)"
        )
        expect(
            power.endedUserActivityCount == 1,
            "with the user-activity declaration already released by the wake itself, not by the session ending, got \(power.endedUserActivityCount)"
        )
    }
    print("PASS: a session holds this machine's displays awake from start to end, independent of the wake that started it")

    do {
        // The host quitting mid-session reaches the same teardown a goodbye
        // does, and must still leave the display-sleep hold dropped.
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
            media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() }
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        expect(power.allowedSleepCount == 0, "the hold lasts as long as the session does")
        expect(
            !power.isUserActivityDeclared,
            "the wake that started this session has already released its own declaration before the host ever quits"
        )
        await coordinator.sessionDidEnd(reason: "host-quit")
        expect(
            power.allowedSleepCount == 1,
            "the host quitting mid-session drops the display-sleep hold the same way a goodbye does, got \(power.allowedSleepCount)"
        )
        expect(
            !power.isUserActivityDeclared,
            "and this machine is left with nothing declared, got isUserActivityDeclared=\(power.isUserActivityDeclared)"
        )
    }

    print("PASS: the host quitting mid-session drops the display-sleep hold and leaves nothing declared")

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
            resumeTicket: nil
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

    do {
        // The field failure on a locked Mac mini: display sleep had taken its
        // monitors offline, so the only display online was macOS's awake
        // headless stand-in, nothing read asleep, and the offer named the
        // stand-in. Its capture was black.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([headlessStandInSnapshot()])
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in
                if power.userActivityDeclarations > 0 {
                    list.displays = [
                        sleepingDisplaySnapshot(id: 2, asleep: false),
                        sleepingDisplaySnapshot(id: 3, asleep: false)
                    ]
                }
            },
            timeoutSeconds: 5,
            pollSeconds: 0.1
        )
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        guard case let .hostScreenList(displays) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "an armed device is offered this machine's displays")
            return
        }
        expect(
            power.userActivityDeclarations == 1,
            "the offer declares user activity even though no display reads asleep, got \(power.userActivityDeclarations)"
        )
        expect(
            displays.count == 2 && displays.allSatisfy { $0.logicalWidth == 2560 },
            "and offers the two monitors that came back, not the stand-in, got \(displays.map(\.label))"
        )
    }

    print("PASS: an offer made while display sleep has taken the monitors offline wakes them and offers them")

    do {
        let power = FakeDisplayPower()
        let list = FakeDisplayList([
            sleepingDisplaySnapshot(id: 2, asleep: false),
            sleepingDisplaySnapshot(id: 3, asleep: false)
        ])
        var waits = 0
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in waits += 1 },
            timeoutSeconds: 5,
            pollSeconds: 0.1
        )
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        guard case let .hostScreenList(displays) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "an armed device is offered this machine's displays")
            return
        }
        expect(
            power.userActivityDeclarations == 1,
            "an offer on an awake machine still declares user activity, got \(power.userActivityDeclarations)"
        )
        expect(waits == 0, "and builds the offer without waiting at all, got \(waits) waits")
        expect(displays.count == 2, "offering both displays, got \(displays.count)")
    }

    print("PASS: an offer on a machine whose monitors are already on is built without waiting")

    do {
        // A Mac mini with no monitor attached: the stand-in is all it has,
        // and it is offered once the bounded wait for a monitor runs out.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([headlessStandInSnapshot()])
        var waits = 0
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in waits += 1 },
            timeoutSeconds: 5,
            pollSeconds: 0.1,
            settleSeconds: 3
        )
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        guard case let .hostScreenList(displays) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "an armed device is offered this machine's displays")
            return
        }
        expect(
            displays.count == 1 && displays.first?.logicalWidth == 1920,
            "the stand-in is offered when it is the only display, got \(displays.map(\.label))"
        )
        expect(waits == 30, "after a wait bounded by the settle time, got \(waits) polls")
    }

    print("PASS: a machine with no monitor still offers the headless stand-in after a bounded wait")

    do {
        let power = FakeDisplayPower()
        let wake = DisplayWakeController(
            power: power,
            displays: { [sleepingDisplaySnapshot(id: 7, asleep: false)] },
            wait: { _ in }
        )
        let fixture = makeWakeHostScreenFixture(
            display: sleepingDisplaySnapshot(id: 7, asleep: false),
            wake: wake,
            availability: HostCaptureAvailability(),
            onStreamUnrecoverable: { _ in },
            hostScreenMediaFactory: { _ in FakeScalableCanvasMedia() }
        )
        _ = try? await fixture.coordinator.handleFirstResponse(.hostScreenRequest(
            token: fixture.token,
            resumeTicket: nil
        ))
        expect(
            power.userActivityDeclarations == 1,
            "a host-screen session start declares user activity even when no display reads asleep, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: a host-screen session start declares user activity whatever the displays report")

    do {
        // Monitors that came back beside the stand-in: the stand-in draws
        // nothing a person sees, so only the monitor is offered.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([headlessStandInSnapshot(), sleepingDisplaySnapshot(id: 2, asleep: false)])
        let wake = DisplayWakeController(power: power, displays: { list.read() }, wait: { _ in })
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        guard case let .hostScreenList(displays) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "an armed device is offered this machine's displays")
            return
        }
        expect(
            displays.count == 1 && displays.first?.logicalWidth == 2560,
            "the stand-in is left out while a monitor is online, got \(displays.map(\.label))"
        )
    }

    print("PASS: the headless stand-in is not offered beside a monitor")

    do {
        // Two monitors that come back one after the other: the offer waits
        // for the second rather than settling on the first.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([headlessStandInSnapshot()])
        var polls = 0
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in
                polls += 1
                if polls == 1 {
                    list.displays = [sleepingDisplaySnapshot(id: 2, asleep: false)]
                } else if polls == 3 {
                    list.displays = [
                        sleepingDisplaySnapshot(id: 2, asleep: false),
                        sleepingDisplaySnapshot(id: 3, asleep: false)
                    ]
                }
            },
            timeoutSeconds: 5,
            pollSeconds: 0.1,
            settleSeconds: 3
        )
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        guard case let .hostScreenList(displays) = try! await controller.offerHostScreenListWakingDisplays() else {
            expect(false, "an armed device is offered this machine's displays")
            return
        }
        expect(displays.count == 2, "both staggered monitors are offered, got \(displays.count)")
        expect(polls < 30, "and the wait ends once the set has held still, not at the bound, got \(polls) polls")
    }

    print("PASS: monitors that come back one after the other are all offered")

    do {
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(id: 2, asleep: true)])
        let wake = DisplayWakeController(power: power, displays: { list.read() }, wait: { _ in })
        let gate = wakeGateController(displays: list, displayWake: wake, authenticate: false, armed: true)
        _ = try? await gate.controller.offerHostScreenListWakingDisplays()
        expect(
            power.userActivityDeclarations == 0,
            "an offer to a peer that has not authenticated wakes nothing, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: an offer to an unauthenticated peer makes no power call")

    do {
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(id: 2, asleep: true)])
        let wake = DisplayWakeController(power: power, displays: { list.read() }, wait: { _ in })
        let gate = wakeGateController(displays: list, displayWake: wake, authenticate: true, armed: false)
        _ = try? await gate.controller.offerHostScreenListWakingDisplays()
        expect(
            power.userActivityDeclarations == 0,
            "an offer to an authenticated device that is not armed wakes nothing, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: an offer to an unarmed device makes no power call")

    do {
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(id: 2, asleep: true)])
        let wake = DisplayWakeController(power: power, displays: { list.read() }, wait: { _ in })
        let connections = HostDeviceConnectionRegistry()
        let gate = wakeGateController(
            displays: list, displayWake: wake, authenticate: true, armed: true, connections: connections
        )
        connections.stopConnections(for: gate.deviceKey)
        let offer = try? await gate.controller.offerHostScreenListWakingDisplays()
        expect(
            power.userActivityDeclarations == 0,
            "a device the host stopped wakes nothing, got \(power.userActivityDeclarations)"
        )
        if case let .hostScreenList(displays)? = offer {
            expect(displays.isEmpty, "and is offered nothing, got \(displays.count)")
        }
    }

    print("PASS: an offer after the host stopped the device makes no power call and offers nothing")

    do {
        let power = FakeDisplayPower()
        let wake = DisplayWakeController(
            power: power,
            displays: { [sleepingDisplaySnapshot(id: 7, asleep: false)] },
            wait: { _ in }
        )
        let fixture = makeWakeHostScreenFixture(
            display: sleepingDisplaySnapshot(id: 7, asleep: false),
            wake: wake,
            availability: HostCaptureAvailability(),
            onStreamUnrecoverable: { _ in },
            hostScreenMediaFactory: { _ in FakeScalableCanvasMedia() }
        )
        _ = try? await fixture.coordinator.handleFirstResponse(.hostScreenRequest(
            token: Data(repeating: 0xA5, count: 32),
            resumeTicket: nil
        ))
        expect(
            power.userActivityDeclarations == 0,
            "a host-screen request carrying a token this host never minted wakes nothing, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: a host-screen request with an unminted token makes no power call")

    do {
        // The field bug, half one: an offer with no request behind it at all
        // never takes a hold, so under the old hold-tied release this
        // declaration was never released either.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(asleep: false)])
        let wake = DisplayWakeController(power: power, displays: { list.read() }, wait: { _ in })
        let controller = armedHostScreenController(displays: list, displayWake: wake, log: { _ in })
        _ = try! await controller.offerHostScreenListWakingDisplays()
        expect(
            power.userActivityDeclarations == 1,
            "the offer wakes this machine, got \(power.userActivityDeclarations)"
        )
        expect(
            !power.isUserActivityDeclared,
            "and releases the declaration once the offer is built, even though the viewer never went on to request anything"
        )
        _ = try? controller.handle(.goodbye(reason: "viewer-left"))
        expect(
            !power.isUserActivityDeclared,
            "disconnecting afterward leaves nothing declared either, got isUserActivityDeclared=\(power.isUserActivityDeclared)"
        )
    }

    print("PASS: an offer-only connection releases the declaration once the offer is built, with no session ever held")

    do {
        // The field bug, half two: a request the controller goes on to
        // refuse still wakes this machine first, since waking happens
        // before the request is judged. A refused request never takes a
        // hold either, so it needs the same per-wake release.
        let power = FakeDisplayPower()
        let display = sleepingDisplaySnapshot(asleep: false)
        let wake = DisplayWakeController(power: power, displays: { [display] }, wait: { _ in })
        let fixture = makeDecliningWakeFixture(
            display: display,
            wake: wake,
            outcome: .refused(reason: HostScreenPresenceRule.declinedReason)
        )
        let reply = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        ))
        expect(
            reply == .hostScreenRefused(reason: "host-screen-presence-declined"),
            "the request is refused, got \(String(describing: reply))"
        )
        expect(
            power.userActivityDeclarations == 1,
            "but this machine was still woken before the refusal was reached, got \(power.userActivityDeclarations)"
        )
        expect(
            !power.isUserActivityDeclared,
            "and the declaration is released once that wake finishes, whether or not the request it was for was ever admitted"
        )
    }

    print("PASS: a refused host-screen request still releases the declaration the wake before it made")

    do {
        // Two overlapping wakes: the assertion is one per process, so a
        // wake that finishes first must not release it out from under one
        // that is still running.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(id: 7, asleep: true)])
        var controllerBox: DisplayWakeController!
        var secondStarted = false
        var secondResult: Bool?
        var isDeclaredWhenNestedFinished: Bool?
        let controller = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in
                if !secondStarted {
                    secondStarted = true
                    secondResult = await controllerBox.wakeDisplays(targets: [7])
                    isDeclaredWhenNestedFinished = power.isUserActivityDeclared
                } else {
                    list.displays = [sleepingDisplaySnapshot(id: 7, asleep: false)]
                }
            },
            timeoutSeconds: 5,
            pollSeconds: 0.1
        )
        controllerBox = controller
        let firstResult = await controller.wakeDisplays(targets: [7])
        expect(firstResult, "the outer wake reports the display awake once the overlapping one has woken it")
        expect(
            secondResult == true,
            "and the overlapping wake it started reports the display awake too, got \(String(describing: secondResult))"
        )
        expect(
            power.userActivityDeclarations == 2,
            "each overlapping wake still makes its own declaration, got \(power.userActivityDeclarations)"
        )
        expect(
            isDeclaredWhenNestedFinished == true,
            "the declaration is still standing once the first wake to finish returns, because the other one is still running"
        )
        expect(
            power.endedUserActivityCount == 1,
            "and is released exactly once, when the second and last wake to finish returns, got \(power.endedUserActivityCount)"
        )
        expect(!power.isUserActivityDeclared, "leaving nothing declared once both have finished")
    }

    print("PASS: two overlapping wakes release the declaration only once both have finished")

    do {
        // The hold and the wake are two different assertions entirely: a
        // session keeps the displays awake with its own hold, independent
        // of whatever the wake that started it already released.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(asleep: true)])
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in list.displays = [sleepingDisplaySnapshot(asleep: false)] },
            timeoutSeconds: 5,
            pollSeconds: 0.1
        )
        let woke = await wake.wakeDisplays()
        expect(woke, "the display wakes before the hold is taken")
        expect(
            !power.isUserActivityDeclared,
            "and the wake has already released its own declaration by the time it returns"
        )
        wake.holdDisplaysAwake()
        expect(
            wake.isHoldingDisplaysAwake && power.preventedSleepNames == [DisplayWakeController.assertionName],
            "a session can still take its own hold afterward, got \(power.preventedSleepNames)"
        )
        expect(
            !power.isUserActivityDeclared,
            "with the user-activity declaration staying released the whole time; the hold never touches it"
        )
    }

    print("PASS: a live session's hold on the displays outlives the wake's own declaration")

    do {
        // Security: a viewer resending an already-used token once its
        // session is already live must not wake this machine again -- that
        // would keep resetting the idle timer with no badge and no session
        // record to show for it.
        let display = sleepingDisplaySnapshot(id: 7, asleep: false)
        let power = FakeDisplayPower()
        let wake = DisplayWakeController(power: power, displays: { [display] }, wait: { _ in })
        let fixture = makeWakeHostScreenFixture(
            display: display,
            wake: wake,
            availability: HostCaptureAvailability(),
            onStreamUnrecoverable: { _ in },
            hostScreenMediaFactory: { _ in FakeScalableCanvasMedia() }
        )
        guard case .hostScreenReady = try! await fixture.coordinator.handleFirstResponse(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        )) else {
            expect(false, "the fixture's own request is admitted")
            return
        }
        expect(
            power.userActivityDeclarations == 1,
            "the request that starts the session wakes this machine once, got \(power.userActivityDeclarations)"
        )
        let resend = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        ))
        expect(
            resend == .hostScreenRefused(reason: "host-screen-session-active"),
            "a resend of the same token while the session is live is refused, got \(String(describing: resend))"
        )
        expect(
            power.userActivityDeclarations == 1,
            "and wakes nothing more, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: resending an already-used token while its session is live wakes nothing more")

    do {
        // Security: once a person at the host has already declined, a
        // resend of the same token must not wake this machine again
        // either.
        let power = FakeDisplayPower()
        let display = sleepingDisplaySnapshot(asleep: false)
        let wake = DisplayWakeController(power: power, displays: { [display] }, wait: { _ in })
        let fixture = makeDecliningWakeFixture(
            display: display,
            wake: wake,
            outcome: .refused(reason: HostScreenPresenceRule.declinedReason)
        )
        let first = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        ))
        expect(
            first == .hostScreenRefused(reason: "host-screen-presence-declined"),
            "the first request is refused with the decline's own reason, got \(String(describing: first))"
        )
        expect(
            power.userActivityDeclarations == 1,
            "which still wakes this machine once, before the decline is reached, got \(power.userActivityDeclarations)"
        )
        let resend = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        ))
        expect(
            resend == .hostScreenRefused(reason: "host-screen-presence-declined"),
            "a resend on the same connection is refused the same way, got \(String(describing: resend))"
        )
        expect(
            power.userActivityDeclarations == 1,
            "and wakes nothing more, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: resending an already-declined token wakes nothing more")

    do {
        // Security: a resume ticket this host cannot validate is refused on
        // its own terms, and a resend with the same invalid ticket must not
        // wake this machine either.
        let power = FakeDisplayPower()
        let display = sleepingDisplaySnapshot(id: 7, asleep: false)
        let wake = DisplayWakeController(power: power, displays: { [display] }, wait: { _ in })
        let fixture = makeMutableArmingWakeFixture(
            display: display, wake: wake, armed: true, resumeTicketStore: HostScreenResumeTicketStore()
        )
        guard case let .hostScreenList(displays) = try! fixture.controller.offerHostScreenList(),
              let entry = displays.first else {
            expect(false, "the fixture's own offer names the display it was armed for")
            return
        }
        let garbageTicket = Data(repeating: 0xEE, count: 16)
        let first = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: entry.opaqueToken, resumeTicket: garbageTicket
        ))
        expect(
            first == .hostScreenRefused(reason: "host-screen-resume-refused"),
            "an invalid resume ticket is refused on its own terms, got \(String(describing: first))"
        )
        expect(power.userActivityDeclarations == 0, "and wakes nothing, got \(power.userActivityDeclarations)")
        let resend = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: entry.opaqueToken, resumeTicket: garbageTicket
        ))
        expect(
            resend == .hostScreenRefused(reason: "host-screen-resume-refused"),
            "a resend with the same invalid ticket is refused the same way, got \(String(describing: resend))"
        )
        expect(power.userActivityDeclarations == 0, "and wakes nothing more, got \(power.userActivityDeclarations)")
    }

    print("PASS: a resend with an invalid resume ticket wakes nothing more")

    do {
        // Security: `HostScreenDeviceRevocation.turnOff` does not stop this
        // connection, so a device the person here just disarmed can still
        // send a request on it. Arming is read fresh, not a value captured
        // at hello or at the offer, so that request is refused, and wakes
        // nothing.
        let power = FakeDisplayPower()
        let display = sleepingDisplaySnapshot(id: 7, asleep: false)
        let wake = DisplayWakeController(power: power, displays: { [display] }, wait: { _ in })
        let fixture = makeMutableArmingWakeFixture(display: display, wake: wake, armed: true)
        guard case let .hostScreenList(displays) = try! fixture.controller.offerHostScreenList(),
              let entry = displays.first else {
            expect(false, "the fixture's own offer names the display it was armed for")
            return
        }
        fixture.armingBox.arming = HostScreenArming()
        let response = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: entry.opaqueToken, resumeTicket: nil
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-not-allowed"),
            "a device disarmed after hello, with its connection still open, is refused as any disarmed device is, got \(String(describing: response))"
        )
        expect(power.userActivityDeclarations == 0, "and wakes nothing, got \(power.userActivityDeclarations)")
    }

    print("PASS: a request from a device disarmed after hello wakes nothing")

    do {
        // Security: the hello-time offer wakes this machine only for a
        // device armed right now, not one that held an arming record at
        // some earlier point on this same connection.
        let power = FakeDisplayPower()
        let display = sleepingDisplaySnapshot(id: 7, asleep: true)
        let wake = DisplayWakeController(power: power, displays: { [display] }, wait: { _ in })
        let fixture = makeMutableArmingWakeFixture(display: display, wake: wake, armed: true)
        fixture.armingBox.arming = HostScreenArming()
        _ = try? await fixture.controller.offerHostScreenListWakingDisplays()
        expect(
            power.userActivityDeclarations == 0,
            "the hello offer for a device disarmed before it wakes nothing, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: the hello offer for a device disarmed before it wakes nothing")

    do {
        // Security: a refusal only the presence gate can give without
        // asking a person -- one already showing for another connection,
        // here, or want of a gate elsewhere -- is retryable, and stays
        // retryable on this connection. Without a cap, each resend into it
        // would wake this machine again, resetting its idle timer with no
        // badge and no session to show for it.
        let power = FakeDisplayPower()
        let display = sleepingDisplaySnapshot(asleep: false)
        let wake = DisplayWakeController(power: power, displays: { [display] }, wait: { _ in })
        let fixture = makeDecliningWakeFixture(
            display: display, wake: wake,
            outcome: .refused(reason: HostScreenPresenceGate.alreadyAskingReason)
        )
        let first = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        ))
        expect(
            first == .hostScreenRefused(reason: "host-screen-presence-check-required"),
            "a gate already showing for another connection refuses without a sticky answer, got \(String(describing: first))"
        )
        expect(power.userActivityDeclarations == 1, "which still wakes this machine once, got \(power.userActivityDeclarations)")
        let resend = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        ))
        expect(
            resend == .hostScreenRefused(reason: "host-screen-presence-check-required"),
            "a resend on the same connection is refused the same retryable way, got \(String(describing: resend))"
        )
        expect(power.userActivityDeclarations == 1, "but wakes this machine no more than once for it, got \(power.userActivityDeclarations)")
        let secondResend = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        ))
        expect(
            secondResend == .hostScreenRefused(reason: "host-screen-presence-check-required"),
            "a further resend is refused the same retryable way too, got \(String(describing: secondResend))"
        )
        expect(power.userActivityDeclarations == 1, "and still wakes at most once, got \(power.userActivityDeclarations)")
    }

    print("PASS: repeated retryable refusals on one connection wake at most once")

    do {
        // A legitimate first request wakes this machine even when the
        // display its token names has gone offline since the offer -- the
        // exact case a session-start wake exists to recover -- and a
        // resumed session with a valid ticket wakes it too.
        let power = FakeDisplayPower()
        let list = FakeDisplayList([sleepingDisplaySnapshot(id: 7, asleep: false)])
        let wake = DisplayWakeController(
            power: power,
            displays: { list.read() },
            wait: { _ in list.displays = [sleepingDisplaySnapshot(id: 7, asleep: false)] },
            timeoutSeconds: 5,
            pollSeconds: 0.1
        )
        let identity = try! DeviceIdentity.generate()
        let deviceKey = identity.publicKey
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(devicePublicKey: deviceKey, deviceName: "Kestrel Laptop Pro", armedAt: Date())
        ])
        let resumeStore = HostScreenResumeTicketStore()

        func makeConnection() -> (coordinator: HostSessionCoordinator, controller: HostSessionController) {
            let controller = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                approvedPublicKeys: [deviceKey],
                requireAuthentication: true,
                inputInjectorFactory: FakeInputInjectorFactory(),
                keyConfinement: .hostScreen,
                hostScreenArmingProvider: { arming },
                hostScreenCurrentDisplaysProvider: { list.read() },
                hostScreenResumeTicketStore: resumeStore,
                displayWake: wake,
                log: { _ in }
            )
            let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
                protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey,
                hostCertificateHash: nil
            )
            _ = try! controller.handle(.authenticatedHello(
                protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
            ))
            let coordinator = HostSessionCoordinator(
                controller: controller,
                media: onlyOnSurfaceZero(FakeScalableCanvasMedia()),
                videoSink: FakeVideoSink(),
                workspaces: CanvasSurfaceSlots { _ in FakeCanvasWorkspace() },
                hostScreenMediaFactory: { _ in FakeScalableCanvasMedia() },
                captureAvailability: HostCaptureAvailability()
            )
            return (coordinator, controller)
        }

        let first = makeConnection()
        guard case let .hostScreenList(firstDisplays) = try! first.controller.offerHostScreenList(),
              let firstEntry = firstDisplays.first else {
            expect(false, "the fixture's own offer names the display it was armed for")
            return
        }
        // Gone offline since the offer, exactly the case a session-start
        // wake exists to recover -- the coordinator's own wake gate must
        // never require a live display resolution to wake this machine.
        list.displays = [offlineDisplaySnapshot(id: 7)]
        let firstReply = try! await first.coordinator.handleFirstResponse(.hostScreenRequest(
            token: firstEntry.opaqueToken, resumeTicket: nil
        ))
        guard case let .hostScreenReady(_, mintedTicket) = firstReply else {
            expect(false, "the fixture's own first request is admitted once the wake brings its display back, got \(String(describing: firstReply))")
            return
        }
        expect(
            power.userActivityDeclarations == 1,
            "a legitimate first request wakes this machine, got \(power.userActivityDeclarations)"
        )
        _ = try? await first.coordinator.handleWritingResponse(.goodbye(reason: "viewer-left"))

        let second = makeConnection()
        guard case let .hostScreenList(secondDisplays) = try! second.controller.offerHostScreenList(),
              let secondEntry = secondDisplays.first else {
            expect(false, "the second connection's own offer names the display too")
            return
        }
        let resumed = try! await second.coordinator.handleFirstResponse(.hostScreenRequest(
            token: secondEntry.opaqueToken, resumeTicket: mintedTicket
        ))
        guard case .hostScreenReady = resumed else {
            expect(false, "a resume with a valid ticket is admitted, got \(String(describing: resumed))")
            return
        }
        expect(
            power.userActivityDeclarations == 2,
            "and a resumed session with a valid ticket wakes this machine too, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: a legitimate first request still wakes, and a resumed session with a valid ticket still wakes")

    do {
        // The cap is scoped to one request cycle, not to the connection's
        // whole life: a session that starts, ends with `goodbye`, and is
        // then started again on the same connection is a session actually
        // starting, exactly what the cap is supposed to allow past it.
        let power = FakeDisplayPower()
        let display = sleepingDisplaySnapshot(id: 7, asleep: false)
        let wake = DisplayWakeController(power: power, displays: { [display] }, wait: { _ in })
        let fixture = makeWakeHostScreenFixture(
            display: display,
            wake: wake,
            availability: HostCaptureAvailability(),
            onStreamUnrecoverable: { _ in },
            hostScreenMediaFactory: { _ in FakeScalableCanvasMedia() }
        )
        guard case .hostScreenReady = try! await fixture.coordinator.handleFirstResponse(.hostScreenRequest(
            token: fixture.token, resumeTicket: nil
        )) else {
            expect(false, "the fixture's own first request is admitted")
            return
        }
        expect(power.userActivityDeclarations == 1, "the first session wakes this machine once, got \(power.userActivityDeclarations)")
        _ = try? await fixture.coordinator.handleWritingResponse(.goodbye(reason: "viewer-left"))
        guard case let .hostScreenList(displays) = try! fixture.controller.offerHostScreenList(),
              let entry = displays.first else {
            expect(false, "the same connection's own second offer names the display again")
            return
        }
        guard case .hostScreenReady = try! await fixture.coordinator.handleFirstResponse(.hostScreenRequest(
            token: entry.opaqueToken, resumeTicket: nil
        )) else {
            expect(false, "a second session on the same connection, after the first ended, is admitted")
            return
        }
        expect(
            power.userActivityDeclarations == 2,
            "and wakes this machine again, since a session actually started in between, got \(power.userActivityDeclarations)"
        )
    }

    print("PASS: a session that starts, ends, and starts again on the same connection wakes this machine each time")
}

import Foundation
import SensoriumClient
import SensoriumCore

/// The viewer's application controller, driven end to end without AppKit, a
/// window server or a socket: fake windows, a fake event loop and a scripted
/// control connection are all it takes to watch a dial fail on the launch
/// window's own row, a session go live and end, the quit latch reach the
/// event loop, and an enter URL select without dialling.

// MARK: - Fakes

@MainActor
final class FakeViewerLaunchWindow: ViewerLaunchWindow {
    private(set) var showCount = 0
    private(set) var hideCount = 0
    private(set) var showListCount = 0
    private(set) var selectedHostPublicKeys: [Data] = []
    private(set) var connectRequestedKeys: [Data] = []
    private(set) var connectStartedKeys: [Data] = []
    private(set) var attemptFailures: [(reason: String, offersFallback: Bool)] = []
    private(set) var stoppedConnectingKeys: [Data] = []
    private(set) var stoppedTryingCount = 0
    private(set) var pairAgainHosts: [SavedHost] = []

    var loadTailnet: (() async -> TailnetDevicePickerState)?
    var sendPairIntent: ((ViewerPairingDevice) async -> ViewerPairIntentAttempt)?
    var pair: ((ViewerPairingDevice?, ViewerPairingSubmission) async -> ViewerPairingResult)?
    var onConnect: ((SavedHost) -> Void)?
    var onCancelConnecting: (() -> Void)?
    var onConnectAsVirtualDisplayFallback: ((Data) -> Void)?
    var onCloseRequested: (() -> Void)?
    var onCodeStepAbandoned: (() -> Void)?

    func show() { showCount += 1 }
    func hide() { hideCount += 1 }
    func showList() { showListCount += 1 }
    func select(hostPublicKey: Data) { selectedHostPublicKeys.append(hostPublicKey) }
    func connectRequested(hostPublicKey: Data) { connectRequestedKeys.append(hostPublicKey) }
    func connectStarted(hostPublicKey: Data) { connectStartedKeys.append(hostPublicKey) }

    func attemptFailed(reason: String, offersConnectAsVirtualDisplayFallback: Bool) {
        attemptFailures.append((reason, offersConnectAsVirtualDisplayFallback))
    }

    func stoppedConnecting(hostPublicKey: Data) { stoppedConnectingKeys.append(hostPublicKey) }
    func stoppedTrying() { stoppedTryingCount += 1 }
    func beginPairAgain(with host: SavedHost) { pairAgainHosts.append(host) }
}

@MainActor
final class FakeViewerEventLoop: ViewerEventLoop {
    private(set) var runCount = 0
    private(set) var stopCount = 0

    /// A real loop takes the thread over here. Nothing does in a test, so the
    /// task the controller started keeps running and the checks below watch
    /// it from the same actor.
    func run() { runCount += 1 }
    func stop() { stopCount += 1 }
}

@MainActor
final class FakeViewerPrompts: ViewerPrompts {
    private(set) var startupFailures: [ViewerStartupFailurePrompt] = []
    var startupFailureChoice = ViewerStartupFailureChoice.tryAgain
    var newKeyConfirmed = false

    func showStartupFailure(_ prompt: ViewerStartupFailurePrompt) async -> ViewerStartupFailureChoice {
        startupFailures.append(prompt)
        return startupFailureChoice
    }

    func dismissStartupFailure() {}

    func confirmNewKey() async -> Bool { newKeyConfirmed }


    private(set) var notices: [ViewerNotice] = []

    func showNotice(_ notice: ViewerNotice) async { notices.append(notice) }
}

/// `RecordingSurfaceWindow` with the chrome half the application controller
/// drives: the status overlay, the four menus and the notices.
nonisolated final class FakeViewerSessionWindow: ViewerSessionWindow, @unchecked Sendable {
    let surfaceID: UInt32
    nonisolated let videoSink = SurfaceVideoSink()
    private let lock = NSLock()
    private let viewport: ClientViewportController
    private var decodedFrameHandler: (@Sendable (DecodedFrame) -> Void)?
    private var statuses: [ViewerSessionStatus] = []
    private var titles: [String] = []
    private var shows = 0
    private var closes = 0

    var onCloseRequested: (() -> Void)?
    var onSessionAction: ((ViewerSessionAction) -> Void)?
    var onSelectDisplayCount: ((Int) -> Void)?
    var onSelectRealScreen: ((Data?) -> Void)?
    var onSelectHostScreenMode: ((String) -> Void)?
    var onSelectClipboardSharing: ((Bool) -> Void)?
    var onSelectStartTarget: ((StartTarget) -> Void)?
    var onDidBecomeKey: (() -> Void)?

    init(surfaceID: UInt32) {
        self.surfaceID = surfaceID
        viewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: RecordingInputSink()
        )
    }

    var appliedStatuses: [ViewerSessionStatus] {
        lock.lock()
        defer { lock.unlock() }
        return statuses
    }

    var appliedTitles: [String] {
        lock.lock()
        defer { lock.unlock() }
        return titles
    }

    var showCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return shows
    }

    var closeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return closes
    }

    // SessionCanvasWindow

    func startDecoding(
        latency: SessionLatencyMonitor?,
        onDecodedFrame: (@Sendable (DecodedFrame) -> Void)?
    ) throws {
        lock.lock()
        decodedFrameHandler = onDecodedFrame
        lock.unlock()
    }

    func canvasObserver() -> ClientViewportController { viewport }

    func receive(_ packet: EncodedVideoFramePacket, receivedAtNanoseconds: Int64) throws {}

    /// Stands in for a decode finishing. A real window reports here once its
    /// decoder hands back a picture; the controller is watching only for the
    /// first such report, which is what puts the window on screen.
    func reportDecodedFrame() {
        lock.lock()
        let handler = decodedFrameHandler
        lock.unlock()
        handler?(makeTestDecodedFrame())
    }

    func stopDecoding() {}
    func updateSessionHUD(_ snapshot: SessionHUDSnapshot) {}

    // SessionWindowChrome

    func attach(session: ClientSessionController) async {}

    func show() async {
        recordShow()
    }

    private func recordShow() {
        lock.lock()
        shows += 1
        lock.unlock()
    }

    func close() {
        lock.lock()
        closes += 1
        lock.unlock()
    }

    func cascadeIfUnplaced(from other: any SessionWindowChrome) {}

    func updateTitle(_ title: String) {
        lock.lock()
        titles.append(title)
        lock.unlock()
    }

    func apply(status: ViewerSessionStatus) {
        lock.lock()
        statuses.append(status)
        lock.unlock()
    }

    func updateDisplayCount(_ count: Int) {}
    func updateIsHostScreenSession(_ isHostScreenSession: Bool) {}
    func updateScreenMenu(displays: [HostScreenListEntry], selectedToken: Data?, canvasAvailable: Bool) {}
    func updateHostScreenModes(_ modes: [HostScreenModeEntry], currentModeID: String?) {}
    func updateStartTargetPreference(_ preference: StartTarget) {}
    func updateClipboardSharingEnabled(_ enabled: Bool) {}
    func showDisplayCountRefusal(reason: String) {}
    func showHostScreenModeRefusal(_ line: String) {}
    func showClipboardRefusal(_ line: String) {}

    // ShortcutForwardingTarget

    var viewerWindowState: ViewerWindowState {
        ViewerWindowState(surfaceID: surfaceID, hasKeyFocus: true, isFullscreen: false)
    }
    func forwardShortcut(keyCode: UInt16, isDown: Bool, modifiers: CanvasModifierFlags) {}
    func releaseToLocalMachine() {}
}

@MainActor
final class FakeSessionWindowFactory: SessionWindowFactory {
    private(set) var made: [FakeViewerSessionWindow] = []

    func makeSessionWindow(
        title: String,
        session: ClientSessionController,
        surfaceID: UInt32,
        hostName: String,
        shortcutMode: SystemShortcutMode,
        initialStreamScalePreference: StreamScalePreference,
        savedHostStore: any SavedHostStoring,
        savedHostPublicKey: Data
    ) throws -> any ViewerSessionWindow {
        let window = FakeViewerSessionWindow(surfaceID: surfaceID)
        made.append(window)
        return window
    }
}

@MainActor
final class FakeViewerWindowRegistry: ViewerWindowRegistry {
    private(set) var registered = 0
    private(set) var unregistered = 0

    func register(_ window: any ViewerSessionWindow) { registered += 1 }
    func unregister(_ window: any ViewerSessionWindow) { unregistered += 1 }
}

@MainActor
final class FakeViewerEnvironment: ViewerPlatformEnvironment {
    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    func applicationSupportDirectory() -> URL { directory }
    func deviceName() -> String { "Test Viewer" }
    func makePasteboard() -> any ClipboardPasteboard { FakeClipboardPasteboard() }

    func makeShortcutForwarder(mode: SystemShortcutMode) -> SystemShortcutForwarder {
        SystemShortcutForwarder(
            mode: mode,
            accessibility: FakeAccessibilityAuthorization(granted: false),
            interceptor: nil
        )
    }

    var isShortcutInterceptionGranted: Bool { false }
    func tailscaleAppURL() -> URL? { nil }
    func openTailscaleApp(_ url: URL) {}
}

/// Hands out one scripted connection per dial and counts the dials, so a
/// test can prove a refusal was never redialled or that nothing was dialled
/// at all.
final class ScriptedTransportFactory: ViewerTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let build: @Sendable () -> any ClientControlConnection
    private var dialledHosts: [String] = []

    init(_ build: @escaping @Sendable () -> any ClientControlConnection) {
        self.build = build
    }

    var dialCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return dialledHosts.count
    }

    func makeConnection(
        host: String,
        port: UInt16,
        tlsCertificateHash: Data?,
        transport: ClientTransportKind
    ) -> any ClientControlConnection {
        lock.lock()
        dialledHosts.append(host)
        lock.unlock()
        return build()
    }
}

/// A scripted connection that parks rather than closing when its script runs
/// out, so a test can watch one thing happen before deciding what the host
/// says next.
actor GatedControlConnection: ClientControlConnection {
    let deferredPackets = DeferredPacketQueue()
    private var pending: [SensoriumTransportPacket]
    private var waiter: CheckedContinuation<SensoriumTransportPacket, Never>?

    init(responses: [SensoriumTransportPacket]) {
        pending = responses
    }

    func push(_ packet: SensoriumTransportPacket) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: packet)
        } else {
            pending.append(packet)
        }
    }

    func start(timeout: TimeInterval) async throws {}
    nonisolated func beginHostSilenceWatch() {}
    nonisolated func endHostSilenceWatch() {}
    nonisolated func enqueue(_ packet: SensoriumTransportPacket) {}
    func send(_ message: SensoriumMessage) async throws {}
    func send(_ packet: SensoriumTransportPacket) async throws {}

    func receiveWirePacket() async throws -> SensoriumTransportPacket {
        if !pending.isEmpty {
            return pending.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }

    func close() async {}
}

// MARK: - Harness

@MainActor
private struct ViewerApplicationHarness {
    let directory: URL
    let launch = FakeViewerLaunchWindow()
    let prompts = FakeViewerPrompts()
    let eventLoop = FakeViewerEventLoop()
    let windowFactory = FakeSessionWindowFactory()
    let registry = FakeViewerWindowRegistry()
    let quit = QuitSignal()
    let transports: ScriptedTransportFactory
    let viewer: ViewerApplication

    init(
        directory: URL? = nil,
        connection: @escaping @Sendable () -> any ClientControlConnection = {
            ScriptedControlConnection(responses: [])
        }
    ) {
        self.directory = directory ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorium-viewer-app-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        transports = ScriptedTransportFactory(connection)
        let environment = FakeViewerEnvironment(directory: self.directory)
        let launch = launch
        let prompts = prompts
        let eventLoop = eventLoop
        let windowFactory = windowFactory
        let registry = registry
        viewer = ViewerApplication(
            environment: environment,
            transports: transports,
            quit: quit
        ) {
            ViewerGUI(
                launch: launch,
                prompts: prompts,
                eventLoop: eventLoop,
                windowFactory: windowFactory,
                windowRegistry: registry
            )
        }
    }

    var store: FileSavedHostStore {
        FileSavedHostStore(url: directory.appendingPathComponent("saved-host.json"))
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Lets the controller's own task run until something it was asked for has
    /// happened. Every check below is the end of a chain of awaits, not a
    /// fixed delay.
    func settle(until condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<600 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }
}

private func savedTestMachine(
    hostPublicKey: Data,
    startTargetPreference: StartTarget = .hostScreenWhenOffered
) -> SavedHost {
    SavedHost(
        displayName: "Studio",
        host: "studio.tail1234.ts.net",
        port: 7777,
        hostPublicKey: hostPublicKey,
        tlsCertificateHash: Data([9, 9, 9]),
        startTargetPreference: startTargetPreference
    )
}

// MARK: - Tests

@MainActor
func testViewerApplicationTests() async {
    await testViewerApplicationFailedDialReturnsToTheList()
    await testViewerApplicationLiveSessionAndHostEnding()
    await testViewerApplicationQuitLatchStopsTheEventLoop()
    await testViewerApplicationEnterURLSelectsWithoutDialling()
    await testViewerApplicationBareEnterURLIsTheEnterVerb()
    await testRedialAfterUnreachableFirstDialStillReachesHostScreen()
    await testRowClickAfterUnreachableKeepsDiallingUntilHostAnswers()
    await testRedialAfterRequestWasSentWithoutTicketStops()
    await testRedialAfterLiveSessionDropPresentsHeldTicket()
}

/// docs/ux-spec.md line 61: a failed attempt keeps a short reason on the row,
/// and the list is what the person comes back to.
@MainActor
private func testViewerApplicationFailedDialReturnsToTheList() async {
    // One refused canvas is a dead end the reconnect driver stops on, so this
    // is one dial and one report rather than a backoff schedule. Pinned to a
    // virtual display: the default start never asks for a canvas.
    let harness = ViewerApplicationHarness {
        ScriptedControlConnection(responses: [
            .control(.hostScreenRefused(reason: "host-screen-not-armed")),
            .control(.canvasRefused(reason: CanvasRefusalReason.canvasUnavailable, surfaceID: 0))
        ])
    }
    defer { harness.cleanUp() }
    let machine = savedTestMachine(hostPublicKey: Data([7]), startTargetPreference: .virtualDisplay)
    harness.store.save(machine)

    await harness.viewer.run(arguments: [])
    expect(harness.eventLoop.runCount == 1, "the controller hands the thread to the event loop exactly once")
    expect(await harness.settle(until: { harness.launch.showCount > 0 }), "the launch window is shown")

    harness.launch.onConnect?(machine)
    expect(
        await harness.settle(until: { !harness.launch.attemptFailures.isEmpty }),
        "the failed dial is reported on this machine's own row"
    )
    expect(
        harness.launch.attemptFailures.first?.reason == ViewerSessionFailureCopy.rowLine(
            for: .canvasRefused(reason: CanvasRefusalReason.canvasUnavailable), hostLabel: "Studio"
        ),
        "with the row's own short reason, got \(String(describing: harness.launch.attemptFailures.first?.reason))"
    )
    expect(
        harness.launch.attemptFailures.first?.offersFallback == false,
        "and no virtual-display fallback, since this attempt was not trying a host screen"
    )
    expect(
        await harness.settle(until: { harness.launch.stoppedTryingCount > 0 }),
        "and the row stops saying it is trying"
    )
    expect(
        await harness.settle(until: { harness.launch.showCount > 1 }),
        "and the list takes the screen back"
    )
    expect(harness.transports.dialCount == 1, "a refused canvas is dialled once, never redialled")
    expect(
        harness.windowFactory.made.first?.showCount == 0,
        "and the canvas window this attempt built was never put on screen"
    )

    harness.launch.onCloseRequested?()
    expect(await harness.settle(until: { harness.eventLoop.stopCount == 1 }), "and quitting ends the loop")
    print("PASS: a dial that fails before any picture is reported on the launch window's row and hands back the list")
}

/// docs/ux-spec.md lines 78-80: the session window appears when the session
/// goes live, and says so itself when the host ends it.
@MainActor
private func testViewerApplicationLiveSessionAndHostEnding() async {
    let hostIdentity = try! DeviceIdentity.generate()
    let machine = savedTestMachine(hostPublicKey: hostIdentity.publicKey, startTargetPreference: .virtualDisplay)
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-viewer-app-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // The viewer's own key has to exist before the host can sign a
    // `canvasReady` naming it, so it is read from the same file the
    // controller will read.
    let viewerIdentity = try! FileDeviceIdentityStore(
        url: directory.appendingPathComponent("device-identity.json")
    ).loadOrCreate()
    let signature = try! hostIdentity.sign(SensoriumFrameCodec.canvasReadyTranscript(
        displayID: 42,
        logicalWidth: 1920,
        logicalHeight: 1200,
        clientPublicKey: viewerIdentity.publicKey,
        surfaceID: 0
    ))

    let connection = GatedControlConnection(responses: [
        .control(.hostScreenRefused(reason: "host-screen-not-armed")),
        .control(.canvasReady(
            displayID: 42,
            logicalWidth: 1920,
            logicalHeight: 1200,
            hostSignature: signature,
            surfaceID: 0,
            hostName: "Studio Mac"
        ))
    ])
    let harness = ViewerApplicationHarness(directory: directory) { connection }
    defer { harness.cleanUp() }
    harness.store.save(machine)

    await harness.viewer.run(arguments: [])
    expect(await harness.settle(until: { harness.launch.showCount > 0 }), "the launch window is shown")
    harness.launch.onConnect?(machine)

    expect(
        await harness.settle(until: { !harness.windowFactory.made.isEmpty }),
        "the canvas window is built for the attempt"
    )
    let window = harness.windowFactory.made[0]
    expect(
        await harness.settle(until: { !window.appliedStatuses.isEmpty }),
        "and the connect is reported to it"
    )
    expect(window.showCount == 0, "and it is not on screen before there is a picture in it")

    window.reportDecodedFrame()
    expect(
        await harness.settle(until: { window.showCount > 0 }),
        "the canvas window goes on screen at the first picture"
    )
    expect(
        window.appliedStatuses.contains(where: { $0.phase == ViewerSessionPhase.live }),
        "and the window is told the session is live"
    )
    expect(harness.launch.hideCount > 0, "and the launch window steps aside")
    expect(
        window.appliedTitles.contains(ViewerWindowTitle.resolve(
            hostMachineName: "Studio Mac", savedHost: "studio.tail1234.ts.net", fallback: "Studio"
        )),
        "and the window is retitled from the host's own name, got \(window.appliedTitles)"
    )

    await connection.push(.control(.goodbye(reason: GoodbyeReason.stoppedByHost)))
    expect(
        await harness.settle(until: { window.appliedStatuses.last?.eyebrow == "SESSION ENDED" }),
        "an ending a person at the host chose is shown as an ending, got "
            + "\(String(describing: window.appliedStatuses.last?.eyebrow))"
    )
    expect(
        window.appliedStatuses.last?.detail == ViewerSessionFailureCopy.line(
            for: .stoppedByHost, hostLabel: "Studio"
        ),
        "with the host's own reason line, got \(String(describing: window.appliedStatuses.last?.detail))"
    )
    expect(
        window.appliedStatuses.last?.headline == "Stopped at Studio.",
        "and a headline naming the machine that stopped it, got "
            + "\(String(describing: window.appliedStatuses.last?.headline))"
    )

    harness.launch.onCloseRequested?()
    expect(await harness.settle(until: { harness.eventLoop.stopCount == 1 }), "and quitting ends the loop")
    expect(window.closeCount > 0, "and the session's window is closed behind it")
    print("PASS: a session that goes live shows its window, hides the list, and says who ended it")
}

/// docs/ux-spec.md line 65: closing the launch window is the same choice as
/// quitting, and it happens once.
@MainActor
private func testViewerApplicationQuitLatchStopsTheEventLoop() async {
    let harness = ViewerApplicationHarness()
    defer { harness.cleanUp() }

    await harness.viewer.run(arguments: [])
    expect(await harness.settle(until: { harness.launch.showCount > 0 }), "the launch window is shown")

    harness.launch.onCloseRequested?()
    harness.launch.onCloseRequested?()
    expect(
        await harness.settle(until: { harness.eventLoop.stopCount == 1 }),
        "closing the launch window hands the thread back"
    )
    expect(harness.eventLoop.stopCount == 1, "and a second close asks for nothing more")
    expect(harness.transports.dialCount == 0, "and nothing was ever dialled")
    print("PASS: closing the launch window fires the quit latch once and stops the event loop once")
}

/// docs/ux-spec.md: however the app was opened, nothing is sent until the
/// person clicks a row.
@MainActor
private func testViewerApplicationEnterURLSelectsWithoutDialling() async {
    let harness = ViewerApplicationHarness()
    defer { harness.cleanUp() }
    let machine = savedTestMachine(hostPublicKey: Data([7]))
    harness.store.save(machine)

    await harness.viewer.run(arguments: ["enter", "sensorium://enter/studio.tail1234.ts.net"])
    expect(
        await harness.settle(until: { !harness.launch.selectedHostPublicKeys.isEmpty }),
        "the machine the URL names is selected"
    )
    expect(
        harness.launch.selectedHostPublicKeys == [machine.hostPublicKey],
        "and it is the one that was paired"
    )
    expect(harness.launch.connectRequestedKeys.isEmpty, "and no row was asked to connect")
    expect(harness.transports.dialCount == 0, "and nothing was dialled")

    harness.launch.onCloseRequested?()
    expect(await harness.settle(until: { harness.eventLoop.stopCount == 1 }), "and quitting ends the loop")
    print("PASS: an enter URL selects the machine it names and dials nothing")
}

/// A desktop entry runs `Sensorium %u`, so the URL arrives with no verb in
/// front of it and has to mean what `enter <url>` means.
@MainActor
private func testViewerApplicationBareEnterURLIsTheEnterVerb() async {
    let harness = ViewerApplicationHarness()
    defer { harness.cleanUp() }
    let machine = savedTestMachine(hostPublicKey: Data([7]))
    harness.store.save(machine)

    await harness.viewer.run(arguments: ["sensorium://enter/studio.tail1234.ts.net"])
    expect(
        await harness.settle(until: { !harness.launch.selectedHostPublicKeys.isEmpty }),
        "the machine the bare URL names is selected"
    )
    expect(
        harness.launch.selectedHostPublicKeys == [machine.hostPublicKey],
        "and it is the one that was paired"
    )
    expect(harness.launch.connectRequestedKeys.isEmpty, "and no row was asked to connect")
    expect(harness.transports.dialCount == 0, "and nothing was dialled")

    harness.launch.onCloseRequested?()
    expect(await harness.settle(until: { harness.eventLoop.stopCount == 1 }), "and quitting ends the loop")
    print("PASS: a bare sensorium:// URL selects the machine it names, exactly as the enter verb does")
}

/// Counts every `start()` across all dials; the first `failingStarts` throw
/// the way an unreachable host does, and later ones run the given script.
final class StartLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var requested = false
    let failingStarts: Int
    init(failingStarts: Int) { self.failingStarts = failingStarts }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func noteHostScreenRequest() { lock.lock(); defer { lock.unlock() }; requested = true }
    var hostScreenRequested: Bool { lock.lock(); defer { lock.unlock() }; return requested }
}

actor UnreachableThenScriptedConnection: ClientControlConnection {
    let deferredPackets = DeferredPacketQueue()
    private let ledger: StartLedger
    private let dropsWhenScriptEnds: Bool
    private var pending: [SensoriumTransportPacket]
    private(set) var sentMessages: [SensoriumMessage] = []
    private var waiter: CheckedContinuation<SensoriumTransportPacket, Never>?

    init(ledger: StartLedger, responses: [SensoriumTransportPacket], dropsWhenScriptEnds: Bool = false) {
        self.ledger = ledger
        self.dropsWhenScriptEnds = dropsWhenScriptEnds
        pending = responses
    }

    func start(timeout: TimeInterval) async throws {
        if ledger.next() <= ledger.failingStarts {
            throw ClientSessionError.notConnected
        }
    }
    nonisolated func beginHostSilenceWatch() {}
    nonisolated func endHostSilenceWatch() {}
    nonisolated func enqueue(_ packet: SensoriumTransportPacket) {}
    func send(_ message: SensoriumMessage) async throws {
        sentMessages.append(message)
        if case .hostScreenRequest = message { ledger.noteHostScreenRequest() }
    }
    func send(_ packet: SensoriumTransportPacket) async throws {}
    func receiveWirePacket() async throws -> SensoriumTransportPacket {
        if !pending.isEmpty { return pending.removeFirst() }
        if dropsWhenScriptEnds { throw ClientSessionError.notConnected }
        return await withCheckedContinuation { waiter = $0 }
    }
    func close() async {}
}

private func hostScreenScript() -> [SensoriumTransportPacket] {
    let entry = HostScreenListEntry(
        opaqueToken: Data([0x0A]), label: "Built-in Display",
        logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0, isBuiltin: true,
        displayIdentity: "00000610-0000a038"
    )
    return [
        .control(.hostScreenList(displays: [entry], canvasAvailable: false)),
        .control(.hostScreenReady(
            geometry: SessionSurfaceGeometry(logicalWidth: 1512, logicalHeight: 982, backingScale: 2.0),
            resumeTicket: Data([0x66])
        ))
    ]
}

/// A click on a machine whose network is still coming back: the first dial
/// never reaches the host, so no one there was asked anything. The backoff's
/// next dial must still ask for the host screen.
@MainActor
private func testRedialAfterUnreachableFirstDialStillReachesHostScreen() async {
    let ledger = StartLedger(failingStarts: 1)
    let made = ConnectionsMade()
    let harness = ViewerApplicationHarness {
        let c = UnreachableThenScriptedConnection(ledger: ledger, responses: hostScreenScript())
        made.append(c)
        return c
    }
    defer { harness.cleanUp() }
    let machine = savedTestMachine(hostPublicKey: Data([7]))
    harness.store.save(machine)
    await harness.viewer.run(arguments: [])
    _ = await harness.settle(until: { harness.launch.showCount > 0 })
    harness.launch.onConnect?(machine)

    _ = await harness.settle(until: { ledger.hostScreenRequested || harness.launch.stoppedTryingCount > 0 })
    let requested = ledger.hostScreenRequested
    expect(
        ledger.value >= 2 && requested,
        "the redial after an unreachable first dial asks the host for its screen -- "
            + "starts=\(ledger.value), hostScreenRequest sent=\(requested), row=\(harness.launch.attemptFailures.map(\.reason))"
    )
    harness.launch.onCloseRequested?()
    _ = await harness.settle(until: { harness.eventLoop.stopCount == 1 })
    print("PASS: redial after unreachable first dial")
}

/// The row the stop leaves behind. Each click is the person asking; while
/// the host stays unreachable each click must keep dialling with backoff, not
/// stop after one failed start with the "needs someone" line.
@MainActor
private func testRowClickAfterUnreachableKeepsDiallingUntilHostAnswers() async {
    let ledger = StartLedger(failingStarts: Int.max)
    let harness = ViewerApplicationHarness {
        UnreachableThenScriptedConnection(ledger: ledger, responses: [])
    }
    defer { harness.cleanUp() }
    let machine = savedTestMachine(hostPublicKey: Data([8]))
    harness.store.save(machine)
    await harness.viewer.run(arguments: [])
    _ = await harness.settle(until: { harness.launch.showCount > 0 })

    for click in 1...2 {
        let before = ledger.value
        let stoppedBefore = harness.launch.stoppedTryingCount
        harness.launch.onConnect?(machine)
        _ = await harness.settle(until: { harness.launch.stoppedTryingCount > stoppedBefore })
        let stopped = harness.launch.stoppedTryingCount > stoppedBefore
        expect(
            !stopped && ledger.value - before >= 2,
            "row click \(click): a click on an unreachable machine keeps dialling -- "
                + "starts this click=\(ledger.value - before), run stopped=\(stopped), "
                + "row=\(harness.launch.attemptFailures.last?.reason ?? "-")"
        )
        if !stopped { harness.launch.onCancelConnecting?(); _ = await harness.settle(until: { harness.launch.showCount > click }) }
    }
    harness.launch.onCloseRequested?()
    _ = await harness.settle(until: { harness.eventLoop.stopCount == 1 })
    print("PASS: row click after unreachable")
}

final class ConnectionsMade: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [UnreachableThenScriptedConnection] = []
    func append(_ c: UnreachableThenScriptedConnection) { lock.lock(); items.append(c); lock.unlock() }
    var all: [UnreachableThenScriptedConnection] { lock.lock(); defer { lock.unlock() }; return items }
}

private func hostScreenRequests(of connections: [UnreachableThenScriptedConnection]) async -> [Data?] {
    var found: [Data?] = []
    for c in connections {
        for case let .hostScreenRequest(_, ticket) in await c.sentMessages { found.append(ticket) }
    }
    return found
}

/// A host set to ask first prompts its user on every unticketed request, so
/// once a request has been sent, an automatic redial that holds no ticket
/// must stop instead of sending another.
@MainActor
private func testRedialAfterRequestWasSentWithoutTicketStops() async {
    let ledger = StartLedger(failingStarts: 0)
    let made = ConnectionsMade()
    let harness = ViewerApplicationHarness {
        // The drop comes after the request and before any ticket is minted.
        let c = UnreachableThenScriptedConnection(
            ledger: ledger, responses: Array(hostScreenScript().prefix(1)), dropsWhenScriptEnds: true
        )
        made.append(c)
        return c
    }
    defer { harness.cleanUp() }
    let machine = savedTestMachine(hostPublicKey: Data([9]))
    harness.store.save(machine)
    await harness.viewer.run(arguments: [])
    _ = await harness.settle(until: { harness.launch.showCount > 0 })
    harness.launch.onConnect?(machine)

    _ = await harness.settle(until: { harness.launch.stoppedTryingCount > 0 })
    let requests = await hostScreenRequests(of: made.all)
    expect(
        harness.launch.stoppedTryingCount > 0 && requests.count == 1,
        "a drop after the request, with no ticket, ends the run without asking again -- "
            + "requests=\(requests.count), stopped=\(harness.launch.stoppedTryingCount)"
    )
    harness.launch.onCloseRequested?()
    _ = await harness.settle(until: { harness.eventLoop.stopCount == 1 })
    print("PASS: an automatic redial after an unticketed request was sent stops")
}

/// A live host-screen session that drops redials the same screen presenting
/// the ticket it was given, so the host resumes it without asking.
@MainActor
private func testRedialAfterLiveSessionDropPresentsHeldTicket() async {
    let ledger = StartLedger(failingStarts: 0)
    let made = ConnectionsMade()
    let harness = ViewerApplicationHarness {
        let first = made.all.isEmpty
        let c = UnreachableThenScriptedConnection(
            ledger: ledger, responses: hostScreenScript(), dropsWhenScriptEnds: first
        )
        made.append(c)
        return c
    }
    defer { harness.cleanUp() }
    let machine = savedTestMachine(hostPublicKey: Data([10]))
    harness.store.save(machine)
    await harness.viewer.run(arguments: [])
    _ = await harness.settle(until: { harness.launch.showCount > 0 })
    harness.launch.onConnect?(machine)

    var requests: [Data?] = []
    for _ in 0..<600 {
        requests = await hostScreenRequests(of: made.all)
        if requests.count >= 2 || harness.launch.stoppedTryingCount > 0 { break }
        try? await Task.sleep(for: .milliseconds(5))
    }
    expect(
        requests.count == 2 && requests[0] == nil && requests[1] == Data([0x66]),
        "the redial after a live session drops presents the held ticket -- "
            + "requests=\(requests.map { $0.map { "\($0.count) bytes" } ?? "none" }), "
            + "stopped=\(harness.launch.stoppedTryingCount)"
    )
    harness.launch.onCloseRequested?()
    _ = await harness.settle(until: { harness.eventLoop.stopCount == 1 })
    print("PASS: a live session dropped mid-stream redials presenting its held ticket")
}

import Foundation
import SensoriumCore

/// Owns the window across reconnects so a dropped session reuses the surface the
/// user is already looking at instead of throwing a new one at them.
///
/// Only glue: every decision it makes — when to redial, what counts as a
/// synchronised clock, whether input may reach the canvas — belongs to a type
/// the runners verify without a socket or a window.
@MainActor
final class ClientSessionHost {
    private let saved: SavedHost
    /// Where `saved` itself lives, so a stream-scale choice made from the
    /// Display menu can be written back and survive relaunch. The same store
    /// `saved` was loaded from -- never a second one.
    private let savedHostStore: any SavedHostStoring
    /// The resolution last picked for one host screen, remembered so it need
    /// not be picked again: the per-machine, per-screen record
    /// `onHostScreenModeList` reads from and
    /// `onHostScreenModeApplied` writes to, in `runOnce()`. A separate store
    /// from `savedHostStore` on purpose -- `saved.streamScalePreference` is a
    /// property of the machine as a whole, and this is a property of one of
    /// its host screens, keyed by a display identity `SavedHost` does not
    /// carry at all.
    private let hostScreenModeMemoryStore: any HostScreenModeMemoryStoring
    private let port: UInt16
    private let tlsCertificateHash: Data
    private let identity: DeviceIdentity
    private let deviceName: String
    private let tracePath: String?
    private let transport: ClientTransportKind
    private let transports: any ViewerTransportFactory
    private let quit: QuitSignal
    private let shortcutMode: SystemShortcutMode
    /// Builds this session's windows, and nothing else does.
    private let windowFactory: any SessionWindowFactory
    /// Every canvas window is registered with it, so a View-menu toggle acts
    /// on whichever one has focus.
    private let windowsRegistry: any ViewerWindowRegistry
    private let environment: any ViewerPlatformEnvironment
    /// Fixed two-slot storage, matching the hard cap: `windows[0]` is the
    /// primary canvas, always present once connected once; `windows[1]`
    /// exists only when a session actually opened a second canvas. Never
    /// grown or indexed by anything the network sends.
    private var windows: [(any ViewerSessionWindow)?] = [nil, nil]
    private var trace: LatencyTraceWriter?
    private var lastRunner: ClientSessionRunner?
    /// One per viewer process, not one per window: whichever viewer window
    /// holds key focus is the one a reserved chord belongs to.
    private let shortcuts: SystemShortcutForwarder
    /// Set by the dialling loop below: stopping ends the current run of
    /// attempts without ending the app, and trying again starts a new one.
    var onStopTrying: (() -> Void)?
    var onTryAgain: (() -> Void)?
    /// Set by the startup call site: the "Pair again" button's own action,
    /// which returns to the launch window on this machine's own code step.
    var onPairAgain: (() -> Void)?
    /// Set by the same call site: "Your machines" closes this session's window
    /// and brings the launch window's list back.
    var onYourMachines: (() -> Void)?
    /// Set by the same call site: a picture has arrived, so this session's
    /// window is on screen and the launch window has nothing left to say.
    var onCanvasLive: (() -> Void)?
    /// Set by the same call site: one attempt is starting, and no picture has
    /// arrived yet, so the launch window's row is what counts it.
    var onAttemptStartedBeforeLive: (() -> Void)?
    /// Set by the same call site: a dial that failed before any picture
    /// belongs on the launch window's own row for this machine, not in an
    /// overlay nobody can see yet. The failure arrives unclassified into
    /// words -- the row's own short fragment and the panel's long
    /// explanation read the same value differently, and only the call site
    /// that draws the row knows which one it needs.
    var onFailureBeforeLive: ((ViewerSessionFailure) -> Void)?
    /// Whether this session has ever shown a picture. Before it has, the
    /// canvas window does not exist as far as the person is concerned and
    /// every report goes to the launch window instead.
    private(set) var hasBeenLive = false
    /// What the windows are currently telling the user. Every word and colour
    /// in them is decided here, in a type the runners verify without a window
    /// or a socket.
    private var sessionState: ViewerSessionStateMachine
    /// docs/ux-spec.md's "Displays" menu: the person's own live choice, sent
    /// at connect and whenever it changes. Not persisted across a full
    /// relaunch the way the resolution choice is (`SavedHost.streamScalePreference`);
    /// kept here so a mid-run reconnect asks for it again instead of a
    /// session that grew to two displays silently shrinking back to one
    /// just because the link dropped.
    private var desiredDisplayCount = 1
    /// docs/ux-spec.md's "Clipboard" control: the person's own live choice,
    /// sent at connect and whenever it changes -- the same "kept here so a
    /// mid-run reconnect asks for it again" reasoning `desiredDisplayCount`
    /// above already carries. Starts at
    /// `ClipboardSyncEngine.sharingEnabledByDefault`.
    private var desiredClipboardSharingEnabled = ClipboardSyncEngine.sharingEnabledByDefault
    /// Which target the live session streams, or the next connect will: the
    /// target is always named explicitly, and a reconnect after a drop
    /// restores whichever one was last chosen -- a mid-run reconnect reads
    /// this, never a hardcoded `.sessionCanvas`.
    /// Set in `init` from `StartTargetResolution.resolve(preference:lastTarget:)`
    /// rather than always `.sessionCanvas`, so the very first connect of a
    /// launch tries this machine's own saved "Start with" preference.
    private var currentTarget: SessionTarget
    /// This machine's own saved "Start with" preference, as `currentTarget`
    /// last read it -- kept only so a "Start with" pick can update the
    /// Screen menu's own row immediately, without waiting for a relaunch.
    private var currentStartTargetPreference: StartTarget
    /// `currentTarget`'s own label when it names a `.hostScreen` -- carried
    /// alongside it rather than looked up again, since a target resolved
    /// from a saved preference at launch, or refused before any
    /// `hostScreenList` offer has arrived, has no live offer to look it up
    /// in. `nil` whenever `currentTarget` is `.sessionCanvas`.
    private var currentTargetLabel: String?
    /// Whether `currentTarget` is still the default `.hostScreenWhenOffered`
    /// preference's own to adjust -- resolved from a remembered offer or a
    /// session canvas at `init`, and updated at the two moments it changes on
    /// its own: `hostScreenOffered(displays:)`'s own auto-switch, and a
    /// refused host screen's own fallback, both below. Set to `false` the
    /// moment a person's own action names a target instead -- `selectRealScreen(token:)`
    /// and `perform(_:)`'s `.connectAsVirtualDisplay` -- so neither of those
    /// two automatic moments ever second-guesses a person's own pick.
    private var currentTargetIsDefaultChosen: Bool
    /// Set once inside `runOnce()`'s own catch for a refused host-screen
    /// connect that fell back to a session canvas on its own -- see
    /// `StartTargetHostScreenRefusalFallback`. Read and cleared by
    /// `consumeFallbackToVirtualDisplay()`, the run loop's own signal to
    /// dial again immediately rather than reporting a dead end.
    private var fellBackToVirtualDisplayAfterRefusal = false
    /// The canvas connection's own unprompted `hostScreenList` offer -- design
    /// §2.3 -- kept so the Screen menu's row-to-target lookup still works
    /// once the live connection has switched to `.hostScreen`, which never
    /// receives an offer of its own.
    private var lastHostScreenOffer: [HostScreenListEntry] = []
    /// The host screen's own display modes, and the one it is on, as the
    /// live session last reported them -- what the Screen menu's Resolution
    /// submenu offers. Emptied at every connect: a mode list belongs to the
    /// session that sent it, and a session streaming a virtual display has
    /// no host screen to offer modes for at all.
    private var hostScreenModes: [HostScreenModeEntry] = []
    private var hostScreenModeID: String?
    /// Ends the live session cleanly for a deliberate reconnect -- the
    /// Screen menu's own action -- distinct from `quit`: firing this ends
    /// only the current `runOnce()`, never the app. `nil` whenever nothing
    /// is connected yet; see `selectRealScreen(token:)`. Routes through the
    /// same one-shot `ended` signal `runOnce()` already fires a real
    /// transport drop through, so a session already ending on its own
    /// cannot be asked to end a second time.
    private var endCurrentSession: (() -> Void)?
    /// The last ticket a host-screen connect received, tagged with the
    /// display it was minted for -- kept so an automatic redial of the
    /// *same* target can present it and resume silently.
    /// `HostScreenResumeTicketRetention` is the pure rule for what this
    /// becomes on a target change or a connect; this field is only ever set
    /// through it.
    private var heldResumeTicket: HostScreenResumeTicket?
    /// True only for the one connect attempt following a person's own
    /// action -- launch with a saved machine, the Connect with a virtual
    /// display button, or a Host screen pick -- and consumed by the very
    /// next `runOnce()`. An automatic redial holding no ticket for its
    /// target stops instead of dialling; see `mustStopWithoutTicket`.
    private var hostScreenConnectIsPersonInitiated = true

    init(
        saved: SavedHost,
        savedHostStore: any SavedHostStoring,
        hostScreenModeMemoryStore: any HostScreenModeMemoryStoring,
        port: UInt16,
        tlsCertificateHash: Data,
        identity: DeviceIdentity,
        deviceName: String,
        tracePath: String?,
        transport: ClientTransportKind,
        transports: any ViewerTransportFactory,
        quit: QuitSignal,
        shortcutMode: SystemShortcutMode,
        windowFactory: any SessionWindowFactory,
        windowsRegistry: any ViewerWindowRegistry,
        environment: any ViewerPlatformEnvironment
    ) {
        self.saved = saved
        self.savedHostStore = savedHostStore
        self.hostScreenModeMemoryStore = hostScreenModeMemoryStore
        self.port = port
        self.tlsCertificateHash = tlsCertificateHash
        self.identity = identity
        self.deviceName = deviceName
        self.tracePath = tracePath
        self.transport = transport
        self.transports = transports
        self.quit = quit
        self.shortcutMode = shortcutMode
        self.windowFactory = windowFactory
        self.windowsRegistry = windowsRegistry
        self.environment = environment
        currentStartTargetPreference = saved.startTargetPreference
        let isDefaultPreference = saved.startTargetPreference == .hostScreenWhenOffered
        switch StartTargetResolution.resolve(
            preference: saved.startTargetPreference,
            lastTarget: saved.lastLiveTarget,
            rememberedOffer: saved.rememberedHostScreenOffer
        ) {
        case .sessionCanvas:
            currentTarget = .sessionCanvas
            currentTargetLabel = nil
            currentTargetIsDefaultChosen = isDefaultPreference
        case let .hostScreen(displayIdentity):
            currentTarget = .hostScreen(displayIdentity: displayIdentity)
            // The label's own best source, in order: the preference (or the
            // last-live record) that pinned this exact screen, then this
            // machine's own most recently remembered offer, which is
            // fresher than either whenever the default preference is what
            // resolved here -- `lastHostScreenOffer` itself is empty until a
            // connect actually receives one, which this resolved target may
            // never do if it connects as `.hostScreen` directly and is
            // refused before any offer arrives.
            currentTargetLabel = {
                if case let .hostScreen(_, label) = saved.startTargetPreference {
                    return label
                }
                if let remembered = saved.rememberedHostScreenOffer.first(where: { $0.displayIdentity == displayIdentity }) {
                    return remembered.label
                }
                if case let .hostScreen(_, label) = saved.lastLiveTarget {
                    return label
                }
                return displayIdentity
            }()
            currentTargetIsDefaultChosen = isDefaultPreference
        }
        sessionState = ViewerSessionStateMachine(hostName: saved.displayName)
        shortcuts = environment.makeShortcutForwarder(mode: shortcutMode)
    }

    /// Builds the primary window and wires its callbacks the first time it is
    /// needed. It is not put on screen here: `markCanvasLive()` is what shows
    /// it, once there is a picture in it. Every later call reuses the same
    /// window, swapping in `controller` through `attach(session:)` exactly as
    /// an in-place reconnect already does.
    private func ensurePrimaryWindow(
        attachingTo controller: ClientSessionController
    ) async throws -> any ViewerSessionWindow {
        let window: any ViewerSessionWindow
        if let existing = windows[0] {
            window = existing
            await existing.attach(session: controller)
        } else {
            window = try windowFactory.makeSessionWindow(
                title: saved.displayName,
                session: controller,
                surfaceID: 0,
                hostName: saved.displayName,
                shortcutMode: shortcutMode,
                initialStreamScalePreference: saved.streamScalePreference,
                savedHostStore: savedHostStore,
                savedHostPublicKey: saved.hostPublicKey
            )
            windows[0] = window
            shortcuts.register(window)
            windowsRegistry.register(window)
            // Closing the window is leaving the session, not orphaning a
            // headless process that still holds the host's canvas. Only
            // `quit` is captured, so the window never retains this host.
            window.onCloseRequested = { [quit] in quit.fire() }
            window.onSessionAction = { [weak self] action in
                self?.perform(action)
            }
            window.onSelectDisplayCount = { [weak self] count in
                self?.selectDisplayCount(count)
            }
            window.onSelectRealScreen = { [weak self] token in
                self?.selectRealScreen(token: token)
            }
            window.onSelectHostScreenMode = { [weak self] modeID in
                self?.selectHostScreenMode(modeID)
            }
            window.onSelectClipboardSharing = { [weak self] enabled in
                self?.selectClipboardSharing(enabled)
            }
            window.onSelectStartTarget = { [weak self] target in
                self?.selectStartTargetPreference(target)
            }
        }
        window.updateDisplayCount(desiredDisplayCount)
        window.updateClipboardSharingEnabled(desiredClipboardSharingEnabled)
        window.updateScreenMenu(displays: lastHostScreenOffer, selectedToken: selectedScreenMenuToken())
        window.updateHostScreenModes(hostScreenModes, currentModeID: hostScreenModeID)
        window.updateStartTargetPreference(currentStartTargetPreference)
        return window
    }

    /// Returns when this session ends. Throws only when the attempt never became
    /// a session, which is what the reconnect driver retries on.
    func runOnce() async throws {
        // Read before anything below can suspend: `transport.start()` can
        // throw and be retried by the caller's backoff, and a flag read
        // after that point would survive into an automatic redial.
        let connectPlan = HostScreenConnectPlan.compute(
            target: currentTarget, heldTicket: heldResumeTicket, isPersonInitiated: hostScreenConnectIsPersonInitiated
        )
        hostScreenConnectIsPersonInitiated = false
        guard !quit.hasFired else { return }
        let transport = transports.makeConnection(
            host: saved.host,
            port: port,
            tlsCertificateHash: tlsCertificateHash,
            transport: self.transport
        )
        // A session always starts at one display; docs/ux-spec.md's
        // "Displays" menu is the only way a second one opens, live, below.
        let controller = ClientSessionController(
            transport: transport,
            identity: identity,
            pinnedHostPublicKey: saved.hostPublicKey
        )
        let primaryWindow = try await ensurePrimaryWindow(attachingTo: controller)
        // Built, not shown. A dial with nothing to look at yet is reported on
        // the launch window's own row for this machine; this window appears at
        // the first picture and not before, so a host that is down never puts
        // an empty canvas on screen.
        applyStatus(sessionState.handle(.connectStarted))
        if !hasBeenLive {
            onAttemptStartedBeforeLive?()
        }

        if connectPlan.mustStopWithoutTicket {
            // An automatic redial (an inner backoff attempt, or a
            // reconnect-after-drop) holding no ticket for this target. A
            // host asking first would put its prompt up on every such
            // attempt; stop instead and wait for the person here, the same
            // way a host's own refusal already ends the run without
            // retrying. Decided above, before `transport.start()`, so a
            // stale flag surviving a failed attempt can never reach this far.
            throw ClientSessionError.hostScreenRefused("host-screen-retry-needs-person")
        }
        try await transport.start(timeout: SessionTimeouts.remoteDefault.handshake)
        await controller.setCanvasObserver(primaryWindow.canvasObserver())
        let connectOutcome: ConnectOutcome
        do {
            // Presented only when it is held for this exact
            // target, so a redial of an unchanged `.hostScreen` target
            // resumes silently and everything else -- the virtual display,
            // a different display, a user-initiated pick that already
            // cleared it -- signs.
            connectOutcome = try await controller.connect(
                deviceName: deviceName,
                target: currentTarget,
                resumeTicket: connectPlan.ticketToPresent
            )
        } catch let error as ClientSessionError {
            if connectPlan.ticketToPresent != nil, case .hostScreenRefused = error {
                // A ticket the host refused is known bad and is
                // never presented again. `ClientReconnectDriver` stops the
                // whole run on this same error, so nothing here retries it.
                heldResumeTicket = nil
            }
            if case .hostScreenRefused = error,
               StartTargetHostScreenRefusalFallback.shouldFallBackToVirtualDisplay(
                   isDefaultChosen: currentTargetIsDefaultChosen, hasBeenLive: hasBeenLive
               ) {
                // The default preference chose this screen, nobody picked
                // it, so its refusal is not the dead end the same refusal
                // would be for an explicit pin -- `runHostSession`'s own
                // loop reads this flag and dials again on a session canvas
                // once the ordinary refusal reporting below has run.
                heldResumeTicket = HostScreenResumeTicketRetention.afterTargetChanged(
                    from: currentTarget, to: .sessionCanvas, held: heldResumeTicket
                )
                currentTarget = .sessionCanvas
                currentTargetLabel = nil
                currentTargetIsDefaultChosen = false
                fellBackToVirtualDisplayAfterRefusal = true
            }
            throw error
        }
        let displayID: UInt32?
        let isHostScreenSession: Bool
        // The one identifier `HostScreenModeMemory` is keyed on for this
        // session -- read once here, alongside the resume ticket, rather
        // than re-read from `currentTarget` later: it names the screen this
        // exact connect is streaming, for the whole of this session's life.
        var sessionDisplayIdentity: String?
        switch connectOutcome {
        case let .canvas(id, hostScreenOffer):
            displayID = id
            isHostScreenSession = false
            // Pushed unprompted with this same connect, not a
            // later message the runner's mid-session hook would catch --
            // that hook only sees what arrives after `connect()` already
            // returned.
            hostScreenOffered(displays: hostScreenOffer)
            if let autoSwitch = StartTargetAutoSwitch.target(
                isDefaultChosen: currentTargetIsDefaultChosen, currentTarget: currentTarget, offer: hostScreenOffer
            ) {
                // Nothing has been shown yet -- `markCanvasLive()` only
                // fires at the first decoded frame, and none has arrived --
                // so abandoning this canvas connect for the screen the
                // default preference just offered costs no picture a person
                // ever saw.
                heldResumeTicket = HostScreenResumeTicketRetention.afterTargetChanged(
                    from: currentTarget,
                    to: .hostScreen(displayIdentity: autoSwitch.displayIdentity),
                    held: heldResumeTicket
                )
                currentTarget = .hostScreen(displayIdentity: autoSwitch.displayIdentity)
                currentTargetLabel = autoSwitch.label
                hostScreenConnectIsPersonInitiated = true
                print("Sensorium: starting on host screen \(autoSwitch.label)")
                await controller.disconnect(reason: "start-target-auto-switch")
                return try await runOnce()
            }
        case let .hostScreen(_, resumeTicket):
            displayID = nil
            isHostScreenSession = true
            // `ClientSessionController` itself has already reconfigured the
            // mapper with this reply's own geometry, awaited to completion
            // before `canvasDidBecomeReady()` opened the gate any pointer
            // event needs -- see `CanvasLifecycleObserving.updateMapper`'s
            // own doc comment for why that ordering, not this call site,
            // is what closes the race a reentrant actor left open.
            if case let .hostScreen(displayIdentity) = currentTarget {
                // Every successful host-screen connect -- a
                // fresh sign or a resumed ticket alike -- carries a ticket
                // good for the next automatic redial; storing it is what
                // makes that redial silent.
                heldResumeTicket = HostScreenResumeTicket(displayIdentity: displayIdentity, ticket: resumeTicket)
                sessionDisplayIdentity = displayIdentity
            }
        }
        primaryWindow.updateIsHostScreenSession(isHostScreenSession)
        // A fresh session's own modes, or none: the host sends its list
        // unprompted once a host screen is live, and a session canvas has
        // no host screen whose resolution this menu could change.
        hostScreenModesReported([], currentModeID: nil)
        if isHostScreenSession, let secondWindow = windows[1] {
            // A host-screen session never opens a second display -- the
            // host's own mixed-session gate refuses one before it is ever
            // asked for -- so a window leftover from a canvas session that
            // had grown to two, picked back up here, has nothing left to
            // show.
            desiredDisplayCount = 1
            windows[1] = nil
            secondWindow.close()
        }

        // Known only once `connect()` returns: `canvasReady` is what carries
        // the host's own name, so the window opens under the address-derived
        // title and is retitled the moment the handshake says who it is.
        // `hostScreenReady` carries no host name, so a `.hostScreen` session
        // falls back the same way a host that predates the field already does.
        let resolvedTitle = ViewerWindowTitle.resolve(
            hostMachineName: await controller.hostMachineName,
            savedHost: saved.host,
            fallback: saved.displayName
        )
        primaryWindow.updateTitle(resolvedTitle)

        shortcuts.startInterceptingIfPermitted { print($0) }

        // Built here, after `connect()` returned a signed canvas or a granted
        // host screen, and torn down with the runner: on this side the
        // session gate is structural rather than a flag the session has to
        // re-check.
        // `desiredClipboardSharingEnabled`, not a hardcoded default: a
        // reconnect must rebuild the engine in the state the person last
        // chose, which the message sent before `start()` below repeats to
        // the host.
        let clipboard = ClipboardSyncSession(
            engine: ClipboardSyncEngine(
                pasteboard: environment.makePasteboard(), isEnabled: desiredClipboardSharingEnabled
            ),
            log: { print("Sensorium: \($0)") },
            onRefusal: { refusal in
                if let line = ClipboardRefusalCopy.line(for: refusal) {
                    primaryWindow.showClipboardRefusal(line)
                }
            }
        )
        // Fresh per attempt, matching `hostScreenModes`' own per-session
        // reset just above: "never request twice per session automatically"
        // means at most once per connect, not once ever.
        let modeAutoRestore = HostScreenModeAutoRestore()
        let runner = ClientSessionRunner(
            connection: transport,
            session: controller,
            window: primaryWindow,
            clipboard: clipboard,
            hostName: saved.displayName,
            hostAddress: "\(saved.host):\(saved.port)"
        )
        lastRunner = runner
        if let writer = try resolveTrace() {
            await runner.latency.attachTrace(writer)
        }
        // The Displays menu's own live replies -- see `selectDisplayCount(_:)`
        // for the request side. Wired before `start()` so a reply that
        // arrives on the very first receive-loop tick (the reconnect case
        // just below, when `desiredDisplayCount` is already 2) is never
        // missed.
        runner.onSecondDisplayReady = { [weak self] displayID, logicalWidth, logicalHeight in
            Task { @MainActor in
                await self?.attachSecondDisplay(
                    displayID: displayID,
                    logicalWidth: logicalWidth,
                    logicalHeight: logicalHeight,
                    session: controller,
                    primaryWindow: primaryWindow,
                    primaryTitle: resolvedTitle,
                    runner: runner
                )
            }
        }
        runner.onSecondDisplayRefused = { [weak self] reason in
            Task { @MainActor in
                self?.reconcileToSingleDisplay(runner: runner)
                guard let self else { return }
                primaryWindow.showDisplayCountRefusal(
                    reason: DisplayCountRefusalCopy.line(reason: reason, hostLabel: self.saved.displayName)
                )
            }
        }
        // Sent unprompted, once authenticated, only on a canvas
        // connection. The Screen menu's own state is pushed here the same
        // reason `onSecondDisplayReady` is pushed above -- the window cannot
        // reach across to this live runner synchronously at `menuNeedsUpdate`.
        runner.onHostScreenOffered = { [weak self] displays in
            Task { @MainActor in
                self?.hostScreenOffered(displays: displays)
            }
        }
        // The host screen's own resolution, reported the same way and for
        // the same reason: the menu cannot reach across to a live runner
        // synchronously at `menuNeedsUpdate` time.
        runner.onHostScreenModeList = { [weak self] modes, currentModeID in
            Task { @MainActor in
                guard let self else { return }
                self.hostScreenModesReported(modes, currentModeID: currentModeID)
                // The resolution picked last time for this host screen is
                // asked for once per session: once this session's own modes
                // and current mode are both known, ask at most once --
                // `modeAutoRestore` refuses every call after its first --
                // for whatever this machine's this screen was last set to,
                // if that shape is still offered and
                // is not already what the screen is on.
                guard isHostScreenSession, let sessionDisplayIdentity else { return }
                let remembered = self.hostScreenModeMemoryStore.remembered(
                    hostPublicKey: self.saved.hostPublicKey, displayIdentity: sessionDisplayIdentity
                )
                guard let outcome = modeAutoRestore.attempt(
                    remembered: remembered, modes: modes, currentModeID: currentModeID
                ) else { return }
                if let line = HostScreenModeRestoreDecision.logLine(for: outcome) {
                    print("Sensorium: \(line)")
                }
                if case let .restore(modeID, _) = outcome {
                    Task { await runner.requestHostScreenMode(modeID) }
                }
            }
        }
        runner.onHostScreenModeApplied = { [weak self] geometry, currentModeID in
            Task { @MainActor in
                guard let self else { return }
                self.hostScreenModesReported(self.hostScreenModes, currentModeID: currentModeID)
                // Exactly what a `hostScreenReady` geometry already does:
                // the screen this session streams is a different size now,
                // and the mapper every pointer event goes through is what
                // has to know it.
                await primaryWindow.canvasObserver().updateMapper(geometry: geometry)
                // Only an applied change is ever remembered -- a refusal
                // (`onHostScreenModeRefused`, below) and a plain snapshot
                // (`onHostScreenModeList`, above) never call this at all.
                if let sessionDisplayIdentity,
                   let mode = HostScreenModeMemoryUpdate.remembering(
                       currentModeID: currentModeID, in: self.hostScreenModes
                   ) {
                    self.hostScreenModeMemoryStore.remember(
                        hostPublicKey: self.saved.hostPublicKey, displayIdentity: sessionDisplayIdentity, mode: mode
                    )
                }
            }
        }
        runner.onHostScreenModeRefused = { [weak self] reason in
            Task { @MainActor in
                guard let self else { return }
                primaryWindow.showHostScreenModeRefusal(
                    HostScreenRefusalCopy.modeRefusalLine(reason: reason, hostLabel: self.saved.displayName)
                )
            }
        }
        runner.onClipboardRefused = { refusal in
            Task { @MainActor in
                if let line = ClipboardRefusalCopy.line(for: refusal) {
                    primaryWindow.showClipboardRefusal(line)
                }
            }
        }
        let ended = QuitSignal()
        // An ending a person at the host chose, told apart from the dropped
        // transport it otherwise looks exactly like -- see the throw below.
        let stoppedByHost = QuitSignal()
        runner.onStoppedByHost = { stoppedByHost.fire() }
        // An ending the host gave a cause for, told apart from the dropped
        // transport the same way Stop is, and for the same reason.
        let hostEnding = HostEndingBox()
        runner.onHostEnded = { hostEnding.record($0) }
        let firstFrame = QuitSignal()
        firstFrame.onFire {
            Task { @MainActor in
                await self.markCanvasLive()
            }
        }
        // Sent on every connect, whatever the choice, and before `start()`
        // begins polling: the host starts each connection off
        // (`ClipboardSyncEngine.hostSharingEnabledAtConnect`) and follows
        // this message, so a copy polled before it arrived would be dropped.
        await runner.setClipboardSharing(enabled: desiredClipboardSharingEnabled)
        try runner.start(
            onEnded: { _ in
                Task { @MainActor in
                    print("Session ended.")
                    // A session the user quit is not a failure, and must not
                    // be announced as one.
                    if !self.quit.hasFired {
                        // An ending a person at the host chose is not the
                        // dropped link `sessionEnded` describes, and the
                        // window must not say it was. Decided here rather
                        // than in a second status call, so only one event
                        // ever reaches the state machine for one ending.
                        if stoppedByHost.hasFired {
                            self.applyStatus(self.sessionState.handle(.stoppedByHost(
                                reasonLine: ViewerSessionFailureCopy.line(
                                    for: .stoppedByHost, hostLabel: self.saved.displayName
                                )
                            )))
                        } else if let failure = hostEnding.failure {
                            self.applyStatus(self.sessionState.handle(.hostEnded(
                                reasonLine: ViewerSessionFailureCopy.line(
                                    for: failure, hostLabel: self.saved.displayName
                                )
                            )))
                        } else {
                            self.applyStatus(self.sessionState.handle(.sessionEnded))
                        }
                    }
                    ended.fire()
                }
            },
            // The live state starts at the first real picture, not at the
            // handshake: until a frame lands there is nothing to look at, and
            // saying "connected" over a black window would be a lie. Latched,
            // so this costs one lock and nothing else on every later frame.
            onDecodedFrame: { _ in firstFrame.fire() }
        )
        // A reconnect after a session that had grown to two displays asks
        // again rather than silently staying at one -- `desiredDisplayCount`
        // is this run's own memory of the person's last live choice, not
        // read back from anywhere the host sends.
        // A host-screen connection never sends a second canvasRequest -- the
        // Displays menu is disabled for exactly this reason above.
        if desiredDisplayCount == 2, !isHostScreenSession {
            await runner.setDisplayCount(2)
        }
        let sessionSummary = displayID.map { "session canvas \($0)" } ?? "the host screen"
        print("Entered \(saved.displayName); \(sessionSummary)")

        // A tap that outlives this session is a machine-wide keylogger with
        // no session to justify it. Stopping it here, before the transport is
        // torn down, means a reconnect gap has no tap: ordinary typing during
        // that gap reaches the local machine, not a dead transport.
        let sessionShortcuts = shortcuts
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let finish: @Sendable (String) -> Void = { reason in
                Task { @MainActor in
                    print("Leaving…")
                    sessionShortcuts.stop()
                    runner.stop()
                    await controller.disconnect(reason: reason)
                    // Quitting must release the canvas on the host. Without
                    // this the host keeps it until the socket eventually
                    // drops. Read fresh, not a snapshot taken before this
                    // session ran: a live "Displays" change may have opened
                    // or closed this window since.
                    await self.windows[1]?.canvasObserver().canvasDidEnd()
                    self.endCurrentSession = nil
                    continuation.resume()
                }
            }
            ended.onFire { finish("transport-lost") }
            quit.onFire { ended.fire() }
            // The Screen menu's own action -- see `selectRealScreen(token:)`.
            // Routed through `ended`, not a second `finish` call, so a
            // session already ending on its own cannot be ended twice.
            endCurrentSession = { ended.fire() }
        }
        if stoppedByHost.hasFired {
            // A person at the host ended this session, so nothing here redials
            // it: `ClientReconnectDriver` stops the whole run on this error,
            // and the ticket that would have made a redial silent goes with
            // the session it belonged to.
            heldResumeTicket = HostScreenResumeTicketRetention.afterHostStoppedSession(held: heldResumeTicket)
            throw ClientSessionError.stoppedByHost
        }
        if hostEnding.failure == .hostDisplaysAsleep {
            // The host's screens are asleep and would not wake, so there is
            // nothing on that machine to send. Read the same way Stop above
            // is: the driver stops the whole run, and a person wakes the
            // screen before there is any point trying again.
            throw ClientSessionError.hostDisplaysAsleep
        }
    }

    /// Ends a live session from outside it -- the launch window taking the
    /// screen back, whether from its own list or from a machine clicked while
    /// this one was still up. Does nothing when nothing is live.
    func endLiveSession() {
        endCurrentSession?()
    }

    /// The retry loop is finished and the host never answered. Said in the
    /// window, because stdout goes nowhere when the app was double-clicked.
    /// Before the first picture there is no window of this session's to say
    /// it in, and the launch window's own row already carries the last
    /// attempt's reason -- see `onFailureBeforeLive`.
    func reportUnreachable() {
        guard hasBeenLive else { return }
        applyStatus(sessionState.handle(.gaveUp))
    }

    /// A button in the status panel. None of these is a second implementation:
    /// quitting fires the one latch the menu bar's Quit and a signal both fire,
    /// and stopping and retrying are handed to the one dialling loop.
    func perform(_ action: ViewerSessionAction) {
        switch action {
        case .quit:
            quit.fire()
        case .stopTrying:
            applyStatus(sessionState.handle(.stopRequested))
            onStopTrying?()
        case .tryAgain:
            hostScreenConnectIsPersonInitiated = true
            applyStatus(sessionState.handle(.retryRequested))
            onTryAgain?()
        case .connectAsVirtualDisplay:
            // Never resumes the target that just ended: nothing here is
            // automatic. Always switches to a session canvas, the same
            // dialling loop `onTryAgain` already wakes for a plain retry.
            heldResumeTicket = HostScreenResumeTicketRetention.afterTargetChanged(
                from: currentTarget, to: .sessionCanvas, held: heldResumeTicket
            )
            currentTarget = .sessionCanvas
            currentTargetLabel = nil
            // A person's own explicit choice, never second-guessed by a
            // later offer the way the default preference's own canvas is.
            currentTargetIsDefaultChosen = false
            applyStatus(sessionState.handle(.retryRequested))
            onTryAgain?()
        case .pairAgain:
            // Sends no event: this session is over, and the launch window is
            // about to take the screen back with this machine's own code step
            // already open.
            onPairAgain?()
        case .yourMachines:
            // Back to the list this session started from, with this window
            // closed behind it.
            onYourMachines?()
        }
    }

    /// The retry loop's own report of a host-screen connect that never
    /// became a session -- refused or failed -- with its reason already in
    /// words. See `ClientReconnectDriver`'s no-auto-redial branch: this is
    /// what the person sees instead of an indefinite "Reconnecting…".
    func reportHostScreenConnectEnded(reasonLine: String, failure: ViewerSessionFailure) {
        guard hasBeenLive else {
            onFailureBeforeLive?(failure)
            return
        }
        applyStatus(sessionState.handle(.hostScreenConnectEnded(reasonLine: reasonLine)))
    }

    /// The retry loop's own report of a dial that failed because the host
    /// did not prove it is the machine this one paired with. See
    /// `ClientReconnectDriver`'s no-auto-redial branch for `.unverifiedHost`:
    /// this is what the person sees instead of an endlessly redialling
    /// "Connecting…" panel.
    func reportUnverifiedHost(reasonLine: String, failure: ViewerSessionFailure) {
        guard hasBeenLive else {
            onFailureBeforeLive?(failure)
            return
        }
        applyStatus(sessionState.handle(.unverifiedHostConnectEnded(reasonLine: reasonLine)))
    }

    /// The retry loop's own report of one failed dial, so the connecting or
    /// reconnecting panel says why the last attempt did not connect instead
    /// of repeating the same words for every attempt.
    func reportAttemptFailed(reasonLine: String, failure: ViewerSessionFailure) {
        guard hasBeenLive else {
            onFailureBeforeLive?(failure)
            return
        }
        applyStatus(sessionState.handle(.attemptFailed(reasonLine: reasonLine)))
    }

    /// The Displays menu's own action, from whichever window the tap came
    /// from -- the choice is session-wide, not per-window, so both
    /// windows' menus (and both windows' `updateDisplayCount`) agree once
    /// this returns. `count == desiredDisplayCount` -- picking the row
    /// already checked -- is a no-op the same way it is on the wire.
    func selectDisplayCount(_ count: Int) {
        guard count == 1 || count == 2, count != desiredDisplayCount else { return }
        guard let lastRunner else {
            // Nothing is connected yet; the next `runOnce()` reads
            // `desiredDisplayCount` itself once it is.
            desiredDisplayCount = count
            return
        }
        if count == 1 {
            // Optimistic: a decrease never fails and the host sends no
            // reply to confirm it, so the viewer's own choice is the only
            // signal there ever is -- docs/ux-spec.md's own reading of
            // "removing a display... is allowed."
            reconcileToSingleDisplay(runner: lastRunner)
        }
        Task { await lastRunner.setDisplayCount(count) }
    }

    /// The Clipboard menu's own action, from whichever window the tap came
    /// from -- session-wide, not per-window, the same reason
    /// `selectDisplayCount(_:)` is. Always optimistic, unlike a "Displays"
    /// increase: `clipboardSharing` has no refusal reply to wait for.
    func selectClipboardSharing(_ enabled: Bool) {
        guard enabled != desiredClipboardSharingEnabled else { return }
        desiredClipboardSharingEnabled = enabled
        for window in windows.compactMap({ $0 }) {
            window.updateClipboardSharingEnabled(enabled)
        }
        guard let lastRunner else {
            // Nothing is connected yet; the next `runOnce()` reads
            // `desiredClipboardSharingEnabled` itself once it is.
            return
        }
        Task { await lastRunner.setClipboardSharing(enabled: enabled) }
    }

    /// The Screen menu's own action: `nil` picks the virtual display,
    /// otherwise the token names one of the host's screens last
    /// offered. Unlike `selectDisplayCount`, this is never optimistic --
    /// docs/ux-spec.md: a session streams the one target it was set up for,
    /// so the only honest response is a fresh connect naming the new
    /// target. `endCurrentSession` ends
    /// the run through the same one-shot latch a real transport loss would,
    /// so a race between the two can never double-resume.
    func selectRealScreen(token: Data?) {
        let target: SessionTarget
        let label: String?
        if let token, let entry = lastHostScreenOffer.first(where: { $0.opaqueToken == token }) {
            target = .hostScreen(displayIdentity: entry.displayIdentity)
            label = entry.label
        } else {
            target = .sessionCanvas
            label = nil
        }
        guard target != currentTarget else { return }
        // A user-initiated pick is never the silent
        // automatic-redial case a held ticket exists for -- even a re-pick
        // of the very display it was minted for signs fresh, never resumes.
        heldResumeTicket = HostScreenResumeTicketRetention.afterTargetChanged(
            from: currentTarget, to: target, held: heldResumeTicket
        )
        currentTarget = target
        currentTargetLabel = label
        // A person's own explicit choice, never second-guessed by a later
        // offer the way the default preference's own canvas is.
        currentTargetIsDefaultChosen = false
        hostScreenConnectIsPersonInitiated = true
        guard lastRunner != nil else {
            // Nothing is connected yet; the next `runOnce()` reads
            // `currentTarget` itself once it is.
            return
        }
        endCurrentSession?()
    }

    /// The Screen menu's own "Start with" action: writes the pick back to
    /// this machine's saved record, read fresh rather than through `saved`
    /// itself -- the same reasoning `SavedHostStoring.stampConnected(_:at:liveTarget:)`
    /// already follows, so a resolution chosen mid-session is never
    /// overwritten by a stale copy. Never touches `currentTarget`: a "Start
    /// with" pick names what the *next* launch tries first, and a
    /// connection's own target is fixed for the whole of its life, which
    /// means
    /// nothing here reconnects the one that is live.
    func selectStartTargetPreference(_ target: StartTarget) {
        currentStartTargetPreference = target
        savedHostStore.setStartTargetPreference(hostPublicKey: saved.hostPublicKey, to: target)
        for window in windows.compactMap({ $0 }) {
            window.updateStartTargetPreference(target)
        }
    }

    /// What `currentTarget` names, in the shape `SavedHost.lastLiveTarget`
    /// stores -- read once a session actually goes live, never before: a
    /// target that has only been attempted is not what `.lastUsed` should
    /// fall back to next time.
    var liveStartTarget: StartTarget {
        switch currentTarget {
        case .sessionCanvas:
            return .virtualDisplay
        case let .hostScreen(displayIdentity):
            return .hostScreen(displayIdentity: displayIdentity, label: currentTargetLabel ?? displayIdentity)
        }
    }

    /// `currentTarget`'s own label, when this attempt is trying a host
    /// screen -- `nil` for a session canvas. Read by the dialling loop so a
    /// refusal it reports before this session has ever gone live can still
    /// name the display a saved "Start with" preference was trying, since
    /// nothing else at that point named it from a menu a person picked.
    var currentHostScreenLabel: String? {
        guard case .hostScreen = currentTarget else { return nil }
        return currentTargetLabel
    }

    /// The Screen menu's own reading of `currentTarget`, round-tripped
    /// through the same stale offer list `selectRealScreen(token:)` reads
    /// from -- a `.hostScreen` session never receives its own fresh offer,
    /// so this is the only place its token can still be found.
    private func selectedScreenMenuToken() -> Data? {
        guard case let .hostScreen(displayIdentity) = currentTarget else { return nil }
        return lastHostScreenOffer.first(where: { $0.displayIdentity == displayIdentity })?.opaqueToken
    }

    /// The runner's own push of the host's current offer, since the Screen
    /// menu cannot pull it from a live runner synchronously at
    /// `menuNeedsUpdate` time -- the same reason `onSecondDisplayReady` and
    /// `onSecondDisplayRefused` already push instead of being polled.
    /// The Screen menu's Resolution submenu's own action: the host is asked
    /// to set the screen it is streaming to one of the modes it offered.
    /// Never optimistic -- the host may refuse, and the answer arrives on
    /// the wire like every other -- and a no-op with nothing connected,
    /// since there is no host screen to change.
    func selectHostScreenMode(_ modeID: String) {
        guard let lastRunner else { return }
        Task { await lastRunner.requestHostScreenMode(modeID) }
    }

    /// The live session's own report of what its host screen can be set to
    /// and what it is on, pushed to every window the same way
    /// `hostScreenOffered(displays:)` below pushes the display offer.
    private func hostScreenModesReported(_ modes: [HostScreenModeEntry], currentModeID: String?) {
        hostScreenModes = modes
        hostScreenModeID = currentModeID
        for window in windows.compactMap({ $0 }) {
            window.updateHostScreenModes(modes, currentModeID: currentModeID)
        }
    }

    private func hostScreenOffered(displays: [HostScreenListEntry]) {
        lastHostScreenOffer = displays
        for window in windows.compactMap({ $0 }) {
            window.updateScreenMenu(displays: displays, selectedToken: selectedScreenMenuToken())
        }
        // Remembered regardless of which target this connection is
        // streaming: a canvas connect's own offer is what
        // `.hostScreenWhenOffered` will read back next time -- see
        // `StartTargetResolution.resolve(preference:lastTarget:rememberedOffer:)`.
        savedHostStore.rememberHostScreenOffer(
            hostPublicKey: saved.hostPublicKey,
            offer: displays.map { RememberedHostScreen(displayIdentity: $0.displayIdentity, label: $0.label) }
        )
    }

    /// `runHostSession`'s own signal that a refused host screen the default
    /// preference chose has already fallen back to a session canvas, and the
    /// next dial should start at once rather than reporting a dead end.
    /// Cleared the moment it is read, so it is acted on exactly once.
    func consumeFallbackToVirtualDisplay() -> Bool {
        let fellBack = fellBackToVirtualDisplayAfterRefusal
        fellBackToVirtualDisplayAfterRefusal = false
        return fellBack
    }

    /// The windows-and-menu reconciliation both a live "Displays" decrease
    /// and a refused increase need: closing `windows[1]` if one exists, and
    /// republishing 1 as the session's own count on every remaining window.
    /// `SecondDisplayRefusalReconciliation` is the pure decision -- reached
    /// from `onSecondDisplayRefused` too, since a refusal that arrives after
    /// a reconnect-time restore (`runOnce()`'s own re-ask when
    /// `desiredDisplayCount == 2`) can find a second window still open,
    /// leftover from before the drop, and it must not sit there dimmed
    /// forever.
    ///
    /// `detachSecondDisplay()` is called unconditionally, for its own side
    /// effect on `runner` (stopping decode, unregistering the router) --
    /// its return value is read only to tell the pure decision whether
    /// this particular runner held the window, never to decide whether
    /// `windows[1]` itself gets closed. A runner rebuilt fresh on reconnect
    /// starts with no secondary attached and this call returns `nil` even
    /// though `windows[1]` still remembers one from before the drop.
    private func reconcileToSingleDisplay(runner: ClientSessionRunner) {
        desiredDisplayCount = 1
        let detachedFromRunner = runner.detachSecondDisplay()
        let outcome = SecondDisplayRefusalReconciliation.outcome(
            hostWindowExists: windows[1] != nil,
            runnerHasSecondaryWindow: detachedFromRunner != nil
        )
        if outcome.shouldCloseSecondWindow, let window = windows[1] {
            windows[1] = nil
            window.close()
        }
        for window in windows.compactMap({ $0 }) {
            window.updateDisplayCount(outcome.publishedDisplayCount)
        }
    }

    /// The live reply to a "Displays" increase that succeeded --
    /// `desiredDisplayCount` only becomes 2 here, once the host has
    /// actually agreed, never optimistically the way a decrease is: an
    /// increase can be refused, and showing a window before knowing that
    /// would mean tearing one back down a moment later.
    private func attachSecondDisplay(
        displayID: UInt32,
        logicalWidth: Int,
        logicalHeight: Int,
        session: ClientSessionController,
        primaryWindow: any ViewerSessionWindow,
        primaryTitle: String,
        runner: ClientSessionRunner
    ) async {
        desiredDisplayCount = 2
        let window: any ViewerSessionWindow
        if let existing = windows[1] {
            window = existing
            await existing.attach(session: session)
        } else {
            guard let built = try? windowFactory.makeSessionWindow(
                title: ViewerWindowTitle.secondDisplayTitle(primaryTitle: saved.displayName),
                session: session,
                surfaceID: 1,
                hostName: saved.displayName,
                shortcutMode: shortcutMode,
                initialStreamScalePreference: saved.streamScalePreference,
                savedHostStore: savedHostStore,
                savedHostPublicKey: saved.hostPublicKey
            ) else {
                return
            }
            window = built
            windows[1] = window
            shortcuts.register(window)
            windowsRegistry.register(window)
            window.onCloseRequested = { [quit] in quit.fire() }
            window.onSessionAction = { [weak self] action in
                self?.perform(action)
            }
            window.onSelectDisplayCount = { [weak self] count in
                self?.selectDisplayCount(count)
            }
            window.onSelectClipboardSharing = { [weak self] enabled in
                self?.selectClipboardSharing(enabled)
            }
            // Both windows are built from the same content rect, so without
            // this the second one opens exactly on top of the first and
            // looks like nothing happened.
            window.cascadeIfUnplaced(from: primaryWindow)
            window.apply(status: sessionState.status)
        }
        window.updateTitle(ViewerWindowTitle.secondDisplayTitle(primaryTitle: primaryTitle))
        for window in windows.compactMap({ $0 }) {
            window.updateDisplayCount(2)
            window.updateClipboardSharingEnabled(desiredClipboardSharingEnabled)
        }
        try? await runner.attachSecondDisplay(window)
        // Nothing registered a lifecycle observer for this surface before
        // now -- the window did not exist, or was detached, until this
        // reply arrived -- so its viewport is armed directly here instead.
        await window.canvasObserver().canvasDidBecomeReady()
        await window.show()
    }

    /// The first picture: the canvas window goes on screen here and nowhere
    /// else, and the launch window's work is done.
    private func markCanvasLive() async {
        guard sessionState.status.phase != .live else { return }
        hasBeenLive = true
        applyStatus(sessionState.handle(.canvasReady))
        await windows[0]?.show()
        onCanvasLive?()
    }

    private func applyStatus(_ status: ViewerSessionStatus) {
        for window in windows.compactMap({ $0 }) {
            window.apply(status: status)
        }
    }

    func reportLatency() async {
        guard let lastRunner else { return }
        await lastRunner.latency.writeTrace()
        if let summary = await lastRunner.latencySummary() {
            print(summary)
        } else {
            print("No latency measured: the session clocks never synchronized.")
        }
    }

    /// Called once, when the viewer is leaving for good — never on an
    /// ordinary per-session disconnect, which reuses these same windows
    /// across a reconnect.
    func closeWindows() {
        shortcuts.stop()
        for window in windows.compactMap({ $0 }) {
            windowsRegistry.unregister(window)
            window.close()
        }
    }

    /// Created once and appended to across reconnects, and loud when the path is
    /// wrong: a silent trace failure looks exactly like a measured session.
    private func resolveTrace() throws -> LatencyTraceWriter? {
        guard let tracePath else { return nil }
        if let trace { return trace }
        let writer = try LatencyTraceWriter(
            url: URL(fileURLWithPath: tracePath),
            sessionLabel: saved.displayName
        )
        trace = writer
        print("Latency trace: \(tracePath)")
        return writer
    }
}


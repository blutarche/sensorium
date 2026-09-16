import AppKit
import SensoriumClient
import SensoriumCore
import Foundation
import Network

/// Two modes, both explicit:
///   pair    <host> <port> <code> — one-time ceremony; saves the host and pins its key
///   enter [sensorium://enter/<host>] — enter the saved paired host in one action
///
/// Neither mode is exercised by the verification runners: both open a socket,
/// and enter also reads and writes the saved-host file and the key that
/// identifies this machine.
private nonisolated(unsafe) var quitSources: [DispatchSourceSignal] = []

/// One-shot latch so the session ends exactly once, whichever comes first: the
/// user quitting or the host disappearing.
final class QuitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var handlers: [@Sendable () -> Void] = []

    var hasFired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fired
    }

    func onFire(_ handler: @escaping @Sendable () -> Void) {
        lock.lock()
        if fired {
            lock.unlock()
            handler()
            return
        }
        handlers.append(handler)
        lock.unlock()
    }

    func fire() {
        lock.lock()
        if fired {
            lock.unlock()
            return
        }
        fired = true
        let handlers = self.handlers
        self.handlers = []
        lock.unlock()
        for handler in handlers {
            handler()
        }
    }
}

/// The cause a host named on its way out, held until the ending is reported.
/// Written on the runner's own receive loop and read on the main actor, so it
/// carries its own lock, exactly as `QuitSignal` above does.
final class HostEndingBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ViewerSessionFailure?

    var failure: ViewerSessionFailure? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ failure: ViewerSessionFailure) {
        lock.lock()
        stored = failure
        lock.unlock()
    }
}

/// The viewer's dialling loop, in one place: a driver per run of attempts, and
/// a wake-up the user can fire from the status panel.
///
/// `ClientReconnectDriver` is deliberately one-shot — a driver the user stopped
/// stays stopped — so trying again builds a new one. Nothing here changes the
/// retry policy: what makes the wait finite is the user's own choice to stop it.
@MainActor
final class DiallingRun {
    private let makeDriver: () -> ClientReconnectDriver
    private var current: ClientReconnectDriver?
    /// The task one run of attempts is running in, so stopping can cancel the
    /// wait between them rather than serving it out. A live session is ended
    /// through `ClientSessionHost` first; cancelling alone would leave it
    /// parked on the picture it is still showing.
    private var runTask: Task<ClientReconnectOutcome, Never>?
    private(set) var isStopped = false
    private var waiter: CheckedContinuation<Void, Never>?
    /// A wake-up that arrives before anything is waiting must not be dropped,
    /// or a fast Try again would park the loop forever.
    private var pendingWake = false

    init(makeDriver: @escaping () -> ClientReconnectDriver) {
        self.makeDriver = makeDriver
    }

    func startRun() async -> ClientReconnectOutcome {
        isStopped = false
        let driver = makeDriver()
        current = driver
        return await runCancellably { await driver.runUntilConnectedSessionEnds() }
    }

    /// Redials within the run already in progress, so its backoff schedule
    /// continues instead of restarting.
    func continueRun() async -> ClientReconnectOutcome {
        guard let current else { return .stopped }
        return await runCancellably { await current.runUntilConnectedSessionEnds() }
    }

    private func runCancellably(
        _ body: @escaping @Sendable () async -> ClientReconnectOutcome
    ) async -> ClientReconnectOutcome {
        let task = Task { await body() }
        runTask = task
        let outcome = await task.value
        runTask = nil
        return outcome
    }

    func stopCurrentRun() {
        isStopped = true
        let driver = current
        Task { await driver?.stop() }
        runTask?.cancel()
    }

    func wake() {
        if let waiter {
            self.waiter = nil
            waiter.resume()
        } else {
            pendingWake = true
        }
    }

    func waitForRetry() async {
        if pendingWake {
            pendingWake = false
            return
        }
        await withCheckedContinuation { continuation in
            waiter = continuation
        }
    }
}

extension DiallingRun {
    /// Stops the current run and wakes anything waiting for a retry, so a
    /// return to the launch window is never left blocked on this one.
    func stop() {
        stopCurrentRun()
        wake()
    }
}

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
    private let port: NWEndpoint.Port
    private let tlsCertificateHash: Data
    private let identity: DeviceIdentity
    /// Session-time host-screen connects sign through this -- see
    /// `docs/host-screen-design.md` §6.3. Also handed to
    /// `ClientSessionController` at pairing time.
    private let credentialProvider: any PresenceCredentialProviding
    private let deviceName: String
    private let tracePath: String?
    private let transport: ClientTransportKind
    private let quit: QuitSignal
    private let shortcutMode: SystemShortcutMode
    /// Every canvas window is registered with it, so a View-menu toggle acts
    /// on whichever one has focus.
    private let menu: ViewerMainMenuController
    /// Fixed two-slot storage, matching the hard cap: `windows[0]` is the
    /// primary canvas, always present once connected once; `windows[1]`
    /// exists only when a session actually opened a second canvas. Never
    /// grown or indexed by anything the network sends.
    private var windows: [ClientCanvasWindowController?] = [nil, nil]
    private var trace: LatencyTraceWriter?
    private var lastRunner: ClientSessionRunner?
    /// One per viewer process, not one per window: whichever viewer window
    /// holds key focus is the one a reserved chord belongs to.
    private let shortcuts: SystemShortcutForwarder
    /// One per viewer process for the same reason: which canvas the user is
    /// looking at is a property of the session, so both windows must
    /// deduplicate their focus reports against the same state.
    private let focusReporter = ViewerFocusReporter()
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
    /// above already carries. A session starts with sharing off, matching
    /// `ClipboardSyncEngine.sharingEnabledByDefault`, until the viewer turns
    /// it on.
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
    /// action -- launch with a saved machine, the Connect with a virtual display
    /// button, or a Host screen pick -- and consumed by the very next
    /// `runOnce()`.
    /// Never in a retry loop: a signed proof is sent only inside an
    /// attempt the person initiated; an automatic redial that holds no
    /// ticket for the target stops instead of signing one.
    private var hostScreenConnectIsPersonInitiated = true

    init(
        saved: SavedHost,
        savedHostStore: any SavedHostStoring,
        hostScreenModeMemoryStore: any HostScreenModeMemoryStoring,
        port: NWEndpoint.Port,
        tlsCertificateHash: Data,
        identity: DeviceIdentity,
        credentialProvider: any PresenceCredentialProviding,
        deviceName: String,
        tracePath: String?,
        transport: ClientTransportKind,
        quit: QuitSignal,
        shortcutMode: SystemShortcutMode,
        menu: ViewerMainMenuController
    ) {
        self.saved = saved
        self.savedHostStore = savedHostStore
        self.hostScreenModeMemoryStore = hostScreenModeMemoryStore
        self.port = port
        self.tlsCertificateHash = tlsCertificateHash
        self.identity = identity
        self.credentialProvider = credentialProvider
        self.deviceName = deviceName
        self.tracePath = tracePath
        self.transport = transport
        self.quit = quit
        self.shortcutMode = shortcutMode
        self.menu = menu
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
        shortcuts = SystemShortcutForwarder(
            mode: shortcutMode,
            accessibility: SystemAccessibilityAuthorization(),
            interceptor: CoreGraphicsShortcutInterceptor()
        )
    }

    /// Builds the primary window and wires its callbacks the first time it is
    /// needed. It is not put on screen here: `markCanvasLive()` is what shows
    /// it, once there is a picture in it. Every later call reuses the same
    /// window, swapping in `controller` through `attach(session:)` exactly as
    /// an in-place reconnect already does.
    private func ensurePrimaryWindow(
        attachingTo controller: ClientSessionController
    ) async throws -> ClientCanvasWindowController {
        let window: ClientCanvasWindowController
        if let existing = windows[0] {
            window = existing
            await existing.attach(session: controller)
        } else {
            window = try ClientCanvasWindowController(
                title: saved.displayName,
                session: controller,
                macName: saved.displayName,
                focusReporter: focusReporter,
                shortcutMode: shortcutMode,
                initialStreamScalePreference: saved.streamScalePreference,
                savedHostStore: savedHostStore,
                savedHostPublicKey: saved.hostPublicKey
            )
            windows[0] = window
            shortcuts.register(window)
            menu.register(window)
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
        let transport = NetworkControlConnection(
            host: NWEndpoint.Host(saved.host),
            port: port,
            tlsCertificateHash: tlsCertificateHash,
            transport: self.transport
        )
        // A session always starts at one display; docs/ux-spec.md's
        // "Displays" menu is the only way a second one opens, live, below.
        let controller = ClientSessionController(
            transport: transport,
            identity: identity,
            credentialProvider: credentialProvider,
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

        if connectPlan.mustStopBeforeSigning {
            // Never in a retry loop: this is an automatic
            // redial (an inner backoff attempt, or a reconnect-after-drop)
            // holding no ticket for this target. Signing a fresh proof
            // here would re-prompt on every attempt; stop instead and wait
            // for the person, the same way a host's own refusal already
            // ends the run without retrying it. Decided above, before
            // `transport.start()`, so a stale flag surviving a failed
            // attempt can never reach this far.
            throw ClientSessionError.hostScreenRefused("host-screen-retry-needs-person")
        }
        try await transport.start()
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

        // Built here, after `connect()` returned a signed canvas, and torn
        // down with the runner: on this side the authenticated-and-active
        // gate is structural rather than a flag the session has to re-check.
        // `desiredClipboardSharingEnabled`, not a hardcoded default: a
        // reconnect after the person turned sharing on must not hand the
        // freshly-rebuilt engine a moment where it is disabled again,
        // however briefly, before the re-send below reaches the host.
        let clipboard = ClipboardSyncSession(
            engine: ClipboardSyncEngine(pasteboard: SystemPasteboard(), isEnabled: desiredClipboardSharingEnabled),
            log: { print("Sensorium: \($0)") }
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
        // The host says whether its screen is locked; the window offers or
        // hides the unlock prompt accordingly.
        runner.onHostScreenLockState = { locked in
            Task { @MainActor in
                primaryWindow.applyHostScreenLockState(locked: locked)
            }
        }
        runner.onHostScreenUnlockResult = { outcome in
            Task { @MainActor in
                primaryWindow.showHostScreenUnlockResult(outcome)
            }
        }
        // The typed password, forwarded on the live connection. The window has
        // already cleared its field, so this closure holds the only viewer-side
        // reference and drops it as soon as the request is sent. It is never
        // logged or written to disk. Copy-on-write `Data` gives no way to wipe
        // the transient copies the transport makes while framing it, so this
        // does not claim to erase every byte from memory.
        primaryWindow.onRequestHostScreenUnlock = { password in
            Task { @MainActor in
                let result = await runner.requestHostScreenUnlock(password: password)
                if let notice = HostScreenUnlockCopy.submitNotice(for: result) {
                    primaryWindow.showHostScreenUnlockNotice(notice)
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
        // A reconnect's own fresh runner and fresh host-side session both
        // start off, the same default `desiredClipboardSharingEnabled`
        // itself carries -- only an on choice needs telling again.
        if desiredClipboardSharingEnabled {
            await runner.setClipboardSharing(enabled: true)
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
    func reportHostScreenConnectEnded(reasonLine: String, failure: ViewerSessionFailure, offersPairAgain: Bool) {
        guard hasBeenLive else {
            onFailureBeforeLive?(failure)
            return
        }
        applyStatus(sessionState.handle(.hostScreenConnectEnded(reasonLine: reasonLine, offersPairAgain: offersPairAgain)))
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
    /// docs/ux-spec.md: choosing a host screen triggers the presence check,
    /// which this process cannot pass silently, so the only honest response
    /// is a fresh connect naming the new target. `endCurrentSession` ends
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
        primaryWindow: ClientCanvasWindowController,
        primaryTitle: String,
        runner: ClientSessionRunner
    ) async {
        desiredDisplayCount = 2
        let window: ClientCanvasWindowController
        if let existing = windows[1] {
            window = existing
            await existing.attach(session: session)
        } else {
            guard let built = try? ClientCanvasWindowController(
                title: ViewerWindowTitle.secondDisplayTitle(primaryTitle: saved.displayName),
                session: session,
                surfaceID: 1,
                macName: saved.displayName,
                focusReporter: focusReporter,
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
            menu.register(window)
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
            menu.unregister(window)
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

/// Why one machine's session ended.
enum ViewerSessionExit {
    /// The person quit.
    case quit
    /// The launch window is taking the screen back: a row's own Cancel,
    /// another machine clicked, "Pair again", or "Your machines" from a session that
    /// had gone live.
    case backToList
}

/// Parks the launch flow until the person clicks a machine. A machine clicked while
/// another was still dialling is held rather than dropped: the window has
/// already asked for that attempt to stop, and this is what the next turn of
/// the loop picks up.
@MainActor
final class SavedMachineChoice {
    private var pending: SavedHost?
    private var waiting: CheckedContinuation<SavedHost?, Never>?
    private var isFinished = false

    func choose(_ host: SavedHost) {
        guard !isFinished else { return }
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: host)
        } else {
            pending = host
        }
    }

    /// Nothing more will be chosen -- the person quit.
    func finish() {
        isFinished = true
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: nil)
        }
    }

    /// The next machine to enter, or `nil` once there will not be one.
    func next() async -> SavedHost? {
        if isFinished { return nil }
        if let pending {
            self.pending = nil
            return pending
        }
        return await withCheckedContinuation { continuation in
            if isFinished {
                continuation.resume(returning: nil)
            } else {
                waiting = continuation
            }
        }
    }
}

/// One connection to a machine being paired, opened the moment its code step
/// appears -- see `sendPairIntent` below -- and reused for every attempt that
/// follows, wrong-code retries included, instead of redialling per attempt. A
/// hand-typed address has nothing to dial yet, so it never comes through here.
@MainActor
final class EagerPairing {
    private let device: ViewerPairingDevice
    private let identity: DeviceIdentity
    private let credentialProvider: any PresenceCredentialProviding
    private let transport: ClientTransportKind
    private var connection: NetworkControlConnection?
    private var controller: ClientSessionController?

    init(
        device: ViewerPairingDevice,
        identity: DeviceIdentity,
        credentialProvider: any PresenceCredentialProviding,
        transport: ClientTransportKind
    ) {
        self.device = device
        self.identity = identity
        self.credentialProvider = credentialProvider
        self.transport = transport
    }

    /// Opens the connection on first use and hands back the same controller on
    /// every later call. `nil` only when the dial itself failed.
    private func openIfNeeded() async -> ClientSessionController? {
        if let controller { return controller }
        // Parsed the way the form does, so a saved host on a non-default port
        // (`address:port`) dials where it was paired rather than the default.
        guard let parsed = ViewerPairingForm(address: device.address).parsedAddress,
              let port = NWEndpoint.Port(rawValue: parsed.port) else {
            return nil
        }
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(parsed.host),
            port: port,
            tlsCertificateHash: nil,
            transport: transport
        )
        do {
            try await connection.start()
        } catch {
            return nil
        }
        let controller = ClientSessionController(
            transport: connection,
            identity: identity,
            credentialProvider: credentialProvider
        )
        self.connection = connection
        self.controller = controller
        return controller
    }

    /// Whatever is open has nobody left to talk to: a different machine was
    /// picked, or the code step was left.
    func close() async {
        await connection?.close()
        connection = nil
        controller = nil
    }

    func sendPairIntent(deviceName: String) async -> ViewerPairIntentAttempt {
        guard let controller = await openIfNeeded() else {
            return .failed(.unreachable)
        }
        do {
            try await controller.sendPairIntent(deviceName: deviceName)
            return .sent
        } catch {
            return .failed(ViewerPairingOutcome.classify(error))
        }
    }

    /// A wrong code (`.refused`) leaves the connection open for the next
    /// retyped digit; anything else ends it, so the next attempt -- if there
    /// is one -- redials fresh rather than reusing a connection already known
    /// to be bad.
    func pair(
        submission: ViewerPairingSubmission,
        fallback: () async -> ViewerPairingResult
    ) async -> ViewerPairingResult {
        guard let controller = await openIfNeeded() else {
            return await fallback()
        }
        do {
            let approval = try await withThrowingTaskGroup(of: PairingApproval.self) { group in
                group.addTask {
                    try await controller.pair(deviceName: Sensorium.deviceName(), code: submission.code)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(SessionTimeouts.remoteDefault.handshake))
                    throw ClientSessionError.timedOut
                }
                guard let first = try await group.next() else {
                    throw ClientSessionError.timedOut
                }
                group.cancelAll()
                return first
            }
            await connection?.close()
            connection = nil
            self.controller = nil
            return .paired(SavedHost(
                displayName: submission.displayName,
                host: submission.host,
                port: submission.port,
                hostPublicKey: approval.hostPublicKey,
                tlsCertificateHash: approval.tlsCertificateHash
            ))
        } catch {
            let outcome = ViewerPairingOutcome.classify(error)
            if EagerPairingRetryRule.decision(for: outcome) == .closeConnection {
                await connection?.close()
                connection = nil
                self.controller = nil
            }
            return .failed(outcome)
        }
    }
}

/// Holds the open connection belonging to the machine whose code step is on
/// screen, so announcing this machine and every code typed for it share one dial.
/// Picking a different machine replaces it; nothing is opened until a code step
/// asks for one.
@MainActor
final class PairingSessions {
    private let identity: DeviceIdentity
    private let credentialProvider: any PresenceCredentialProviding
    private let transport: ClientTransportKind
    private var current: (device: ViewerPairingDevice, pairing: EagerPairing)?

    init(
        identity: DeviceIdentity,
        credentialProvider: any PresenceCredentialProviding,
        transport: ClientTransportKind
    ) {
        self.identity = identity
        self.credentialProvider = credentialProvider
        self.transport = transport
    }

    func pairing(for device: ViewerPairingDevice) -> EagerPairing {
        if let current, current.device == device { return current.pairing }
        closeCurrent()
        let pairing = EagerPairing(
            device: device,
            identity: identity,
            credentialProvider: credentialProvider,
            transport: transport
        )
        current = (device, pairing)
        return pairing
    }

    /// Closes whatever is open, if anything is. Called when a different machine's
    /// code step replaces this one, and when the code step is left.
    func closeCurrent() {
        guard let open = current?.pairing else { return }
        current = nil
        Task { await open.close() }
    }
}

/// The session on screen right now, so one quit handler and the launch
/// window's own clicks reach it without a new handler registered per session.
@MainActor
final class ActiveSession {
    /// Set by the running session; `nil` whenever none is.
    var leave: (() -> Void)?

    /// Ends the session on screen and hands the screen back to the list.
    func leaveNow() {
        leave?()
    }
}

@main
@MainActor
struct Sensorium {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        var arguments = Array(CommandLine.arguments.dropFirst())
        // Also a launch flag, not a runtime toggle: which machine a
        // system-reserved shortcut acts on is chosen before the session, so it
        // can never change under the user's fingers mid-keystroke.
        var shortcutMode = SystemShortcutMode.default
        if let flag = arguments.firstIndex(of: "--system-shortcuts"), arguments.index(after: flag) < arguments.endIndex {
            guard let mode = SystemShortcutMode(flagValue: arguments[arguments.index(after: flag)]) else {
                print("usage: --system-shortcuts <local|remote-when-focused|remote-in-fullscreen>")
                Foundation.exit(2)
            }
            shortcutMode = mode
            arguments.removeSubrange(flag...arguments.index(after: flag))
        }
        var tracePath: String?
        if let flag = arguments.firstIndex(of: "--trace"), arguments.index(after: flag) < arguments.endIndex {
            tracePath = arguments[arguments.index(after: flag)]
            arguments.removeSubrange(flag...arguments.index(after: flag))
        }
        var transport = ClientTransportKind.quic
        if let flag = arguments.firstIndex(of: "--transport"), arguments.index(after: flag) < arguments.endIndex {
            guard let kind = ClientTransportKind(rawValue: arguments[arguments.index(after: flag)] == "tcp-local-verification" ? "tcpLocalVerification" : arguments[arguments.index(after: flag)]) else {
                print("usage: --transport <quic|tcp-local-verification>")
                Foundation.exit(2)
            }
            transport = kind
            arguments.removeSubrange(flag...arguments.index(after: flag))
        }
        let store = FileSavedHostStore(url: savedHostURL())
        let hostScreenModeMemoryStore = FileHostScreenModeMemoryStore(url: hostScreenModeMemoryURL())

        do {
            switch arguments.first {
            case "pair":
                guard let identity = resolveIdentity() else {
                    Foundation.exit(1)
                }
                guard arguments.count == 4,
                      let rawPort = UInt16(arguments[2]),
                      let port = NWEndpoint.Port(rawValue: rawPort) else {
                    print("usage: Sensorium pair <host> <port> <code>")
                    Foundation.exit(2)
                }
                let pairingConnection = NetworkControlConnection(
                    host: NWEndpoint.Host(arguments[1]),
                    port: port,
                    tlsCertificateHash: nil,
                    transport: transport
                )
                try await pairingConnection.start()
                let controller = ClientSessionController(
                    transport: pairingConnection,
                    identity: identity,
                    credentialProvider: SecureEnclavePresenceCredential(recordStoreURL: presenceCredentialRecordStoreURL())
                )
                let approval = try await controller.pair(deviceName: deviceName(), code: arguments[3])
                store.save(SavedHost(
                    displayName: arguments[1],
                    host: arguments[1],
                    port: rawPort,
                    hostPublicKey: approval.hostPublicKey,
                    tlsCertificateHash: approval.tlsCertificateHash
                ))
                await pairingConnection.close()
                print("Paired with \(arguments[1]). Its key is pinned; later sessions need no code.")

            case "enter", .none:
                guard arguments.count <= 2 else {
                    print("usage: Sensorium enter [sensorium://enter/<host>]")
                    Foundation.exit(2)
                }
                let entryURL: SensoriumEntryURL?
                if arguments.count == 2 {
                    guard let parsed = SensoriumEntryURL(string: arguments[1]) else {
                        print("Invalid enter URL. Expected: sensorium://enter/<host>")
                        Foundation.exit(2)
                    }
                    entryURL = parsed
                } else {
                    entryURL = nil
                }
                let quit = QuitSignal()
                if transport == .tcpLocalVerification {
                    print("Transport: TCP local-verification mode. The saved TLS pin is not checked; the host key still is.")
                }
                // Said before the first keystroke, because a shortcut this
                // viewer is never handed produces no event to complain about.
                for line in ClientShortcutPermissionReport.lines(
                    mode: shortcutMode,
                    accessibilityGranted: SystemAccessibilityAuthorization().isAccessibilityGranted
                ) {
                    print(line)
                }
                let credentialProvider = SecureEnclavePresenceCredential(
                    recordStoreURL: presenceCredentialRecordStoreURL()
                )
                // The only window at launch. Built here so the menu bar's own
                // "Your machines" item has something to open, and put on screen
                // below, once this machine's identity has been read: a list of
                // machines is not an answer to an identity that cannot be read.
                let launch = YourMachinesWindowController(
                    store: store,
                    credentialProvider: credentialProvider
                )
                launch.loadTailnet = {
                    await TailnetDevicePickerLoader(provider: LocalTailscaleStatusProvider()).load()
                }
                let choice = SavedMachineChoice()
                let active = ActiveSession()
                launch.onConnect = { host in
                    // The row says so from the click, the machine is queued, and
                    // whatever is on screen now gets out of the way. A machine
                    // clicked during a live session ends that session and is
                    // dialled at once -- never quietly, minutes later, when
                    // the session happens to end on its own.
                    launch.connectRequested(hostPublicKey: host.hostPublicKey)
                    choice.choose(host)
                    active.leaveNow()
                }
                launch.onCloseRequested = { quit.fire() }
                // Registered once, for every session this run will have.
                quit.onFire {
                    Task { @MainActor in
                        choice.finish()
                        active.leaveNow()
                    }
                }
                // Installed before the first window is on screen: the menu bar
                // is how a person quits, and a viewer that has no machine yet, or
                // cannot reach the one it has, must still be quittable.
                let menu = ViewerMainMenuController(
                    onQuit: { quit.fire() },
                    onShowYourMachines: {
                        launch.showList()
                        launch.show()
                    }
                )
                menu.install(into: NSApplication.shared)
                installQuitHandler { quit.fire() }

                // The canvas window needs real AppKit event delivery to
                // receive keyboard and pointer input, so the session runs on
                // a `Task` while this thread — already macOS's actual main
                // thread — becomes AppKit's event loop. The task hands
                // control back via `stopEventLoop` once the session has
                // fully ended.
                let application = NSApplication.shared
                // Copied out of the mutable flag parsing above: the task below
                // is main-actor isolated and may not capture a `var` the rest
                // of this function can still write.
                let sessionTransport = transport
                Task { @MainActor in
                    // Resolved here rather than before the event loop, so a
                    // key that cannot be read is said in a window instead of
                    // dying to stdout.
                    let identityStore = FileDeviceIdentityStore(url: identityFileURL())
                    var identityOutcome = loadIdentity()
                    var identityWasReplaced = false
                    let identity: DeviceIdentity = await { () async -> DeviceIdentity in
                        while true {
                            switch identityOutcome {
                            case let .success(loaded):
                                return loaded
                            case let .failure(failure):
                                let copy = ViewerStartupFailureCopy.copy(for: failure)
                                print(copy.headline)
                                print(copy.detail)
                                let message = ViewerMessageWindowController(
                                    eyebrow: "CANNOT START",
                                    headline: copy.headline,
                                    detail: copy.detail + "\n\n" + copy.replaceConsequence,
                                    actionTitle: copy.retryButtonTitle,
                                    // Trying again is never destructive, so
                                    // Return activates it; only replacing
                                    // this machine's identity is, and Return
                                    // must not fire that by accident.
                                    actionIsDefault: true,
                                    secondaryActionTitle: copy.replaceButtonTitle,
                                    dismissTitle: "Quit Sensorium"
                                )
                                quit.onFire {
                                    Task { @MainActor in message.dismiss() }
                                }
                                switch await message.run() {
                                case .dismissed:
                                    Foundation.exit(1)
                                case .actionTapped:
                                    identityOutcome = loadIdentity()
                                    continue
                                case .secondaryActionTapped:
                                    // Replacing is one-way and this screen's
                                    // own `replaceConsequence` line already
                                    // said so, but a tap that landed before
                                    // that sank in should still have one more
                                    // chance to back out before the key is
                                    // actually gone.
                                    let confirm = NSAlert()
                                    confirm.messageText = "Make a new key?"
                                    confirm.informativeText = "The host will ask for a pairing code again."
                                    confirm.addButton(withTitle: "Make a new key")
                                    confirm.addButton(withTitle: "Cancel")
                                    guard confirm.runModal() == .alertFirstButtonReturn else {
                                        continue
                                    }
                                    identityOutcome = ViewerIdentityRecovery.replace(using: identityStore)
                                    identityWasReplaced = true
                                }
                            }
                        }
                    }()
                    // A fresh identity is a machine the host has never seen:
                    // whatever this machine had saved about a host it used to
                    // reach is a pairing that key no longer holds, so it is
                    // cleared rather than attempted and refused silently --
                    // the normal first-run flow below asks for a pairing
                    // code again, exactly as the screen above said it would.
                    if identityWasReplaced {
                        store.clear()
                    }
                    // Everything the launch window needs this machine's identity
                    // or a socket for. None of it runs until the person asks:
                    // listing the machines already paired needs neither.
                    let pairingSessions = PairingSessions(
                        identity: identity,
                        credentialProvider: credentialProvider,
                        transport: sessionTransport
                    )
                    launch.onCodeStepAbandoned = { pairingSessions.closeCurrent() }
                    launch.sendPairIntent = { device in
                        await pairingSessions.pairing(for: device).sendPairIntent(deviceName: deviceName())
                    }
                    launch.pair = { device, submission in
                        guard let device else {
                            // A hand-typed address has nothing open to reuse,
                            // so each attempt dials for itself.
                            return await runPairingCeremony(
                                submission: submission,
                                identity: identity,
                                credentialProvider: credentialProvider,
                                transport: sessionTransport
                            )
                        }
                        return await pairingSessions.pairing(for: device).pair(submission: submission) {
                            await runPairingCeremony(
                                submission: submission,
                                identity: identity,
                                credentialProvider: credentialProvider,
                                transport: sessionTransport
                            )
                        }
                    }
                    if let entryURL {
                        guard let selected = store.loadAll().first(where: { $0.matches(entryURL) }) else {
                            print("That enter URL selects a host that is not paired on this machine. Pair it before entering.")
                            Foundation.exit(2)
                        }
                        // Selected, not dialled: nothing is sent until the
                        // person clicks a row, however the app was opened.
                        launch.select(hostPublicKey: selected.hostPublicKey)
                    }
                    launch.show()
                    // One turn per machine entered. A session that ends hands the
                    // screen back to the list, which is where the next one is
                    // chosen -- including the machine that was just paired.
                    while let host = await choice.next() {
                        let exit = await runHostSession(
                            saved: host,
                            savedHostStore: store,
                            hostScreenModeMemoryStore: hostScreenModeMemoryStore,
                            identity: identity,
                            credentialProvider: credentialProvider,
                            tracePath: tracePath,
                            transport: sessionTransport,
                            quit: quit,
                            shortcutMode: shortcutMode,
                            menu: menu,
                            launch: launch,
                            active: active
                        )
                        if case .quit = exit { break }
                        // Whatever step the session left this window on -- the
                        // list, or a code step "Pair again" opened -- is the
                        // step it comes back on.
                        launch.show()
                    }
                    stopEventLoop(application)
                }
                application.run()

            default:
                print("usage: Sensorium <pair|enter> [--trace <path.jsonl>] [--system-shortcuts <local|remote-when-focused|remote-in-fullscreen>] [--transport <quic|tcp-local-verification>]")
                print("  --transport is for diagnosing this machine only. tcp-local-verification drops TLS, so the")
                print("  certificate saved at pairing is never checked; a normal session leaves it unset.")
                Foundation.exit(2)
            }
        } catch {
            // Never the error value itself: a Swift case, or an NWError with
            // macOS's own wording inside it, is not something the person who
            // ran this can act on.
            print("Sensorium: \(ViewerSessionFailureCopy.line(for: error, hostLabel: store.loadAll().first?.displayName ?? "the other machine"))")
            Foundation.exit(1)
        }
    }

    /// Builds one machine's session and its retry driver, wires the launch
    /// window's row and the status panel's buttons to them, and dials until
    /// the session ends, the person quits, or the list is asked for again.
    private static func runHostSession(
        saved: SavedHost,
        savedHostStore: any SavedHostStoring,
        hostScreenModeMemoryStore: any HostScreenModeMemoryStoring,
        identity: DeviceIdentity,
        credentialProvider: any PresenceCredentialProviding,
        tracePath: String?,
        transport: ClientTransportKind,
        quit: QuitSignal,
        shortcutMode: SystemShortcutMode,
        menu: ViewerMainMenuController,
        launch: YourMachinesWindowController,
        active: ActiveSession
    ) async -> ViewerSessionExit {
        // One unusable saved machine is not the end of the app: it is
        // reported on its own row, and pairing again is the way out.
        func refuse(_ line: String) -> ViewerSessionExit {
            print("Sensorium: \(line)")
            launch.attemptFailed(reason: line)
            launch.stoppedTrying()
            return .backToList
        }
        guard let port = NWEndpoint.Port(rawValue: saved.port) else {
            return refuse("saved with an unusable port; pair again")
        }
        guard let tlsCertificateHash = saved.tlsCertificateHash else {
            return refuse("has no saved certificate; pair again before entering")
        }
        let session = ClientSessionHost(
            saved: saved,
            savedHostStore: savedHostStore,
            hostScreenModeMemoryStore: hostScreenModeMemoryStore,
            port: port,
            tlsCertificateHash: tlsCertificateHash,
            identity: identity,
            credentialProvider: credentialProvider,
            deviceName: deviceName(),
            tracePath: tracePath,
            transport: transport,
            quit: quit,
            shortcutMode: shortcutMode,
            menu: menu
        )
        // One driver per run of attempts. A stopped driver stays
        // stopped, so "Try again" starts a fresh one rather than
        // reviving a dead one, and the retry policy itself is
        // never edited to make that work.
        let dialling = DiallingRun(
            makeDriver: {
                ClientReconnectDriver(
                    policy: .remoteDefault,
                    runSession: { try await session.runOnce() },
                    sleep: { seconds in try? await Task.sleep(for: .seconds(seconds)) },
                    onEvent: { event in
                        let line = ViewerSessionFailureCopy.line(for: event, hostLabel: saved.displayName)
                        print("Sensorium: \(line)")
                        // A refused or failed host-screen connect never
                        // auto-redials (see `ClientReconnectDriver`'s own
                        // `.stopped` branch for it) and so never reaches
                        // `.gaveUp` either; the window still needs telling.
                        if case let .attemptFailed(.hostScreenRefused(reason)) = event {
                            Task { @MainActor in
                                // A saved "Start with" preference that names
                                // a host screen connects to it directly, so
                                // a refusal here can be this session's very
                                // first ending -- nothing else has named the
                                // display yet the way a Screen menu pick
                                // already would have. `hasBeenLive` is read
                                // fresh, not cached: a mid-session refusal
                                // (the person's own Screen menu pick) is
                                // read under a headline that already names
                                // the machine and a row the person just
                                // clicked, so it is never wrapped again.
                                let reportedLine: String
                                if !session.hasBeenLive, let displayLabel = session.currentHostScreenLabel {
                                    reportedLine = StartTargetConnectCopy.line(
                                        reasonLine: line, displayLabel: displayLabel
                                    )
                                } else {
                                    reportedLine = line
                                }
                                session.reportHostScreenConnectEnded(
                                    reasonLine: reportedLine,
                                    failure: .hostScreenRefused(reason: reason),
                                    offersPairAgain: HostScreenRefusalCopy.offersPairAgain(reason: reason)
                                )
                            }
                        } else if case .attemptFailed(.unverifiedHost) = event {
                            // Never fed to `reportAttemptFailed`: that line
                            // starts with "Stopped:", and a connecting or
                            // reconnecting panel must never show that while
                            // an attempt is still under way.
                            Task { @MainActor in
                                session.reportUnverifiedHost(reasonLine: line, failure: .unverifiedHost)
                            }
                        } else if case let .attemptFailed(failure) = event {
                            Task { @MainActor in
                                session.reportAttemptFailed(reasonLine: line, failure: failure)
                            }
                        }
                    }
                )
            }
        )
        session.onStopTrying = {
            print("Stopped trying to reach \(saved.displayName).")
            dialling.stopCurrentRun()
        }
        session.onTryAgain = {
            print("Trying \(saved.displayName) again…")
            dialling.wake()
        }
        // Set whenever the launch window is taking the screen back. Checked
        // alongside `quit.hasFired` everywhere below, so the loop unwinds the
        // same way a quit does -- the difference is only in what runs after.
        var wantsList = false
        // Ending the live session comes first: its own wait is what the run is
        // parked in, and cancelling around it would leave the picture up with
        // nothing behind it. Harmless when nothing is live.
        func returnToList() {
            wantsList = true
            session.endLiveSession()
            dialling.stop()
        }
        // The user's quit stops the retry loop as well as the live session;
        // otherwise it would only end the current attempt, and a viewer parked
        // between attempts would never wake up.
        active.leave = returnToList
        // A row's own Cancel, another machine clicked while this one was still
        // dialling, or this machine forgotten mid-attempt: all three ask this
        // session to end, and the window has already updated its own row.
        launch.onCancelConnecting = { returnToList() }
        // Nothing here is automatic beyond that: the one explicit way a
        // failed host-screen attempt this machine's own "Start with"
        // preference started switches to a virtual display and tries
        // again -- the same action the live session panel's own button
        // performs, reached here from the launch window's row instead.
        launch.onConnectAsVirtualDisplayFallback = { hostPublicKey in
            guard hostPublicKey == saved.hostPublicKey else { return }
            session.perform(.connectAsVirtualDisplay)
        }
        session.onPairAgain = {
            // The code step for this machine, in the window the person started
            // from. This session is already over -- "Pair again" is offered
            // only once it is -- so nothing live is thrown away here.
            launch.beginPairAgain(with: saved)
            returnToList()
        }
        session.onYourMachines = {
            launch.showList()
            returnToList()
        }
        session.onCanvasLive = {
            // The picture is up. The row that was dialling has nothing left
            // to report, this machine is now the most recently connected one, and
            // the list steps aside until it is asked for again. The stamp is
            // written against the stored record, not against the copy this
            // session started from: a reconnect after a drop would otherwise
            // put back a resolution the person changed while it was up.
            launch.stoppedConnecting(hostPublicKey: saved.hostPublicKey)
            savedHostStore.stampConnected(
                hostPublicKey: saved.hostPublicKey, at: Date(), liveTarget: session.liveStartTarget
            )
            launch.hide()
        }
        session.onAttemptStartedBeforeLive = {
            launch.connectStarted(hostPublicKey: saved.hostPublicKey)
        }
        session.onFailureBeforeLive = { failure in
            // `currentHostScreenLabel` is still this failed attempt's own --
            // nothing has changed `currentTarget` since it was read to make
            // this very connect -- so its presence is exactly "this attempt
            // was trying a host screen", the one case the row's own
            // "Connect with a virtual display" is offered for.
            launch.attemptFailed(
                reason: ViewerSessionFailureCopy.rowLine(for: failure, hostLabel: saved.displayName),
                offersConnectAsVirtualDisplayFallback: session.currentHostScreenLabel != nil
            )
        }

        while !quit.hasFired, !wantsList {
            var outcome = await dialling.startRun()
            // A session that connected and then dropped is worth
            // redialling; one the user closed, or stopped waiting
            // for, is not.
            while outcome == .sessionEnded, !quit.hasFired, !dialling.isStopped, !wantsList {
                print("Session lost; entering \(saved.displayName) again…")
                outcome = await dialling.continueRun()
            }
            if outcome == .stopped, session.consumeFallbackToVirtualDisplay() {
                // The default preference's own screen was refused before
                // this session ever went live, and it has already switched
                // itself to a session canvas -- the ordinary refusal
                // reporting above already said why, once; dialling again
                // is this run's own recovery, not a person's.
                continue
            }
            if case .gaveUp = outcome {
                print("Could not reach \(saved.displayName); giving up.")
                session.reportUnreachable()
            }
            if quit.hasFired || wantsList { break }
            guard session.hasBeenLive else {
                // No picture ever arrived, so there is no window of this
                // session's to wait in. The row keeps the last attempt's
                // reason, and clicking it again is how it is tried again.
                launch.stoppedTrying()
                wantsList = true
                break
            }
            // Nothing is dialling now, and the canvas window says so with a
            // Try again button. Wait for the user rather than exiting behind
            // their back.
            await dialling.waitForRetry()
        }
        launch.onCancelConnecting = nil
        launch.onConnectAsVirtualDisplayFallback = nil
        active.leave = nil
        if session.hasBeenLive {
            await session.reportLatency()
        } else {
            // Nothing is dialling this machine any more. A row still saying it is
            // stopping goes quiet here; one that kept a reason keeps it, and
            // one another machine's click has taken over is left alone.
            launch.stoppedConnecting(hostPublicKey: saved.hostPublicKey)
        }
        session.closeWindows()
        if quit.hasFired {
            print("Left; the virtual display has been released.")
            return .quit
        }
        return .backToList
    }

    /// One attempt at the one-time ceremony, for the pairing window: dial,
    /// send the code, and hand back either the host to save or the outcome the
    /// window turns into a sentence. Never throws — a first-run failure that
    /// reached the `catch` below would print a Swift enum and exit, which is
    /// the dead end this window exists to remove.
    private static func runPairingCeremony(
        submission: ViewerPairingSubmission,
        identity: DeviceIdentity,
        credentialProvider: any PresenceCredentialProviding,
        transport: ClientTransportKind
    ) async -> ViewerPairingResult {
        guard let port = NWEndpoint.Port(rawValue: submission.port) else {
            return .failed(.unknown)
        }
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(submission.host),
            port: port,
            tlsCertificateHash: nil,
            transport: transport
        )
        do {
            try await connection.start()
            let controller = ClientSessionController(
                transport: connection,
                identity: identity,
                credentialProvider: credentialProvider
            )
            let name = deviceName()
            let code = submission.code
            // `pair()` has no deadline of its own. A machine that accepts the
            // connection and then never answers would leave the window saying
            // "asking…" forever, which is a dead end wearing a spinner.
            let approval = try await withThrowingTaskGroup(of: PairingApproval.self) { group in
                group.addTask {
                    try await controller.pair(deviceName: name, code: code)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(SessionTimeouts.remoteDefault.handshake))
                    throw ClientSessionError.timedOut
                }
                guard let first = try await group.next() else {
                    throw ClientSessionError.timedOut
                }
                group.cancelAll()
                return first
            }
            await connection.close()
            return .paired(SavedHost(
                displayName: submission.displayName,
                host: submission.host,
                port: submission.port,
                hostPublicKey: approval.hostPublicKey,
                tlsCertificateHash: approval.tlsCertificateHash
            ))
        } catch {
            await connection.close()
            return .failed(ViewerPairingOutcome.classify(error))
        }
    }

    /// The key that identifies this machine, read from its own file under
    /// Application Support, or generated there on a first run.
    private static func loadIdentity() -> Result<DeviceIdentity, ViewerIdentityFailure> {
        ViewerIdentityRecovery.load(using: FileDeviceIdentityStore(url: identityFileURL()))
    }

    /// The `pair` verb is typed into a Terminal, which has a reader; the same
    /// words the window would show are printed instead of drawn.
    private static func resolveIdentity() -> DeviceIdentity? {
        switch loadIdentity() {
        case let .success(identity):
            return identity
        case let .failure(failure):
            let copy = ViewerStartupFailureCopy.copy(for: failure)
            print(copy.headline)
            print(copy.detail)
            return nil
        }
    }

    private static func identityFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Sensorium", isDirectory: true)
            .appendingPathComponent("device-identity.json")
    }

    /// Where this machine's own presence credential record persists -- design
    /// §6.3's "the tier is discovered by attempting it," reused across
    /// launches so pairing again never mints a second credential for a key
    /// still loadable from the Secure Enclave.
    private static func presenceCredentialRecordStoreURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Sensorium", isDirectory: true)
            .appendingPathComponent("presence-credential.json")
    }

    /// Traps SIGINT and SIGTERM so an interactive quit still tears the session
    /// down. `signal(..., SIG_IGN)` is required for the dispatch source to see
    /// them instead of the default terminating handler.
    private static func installQuitHandler(_ onQuit: @escaping @Sendable () -> Void) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler(handler: onQuit)
            source.resume()
            quitSources.append(source)
        }
    }

    /// `NSApplication.stop(_:)` only takes effect the next time the run loop
    /// dequeues an event, so a real one must follow it or `run()` would keep
    /// waiting for input that will never arrive.
    private static func stopEventLoop(_ application: NSApplication) {
        application.stop(nil)
        if let event = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            application.postEvent(event, atStart: true)
        }
    }

    static func deviceName() -> String {
        Host.current().localizedName ?? "This machine"
    }

    private static func savedHostURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Sensorium", isDirectory: true)
            .appendingPathComponent("saved-host.json")
    }

    /// Next to `savedHostURL()`, in the same "Sensorium" directory every
    /// other per-machine viewer file already lives in -- see
    /// `FileHostScreenModeMemoryStore`'s own doc comment for why this one
    /// file is owner-only like the credential files rather than plain like
    /// `saved-host.json`.
    private static func hostScreenModeMemoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Sensorium", isDirectory: true)
            .appendingPathComponent("host-screen-mode-memory.json")
    }
}

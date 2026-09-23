import Foundation
import SensoriumCore

/// The viewer application, from its arguments to the end of its event loop.
///
/// Two modes, both explicit:
///   pair    <host> <port> <code> — one-time ceremony; saves the host and pins its key
///   enter [sensorium://enter/<host>] — enter the saved paired host in one action
///
/// Neither mode is exercised by the verification runners: both open a socket,
/// and enter also reads and writes the saved-host file and the key that
/// identifies this machine.
///
/// Nothing here draws or dials by itself. Every window, the event loop, the
/// clipboard and the socket arrive through `ViewerPlatform.swift`'s protocols,
/// which is what lets one controller serve every platform the viewer runs on.
@MainActor
public final class ViewerApplication {
    private let environment: any ViewerPlatformEnvironment
    private let transports: any ViewerTransportFactory
    private let quit: QuitSignal
    /// Built only once the arguments have been read, so the `pair` verb and a
    /// usage error never put a window on screen.
    private let makeGUI: @MainActor () -> ViewerGUI
    private var quitSources: [DispatchSourceSignal] = []

    public init(
        environment: any ViewerPlatformEnvironment,
        transports: any ViewerTransportFactory,
        quit: QuitSignal,
        makeGUI: @escaping @MainActor () -> ViewerGUI
    ) {
        self.environment = environment
        self.transports = transports
        self.quit = quit
        self.makeGUI = makeGUI
    }

    public func run(arguments rawArguments: [String]) async {
        // Answered before anything is parsed, built or opened, so a package's
        // own check can run this on a machine with no display at all.
        if rawArguments.contains("--help") {
            for line in ViewerUsage.lines { print(line) }
            exit(0)
        }
        var arguments = rawArguments
        // A desktop environment hands a `sensorium://enter/<host>` link to
        // this binary with no verb in front of it, which means exactly what
        // `enter <url>` means.
        if let first = arguments.first, first.hasPrefix("\(SensoriumEntryURL.scheme)://") {
            arguments.insert("enter", at: 0)
        }
        // Also a launch flag, not a runtime toggle: which machine a
        // system-reserved shortcut acts on is chosen before the session, so it
        // can never change under the user's fingers mid-keystroke.
        var shortcutMode = SystemShortcutMode.default
        if let flag = arguments.firstIndex(of: "--system-shortcuts"), arguments.index(after: flag) < arguments.endIndex {
            guard let mode = SystemShortcutMode(flagValue: arguments[arguments.index(after: flag)]) else {
                print("usage: --system-shortcuts <local|remote-when-focused|remote-in-fullscreen>")
                exit(2)
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
            let raw = arguments[arguments.index(after: flag)]
            guard let kind = ClientTransportKind(rawValue: raw == "tcp-local-verification" ? "tcpLocalVerification" : raw) else {
                print("usage: --transport <quic|tcp-local-verification>")
                exit(2)
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
                    exit(1)
                }
                guard arguments.count == 4, let port = UInt16(arguments[2]), port != 0 else {
                    print("usage: Sensorium pair <host> <port> <code>")
                    exit(2)
                }
                let pairingConnection = transports.makeConnection(
                    host: arguments[1],
                    port: port,
                    tlsCertificateHash: nil,
                    transport: transport
                )
                try await pairingConnection.start(timeout: SessionTimeouts.remoteDefault.handshake)
                let controller = ClientSessionController(
                    transport: pairingConnection,
                    identity: identity
                )
                let approval = try await controller.pair(deviceName: environment.deviceName(), code: arguments[3])
                store.save(SavedHost(
                    displayName: arguments[1],
                    host: arguments[1],
                    port: port,
                    hostPublicKey: approval.hostPublicKey,
                    tlsCertificateHash: approval.tlsCertificateHash
                ))
                await pairingConnection.close()
                print("Paired with \(arguments[1]). Its key is pinned; later sessions need no code.")

            case "enter", .none:
                guard arguments.count <= 2 else {
                    print("usage: Sensorium enter [sensorium://enter/<host>]")
                    exit(2)
                }
                let entryURL: SensoriumEntryURL?
                if arguments.count == 2 {
                    guard let parsed = SensoriumEntryURL(string: arguments[1]) else {
                        print("Invalid enter URL. Expected: sensorium://enter/<host>")
                        exit(2)
                    }
                    entryURL = parsed
                } else {
                    entryURL = nil
                }
                if transport == .tcpLocalVerification {
                    print("Transport: TCP local-verification mode. The saved TLS pin is not checked; the host key still is.")
                }
                // Said before the first keystroke, because a shortcut this
                // viewer is never handed produces no event to complain about.
                for line in ClientShortcutPermissionReport.lines(
                    mode: shortcutMode,
                    accessibilityGranted: environment.isShortcutInterceptionGranted
                ) {
                    print(line)
                }
                // The only windows at launch, and the menu bar with them:
                // built here so quitting works before any machine has been
                // reached, and put on screen below, once this machine's
                // identity has been read. A list of machines is not an answer
                // to an identity that cannot be read.
                let gui = makeGUI()
                let launch = gui.launch
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
                launch.onCloseRequested = { [quit] in quit.fire() }
                // Registered once, for every session this run will have.
                quit.onFire {
                    Task { @MainActor in
                        choice.finish()
                        active.leaveNow()
                    }
                }
                installQuitHandler { [quit] in quit.fire() }

                // The canvas window needs real event delivery to receive
                // keyboard and pointer input, so the session runs on a `Task`
                // while this thread — already the process's main thread —
                // becomes the platform's event loop. The task hands control
                // back through `ViewerEventLoop.stop()` once the session has
                // fully ended.
                //
                // Copied out of the mutable flag parsing above: the task below
                // is main-actor isolated and may not capture a `var` the rest
                // of this function can still write.
                let sessionTransport = transport
                let sessionTracePath = tracePath
                let sessionShortcutMode = shortcutMode
                Task { @MainActor in
                    let identity = await resolveIdentityInWindow(prompts: gui.prompts, store: store)
                    // Everything the launch window needs this machine's identity
                    // or a socket for. None of it runs until the person asks:
                    // listing the machines already paired needs neither.
                    let pairingSessions = PairingSessions(
                        identity: identity,
                        transport: sessionTransport,
                        transports: transports,
                        deviceName: environment.deviceName()
                    )
                    launch.onCodeStepAbandoned = { pairingSessions.closeCurrent() }
                    launch.sendPairIntent = { [environment] device in
                        await pairingSessions.pairing(for: device).sendPairIntent(deviceName: environment.deviceName())
                    }
                    launch.pair = { [weak self] device, submission in
                        guard let self else { return .failed(.unknown) }
                        guard let device else {
                            // A hand-typed address has nothing open to reuse,
                            // so each attempt dials for itself.
                            return await self.runPairingCeremony(
                                submission: submission,
                                identity: identity,
                                transport: sessionTransport
                            )
                        }
                        return await pairingSessions.pairing(for: device).pair(submission: submission) {
                            await self.runPairingCeremony(
                                submission: submission,
                                identity: identity,
                                transport: sessionTransport
                            )
                        }
                    }
                    if let entryURL {
                        guard let selected = store.loadAll().first(where: { $0.matches(entryURL) }) else {
                            print("That enter URL selects a host that is not paired on this machine. Pair it before entering.")
                            exit(2)
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
                        let sessionExit = await runHostSession(
                            saved: host,
                            savedHostStore: store,
                            hostScreenModeMemoryStore: hostScreenModeMemoryStore,
                            identity: identity,
                            tracePath: sessionTracePath,
                            transport: sessionTransport,
                            shortcutMode: sessionShortcutMode,
                            gui: gui,
                            active: active
                        )
                        if case .quit = sessionExit { break }
                        // Whatever step the session left this window on -- the
                        // list, or a code step "Pair again" opened -- is the
                        // step it comes back on.
                        launch.show()
                    }
                    gui.eventLoop.stop()
                }
                gui.eventLoop.run()

            default:
                for line in ViewerUsage.lines { print(line) }
                exit(2)
            }
        } catch {
            // Never the error value itself: a Swift case, or a platform error
            // with the operating system's own wording inside it, is not
            // something the person who ran this can act on.
            print("Sensorium: \(ViewerSessionFailureCopy.line(for: error, hostLabel: store.loadAll().first?.displayName ?? "the other machine"))")
            exit(1)
        }
    }

    /// Reads this machine's key, and keeps asking in a window until there is
    /// one: trying the read again, or replacing it. Resolved here rather than
    /// before the event loop, so a key that cannot be read is said in a window
    /// instead of dying to stdout.
    private func resolveIdentityInWindow(
        prompts: any ViewerPrompts,
        store: any SavedHostStoring
    ) async -> DeviceIdentity {
        // Registered once, not per screen: quitting while this is up must not
        // be blocked behind it.
        quit.onFire {
            Task { @MainActor in prompts.dismissStartupFailure() }
        }
        let identityStore = FileDeviceIdentityStore(url: identityFileURL())
        var identityOutcome = loadIdentity()
        var identityWasReplaced = false
        let identity: DeviceIdentity = await {
            while true {
                switch identityOutcome {
                case let .success(loaded):
                    return loaded
                case let .failure(failure):
                    let copy = ViewerStartupFailureCopy.copy(for: failure)
                    print(copy.headline)
                    print(copy.detail)
                    switch await prompts.showStartupFailure(ViewerStartupFailurePrompt.make(for: copy)) {
                    case .quit:
                        exit(1)
                    case .tryAgain:
                        identityOutcome = loadIdentity()
                        continue
                    case .replaceIdentity:
                        guard await prompts.confirmNewKey() else { continue }
                        identityOutcome = ViewerIdentityRecovery.replace(using: identityStore)
                        identityWasReplaced = true
                    }
                }
            }
        }()
        // A fresh identity is a machine the host has never seen: whatever this
        // machine had saved about a host it used to reach is a pairing that
        // key no longer holds, so it is cleared rather than attempted and
        // refused silently -- the normal first-run flow asks for a pairing
        // code again, exactly as the screen above said it would.
        if identityWasReplaced {
            store.clear()
        }
        return identity
    }

    /// Builds one machine's session and its retry driver, wires the launch
    /// window's row and the status panel's buttons to them, and dials until
    /// the session ends, the person quits, or the list is asked for again.
    private func runHostSession(
        saved: SavedHost,
        savedHostStore: any SavedHostStoring,
        hostScreenModeMemoryStore: any HostScreenModeMemoryStoring,
        identity: DeviceIdentity,
        tracePath: String?,
        transport: ClientTransportKind,
        shortcutMode: SystemShortcutMode,
        gui: ViewerGUI,
        active: ActiveSession
    ) async -> ViewerSessionExit {
        let launch = gui.launch
        // One unusable saved machine is not the end of the app: it is
        // reported on its own row, and pairing again is the way out.
        func refuse(_ line: String) -> ViewerSessionExit {
            print("Sensorium: \(line)")
            launch.attemptFailed(reason: line, offersConnectAsVirtualDisplayFallback: false)
            launch.stoppedTrying()
            return .backToList
        }
        guard saved.port != 0 else {
            return refuse("saved with an unusable port; pair again")
        }
        guard let tlsCertificateHash = saved.tlsCertificateHash else {
            return refuse("has no saved certificate; pair again before entering")
        }
        let session = ClientSessionHost(
            saved: saved,
            savedHostStore: savedHostStore,
            hostScreenModeMemoryStore: hostScreenModeMemoryStore,
            port: saved.port,
            tlsCertificateHash: tlsCertificateHash,
            identity: identity,
            deviceName: environment.deviceName(),
            tracePath: tracePath,
            transport: transport,
            transports: transports,
            quit: quit,
            shortcutMode: shortcutMode,
            windowFactory: gui.windowFactory,
            windowsRegistry: gui.windowRegistry,
            environment: environment
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
                                    failure: .hostScreenRefused(reason: reason)
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
    /// reached the `catch` in `run(arguments:)` would print a Swift enum and
    /// exit, which is the dead end this window exists to remove.
    private func runPairingCeremony(
        submission: ViewerPairingSubmission,
        identity: DeviceIdentity,
        transport: ClientTransportKind
    ) async -> ViewerPairingResult {
        guard submission.port != 0 else {
            return .failed(.unknown)
        }
        let connection = transports.makeConnection(
            host: submission.host,
            port: submission.port,
            tlsCertificateHash: nil,
            transport: transport
        )
        do {
            try await connection.start(timeout: SessionTimeouts.remoteDefault.handshake)
            let controller = ClientSessionController(
                transport: connection,
                identity: identity
            )
            let name = environment.deviceName()
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

    /// The key that identifies this machine, read from its own file under the
    /// viewer's directory, or generated there on a first run.
    private func loadIdentity() -> Result<DeviceIdentity, ViewerIdentityFailure> {
        ViewerIdentityRecovery.load(using: FileDeviceIdentityStore(url: identityFileURL()))
    }

    /// The `pair` verb is typed into a terminal, which has a reader; the same
    /// words the window would show are printed instead of drawn.
    private func resolveIdentity() -> DeviceIdentity? {
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

    private func identityFileURL() -> URL {
        environment.applicationSupportDirectory().appendingPathComponent("device-identity.json")
    }

    private func savedHostURL() -> URL {
        environment.applicationSupportDirectory().appendingPathComponent("saved-host.json")
    }

    /// Next to `savedHostURL()`, in the same directory every other
    /// per-machine viewer file already lives in -- see
    /// `FileHostScreenModeMemoryStore`'s own doc comment for why this one
    /// file is owner-only rather than plain like `saved-host.json`.
    private func hostScreenModeMemoryURL() -> URL {
        environment.applicationSupportDirectory().appendingPathComponent("host-screen-mode-memory.json")
    }

    /// Traps SIGINT and SIGTERM so an interactive quit still tears the session
    /// down. `signal(..., SIG_IGN)` is required for the dispatch source to see
    /// them instead of the default terminating handler.
    private func installQuitHandler(_ onQuit: @escaping @Sendable () -> Void) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler(handler: onQuit)
            source.resume()
            quitSources.append(source)
        }
    }
}

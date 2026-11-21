#if os(Linux)
import Foundation
import SensoriumCore
import SensoriumHost

/// What the runtime needs from the desktop it runs on. The real desktop
/// supplies the portal, the layer-shell indicator, the screen saver and
/// logind; a test supplies stand-ins for each.
public struct LinuxHostPlatform {
    public var grantOpener: any LinuxScreenGrantOpening
    /// A new indicator for one session.
    public var makeIndicator: @MainActor () -> LinuxHostIndicator
    /// Why this desktop cannot show the indicator, or nil when it can. A
    /// desktop that cannot is offered no host screen at all.
    public var indicatorSupport: @MainActor () -> IndicatorError?
    public var lockState: any ScreenLockStateReading
    public var localActivity: any HostLocalActivitySignal
    public var relocker: any HostScreenRelocking
    /// How long ago the login session started, or nil when unknown.
    public var sessionAge: @Sendable () async -> TimeInterval?
    /// Asks the person at the host whether a device may see the screen, and
    /// waits for the answer. It runs on the main actor and blocks it, as the
    /// shared presence gate requires, so a window-less host must answer at
    /// once.
    public var askFirst: @MainActor (AskFirstPromptContent) -> AskFirstOutcome
    public var encoderBackend: LinuxEncoderBackendPreference

    public init(
        grantOpener: any LinuxScreenGrantOpening,
        makeIndicator: @escaping @MainActor () -> LinuxHostIndicator,
        indicatorSupport: @escaping @MainActor () -> IndicatorError?,
        lockState: any ScreenLockStateReading,
        localActivity: any HostLocalActivitySignal,
        relocker: any HostScreenRelocking,
        sessionAge: @escaping @Sendable () async -> TimeInterval?,
        askFirst: @escaping @MainActor (AskFirstPromptContent) -> AskFirstOutcome = LinuxHostPlatform.nobodyToAsk,
        encoderBackend: LinuxEncoderBackendPreference = .automatic
    ) {
        self.grantOpener = grantOpener
        self.makeIndicator = makeIndicator
        self.indicatorSupport = indicatorSupport
        self.lockState = lockState
        self.localActivity = localActivity
        self.relocker = relocker
        self.sessionAge = sessionAge
        self.askFirst = askFirst
        self.encoderBackend = encoderBackend
    }

    /// A host with no window has nobody to show the question to, so the
    /// question goes unanswered at once, which refuses the session.
    public static let nobodyToAsk: @MainActor (AskFirstPromptContent) -> AskFirstOutcome = { _ in .timedOut }
}

/// Where the host listens.
public enum LinuxHostListen: Sendable {
    /// This machine's tailnet address only. The host's one shipping choice.
    case tailnet(port: UInt16)
    /// A fixed address, for checks that run where there is no tailnet.
    case testOnly(address: String, port: UInt16)
}

/// The Linux host, headless: identity, pairing, arming, the screen-sharing
/// grant, the listener and every session, with the state the host window
/// shows and the actions it takes.
///
/// Everything the host keeps lives in one data folder,
/// `$XDG_DATA_HOME/sensorium-host`, in the same files the macOS host writes.
@MainActor
public final class LinuxHostRuntime {
    public static let defaultPort: UInt16 = 7777

    /// What the host window shows. `onStateChange` runs after each change.
    public private(set) var state: HostWindowState {
        didSet {
            if state != oldValue {
                onStateChange?(state)
            }
        }
    }
    public var onStateChange: ((HostWindowState) -> Void)?
    /// The UDP port the listener is bound to, once it is.
    public private(set) var boundPort: UInt16?
    /// The local-network switch has no Linux counterpart: the host listens
    /// on its tailnet address and nowhere else.
    public let supportsLocalNetwork = false

    private let dataFolder: URL
    private let platform: LinuxHostPlatform
    private let listen: LinuxHostListen
    private let log: @Sendable (String) -> Void

    private let grantState = PortalGrantState()
    private let approvedStore: FileApprovedDeviceStore
    private let armingStore: HostScreenArmingStore
    private let sessionLog: HostScreenSessionLogStore
    private let liveSessions = HostScreenLiveSessionRegistry()
    private let connections = HostDeviceConnectionRegistry()
    private let resumeTickets = HostScreenResumeTicketStore()
    private let unlockThrottle = HostScreenUnlockThrottle()
    private let ownActivity: MutableHostInjectedHIDActivity
    private let activitySignals: HostScreenActivitySignals
    /// This runtime's own record of a capture that could not be rebuilt, so
    /// one dead capture never outlasts the grant it came from in another
    /// runtime of the same process.
    private let captureAvailability = HostCaptureAvailability()
    private lazy var presenceGate = HostScreenPresenceGate(prompting: AskFirstPrompting(ask: platform.askFirst))

    private var pairing: HostPairingService?
    private var sessionFactory: HostConnectionSessionFactory?
    private var identity: HostTLSIdentity?
    private var server: OpenSSLQUICServer?
    private var acceptTask: Task<Void, Never>?
    private var listenRetryTask: Task<Void, Never>?
    private var openGrant: LinuxScreenGrant?
    private var feed: LinuxScreenFeed?
    private var grantGeneration = 0
    private var isOpeningGrant = false
    private var indicatorProblem: IndicatorError?
    private var liveConnections: [ObjectIdentifier: LiveConnection] = [:]
    private var liveHostScreen: LiveHostScreen?
    private var pairingDeviceName: String?
    private var isStopped = false

    private struct LiveConnection {
        let session: HostNetworkSession
        let coordinator: HostSessionCoordinator
    }

    private struct LiveHostScreen {
        let connection: ObjectIdentifier
        let deviceName: String
        let displayName: String
        let stop: @MainActor () -> Void
    }

    public init(
        dataFolder: URL,
        platform: LinuxHostPlatform,
        listen: LinuxHostListen = .tailnet(port: LinuxHostRuntime.defaultPort),
        log: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.dataFolder = dataFolder
        self.platform = platform
        self.listen = listen
        self.log = log
        approvedStore = FileApprovedDeviceStore(url: dataFolder.appendingPathComponent("approved-devices.json"))
        armingStore = HostScreenArmingStore(url: dataFolder.appendingPathComponent("host-screen-arming.json"), log: log)
        sessionLog = HostScreenSessionLogStore(url: dataFolder.appendingPathComponent("host-screen-sessions.log"))
        ownActivity = MutableHostInjectedHIDActivity(rawActivity: platform.localActivity)
        activitySignals = HostScreenActivitySignals(raw: platform.localActivity, ownActivity: ownActivity)
        state = HostWindowState(status: .notHosting, grant: .needed, openAtLogin: .notAvailable)
    }

    /// Whether a viewer asking now would be offered the host screen.
    public var offersHostScreen: Bool {
        !offeredDisplays().isEmpty
    }

    // MARK: - Starting and stopping

    /// Brings the host up: identity, pairing, lock at launch, the listener
    /// and the screen-sharing grant, restored once without a dialog.
    public func start() async {
        do {
            try FileManager.default.createDirectory(
                at: dataFolder,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            fail(headline: "Sensorium Host could not start", detail: "Its data folder could not be made: \(error)")
            return
        }
        indicatorProblem = platform.indicatorSupport()
        if let indicatorProblem {
            log("Sensorium host: no host screen is offered: \(indicatorProblem)")
        }
        sessionLog.reconcileAbandonedSessionsAtLaunch()
        guard let identity = loadIdentities() else { return }
        self.identity = identity.tls
        armingStore.armEveryPairedMachine(approvedStore: approvedStore, now: Date())
        makePairingAndSessions(hostIdentity: identity.device, tls: identity.tls)
        grantState.setChangeHandler { [weak self] in
            Task { @MainActor in self?.refreshState() }
        }
        let sessionAge = await platform.sessionAge()
        let locked = LinuxLockAtLaunch.apply(
            lockState: platform.lockState,
            activity: platform.localActivity,
            sessionAge: sessionAge,
            relocker: platform.relocker
        )
        if locked == .locked {
            log("Sensorium host: the screen was locked at launch, because nobody had used this session since login")
        }
        startListening()
        await openScreenGrant(interactive: false)
        refreshState()
    }

    /// Ends every session, closes the listener and the grant.
    public func stop() async {
        guard !isStopped else { return }
        isStopped = true
        listenRetryTask?.cancel()
        server?.stop()
        server = nil
        acceptTask?.cancel()
        for live in liveConnections.values {
            await live.coordinator.sessionDidEnd(reason: "host-quit")
            live.session.stop()
        }
        liveConnections.removeAll()
        await closeScreenGrant()
        state.status = .notHosting
        boundPort = nil
    }

    private func loadIdentities() -> (device: DeviceIdentity, tls: HostTLSIdentity)? {
        let device: DeviceIdentity
        let tls: HostTLSIdentity
        do {
            device = try FileDeviceIdentityStore(url: dataFolder.appendingPathComponent("device-identity.json")).loadOrCreate()
            tls = try FileHostTLSIdentityStore(
                url: dataFolder.appendingPathComponent("host-tls-identity.json"),
                commonName: "Sensorium Host"
            ).loadOrCreate()
        } catch {
            fail(headline: "Sensorium Host could not start", detail: "This machine\u{2019}s identity could not be read or made: \(error)")
            return nil
        }
        return (device, tls)
    }

    private func fail(headline: String, detail: String) {
        log("Sensorium host: \(headline): \(detail)")
        state.status = .couldNotStart(headline: headline, detail: detail)
    }

    // MARK: - Listening

    private func startListening() {
        let address: String
        let port: UInt16
        switch listen {
        case let .testOnly(fixed, fixedPort):
            address = fixed
            port = fixedPort
        case let .tailnet(tailnetPort):
            guard case let .single(found) = TailnetAddressEnumerator.autoSelect() else {
                // Tailscale may come up after the host at login; look again
                // until it does rather than listen anywhere else.
                fail(headline: "Waiting for Tailscale", detail: "This machine has no tailnet address yet.")
                scheduleListenRetry()
                return
            }
            address = found
            port = tailnetPort
        }
        guard let identity else { return }
        let server = OpenSSLQUICServer(identity: identity, bindAddress: address, port: port)
        do {
            try server.start()
        } catch {
            fail(headline: "Sensorium Host could not start", detail: "It could not listen on \(address) port \(port): \(error)")
            if case .tailnet = listen { scheduleListenRetry() }
            return
        }
        self.server = server
        boundPort = server.boundPort
        log("Sensorium host bound \(address):\(server.boundPort)")
        state.status = .waiting
        let channels = server.channels
        acceptTask = Task { @MainActor [weak self] in
            for await channel in channels {
                guard let self, !self.isStopped else {
                    channel.cancel()
                    continue
                }
                self.serve(channel)
            }
        }
    }

    private func scheduleListenRetry() {
        listenRetryTask?.cancel()
        listenRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, !self.isStopped, self.server == nil else { return }
            self.startListening()
        }
    }

    // MARK: - The screen-sharing grant

    /// Asks the desktop to allow screen sharing again, with its dialog.
    public func allowScreenSharing() {
        Task { await openScreenGrant(interactive: true) }
    }

    private func openScreenGrant(interactive: Bool) async {
        guard !isOpeningGrant, !isStopped else { return }
        isOpeningGrant = true
        defer { isOpeningGrant = false }
        await closeScreenGrant()
        grantGeneration += 1
        let generation = grantGeneration
        let opened: LinuxScreenGrant
        do {
            opened = try await platform.grantOpener.open(interactive: interactive, onClosed: { [weak self] in
                Task { @MainActor in await self?.grantEndedByDesktop(generation: generation) }
            })
        } catch {
            log("Sensorium host: screen sharing is not allowed: \(error)")
            state.grant = .needed
            return
        }
        grantState.install(grant: opened.grant, sink: opened.input)
        let feed = LinuxScreenFeed(source: opened.frameSource, grantState: grantState)
        do {
            try await feed.start()
        } catch {
            log("Sensorium host: the screen could not be captured: \(error)")
            grantState.end()
            await opened.close()
            state.grant = .needed
            return
        }
        openGrant = opened
        self.feed = feed
        state.grant = .allowed
        refreshState()
    }

    private func grantEndedByDesktop(generation: Int) async {
        guard generation == grantGeneration else { return }
        log("Sensorium host: the desktop ended screen sharing")
        await closeScreenGrant()
    }

    private func closeScreenGrant() async {
        let feed = self.feed
        let opened = openGrant
        self.feed = nil
        openGrant = nil
        grantState.end()
        // A session streaming from the feed is told it failed, and ends.
        feed?.stop()
        await opened?.close()
        state.grant = .needed
        refreshState()
    }

    // MARK: - Pairing and sessions

    private func makePairingAndSessions(hostIdentity: DeviceIdentity, tls: HostTLSIdentity) {
        let pairing = HostPairingService(
            hostIdentity: hostIdentity,
            approvedStore: approvedStore,
            tlsCertificateHash: tls.certificateHash,
            onDeviceApproved: { [weak self] approval in
                MainActor.assumeIsolated { self?.deviceApproved(approval) }
            }
        )
        self.pairing = pairing
        let grantState = grantState
        sessionFactory = HostConnectionSessionFactory(
            sessions: CanvasSurfaceSlots { _ in VirtualDisplaySession(adapter: NoCanvasDisplayAdapter()) },
            requireAuthentication: true,
            inputInjectorFactory: PortalInputInjectorFactory(
                grantState: grantState,
                observer: PortalInputPostObserver(
                    sampleBeforePost: { [ownActivity] in ownActivity.sampleBeforePost() },
                    recordPost: { [ownActivity] in ownActivity.recordPost() }
                )
            ),
            pairing: pairing,
            onPairingRequested: { [weak self] deviceName in self?.pairingRequested(by: deviceName) },
            keyConfinement: .unconfined,
            hostCertificateHash: tls.certificateHash,
            hostScreenArmingProvider: { [armingStore] in armingStore.load() },
            hostScreenCurrentDisplaysProvider: { [weak self] in self?.offeredDisplays() ?? [] },
            hostScreenResumeTicketStore: resumeTickets,
            hostScreenUnlockThrottle: unlockThrottle,
            hostScreenLiveSessionRegistry: liveSessions,
            deviceConnectionRegistry: connections,
            hostScreenPresenceActivitySignal: activitySignals.presence,
            hostScreenPresenceGate: presenceGate,
            privateDesktopOffered: { false },
            hostScreenLockStateReader: platform.lockState,
            log: { [log] line in log(line) }
        )
    }

    /// The monitor a viewer may ask for: the granted one, once its first
    /// frame says its scale, and only where the indicator can be shown.
    private func offeredDisplays() -> [DisplaySnapshot] {
        guard indicatorProblem == nil else { return [] }
        return PortalDisplayInventory(grantState: grantState).displays()
    }

    private func serve(_ channel: OpenSSLQUICServerChannel) {
        guard let sessionFactory else {
            channel.cancel()
            return
        }
        let log = log
        let controller = sessionFactory.makeController()
        let latencyRecorder = HostMediaLatencyRecorder()
        let sendFeedback = VideoSendFeedback()
        let connectionBox = ConnectionBox()
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            latencyRecorder: latencyRecorder,
            clipboard: nil,
            sendFeedback: sendFeedback,
            onEvent: { log($0) },
            onPeerPresence: { [weak self] presence in
                Task { @MainActor in self?.peerPresenceChanged(presence, connection: connectionBox.id) }
            }
        )
        let id = ObjectIdentifier(session)
        connectionBox.id = id
        controller.onStopRequested = { [weak session] in session?.stop() }
        let platform = platform
        let accountable = HostScreenAccountableMedia(
            capturePermission: ScreenCapturePermissionGate(checker: PortalCapturePermissionChecker(grantState: grantState)),
            rawFactory: { [weak self] configuration, sequencer in
                guard let feed = self?.feed else {
                    return UnavailableMedia(reason: "screen sharing ended before the stream started")
                }
                return LinuxHostScreenMedia(
                    configuration: configuration,
                    sequencer: sequencer,
                    feed: feed,
                    latencyRecorder: latencyRecorder,
                    sendFeedback: sendFeedback,
                    backendPreference: platform.encoderBackend,
                    log: log
                )
            },
            sessionLog: sessionLog,
            deviceName: { controller.hostScreenDeviceName ?? "" },
            reportedDeviceName: { controller.hostScreenReportedDeviceName },
            displayLabel: { controller.hostScreenDisplayLabel ?? "" },
            onBadgeStop: { [weak session] in session?.stop() },
            badgeFactory: { [weak self, weak session] state, _ in
                SessionIndicator(
                    badge: LinuxIndicatorBadge(state: state, indicator: platform.makeIndicator()),
                    onShown: {
                        self?.hostScreenStarted(
                            connection: id,
                            deviceName: state.content.deviceName,
                            displayName: state.content.displayLabel,
                            stop: { session?.stop() }
                        )
                    },
                    onHidden: { self?.hostScreenEnded(connection: id) }
                )
            }
        )
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: CanvasSurfaceSlots { _ in UnavailableMedia(reason: "this host offers no session canvas") },
            videoSink: session,
            latencyRecorder: latencyRecorder,
            onEvent: { log($0) },
            onSessionEnded: {
                if let summary = HostLatencySummary.line(
                    metrics: latencyRecorder.metrics,
                    droppedFrameCount: session.droppedVideoFrameCount,
                    frameCounts: latencyRecorder.frameCounts
                ) {
                    log("Sensorium host: \(summary)")
                }
            },
            onStreamUnrecoverable: { [weak session] reason in
                log("Sensorium host: ending session: \(reason)")
                session?.stop()
            },
            hostScreenMediaFactory: accountable.makeMedia,
            requiresAccountableHostScreenMedia: true,
            captureAvailability: captureAvailability,
            lockStateReader: platform.lockState,
            lockScreenUnlocker: UnavailableLockScreenUnlocker(),
            hostScreenRelockPoster: platform.relocker,
            hostScreenRelockActivitySignal: activitySignals.relock,
            sharpScreens: nil
        )
        session.attach(coordinator: coordinator)
        liveConnections[id] = LiveConnection(session: session, coordinator: coordinator)
        session.start()
    }

    private func peerPresenceChanged(_ presence: HostPeerPresence, connection: ObjectIdentifier?) {
        switch presence {
        case let .identified(deviceName):
            if pairingDeviceName == deviceName {
                pairingDeviceName = nil
            }
        case .closed:
            if let connection {
                liveConnections[connection] = nil
                hostScreenEnded(connection: connection)
            }
        }
        refreshState()
    }

    private func hostScreenStarted(connection: ObjectIdentifier, deviceName: String, displayName: String, stop: @escaping @MainActor () -> Void) {
        pairingDeviceName = nil
        liveHostScreen = LiveHostScreen(connection: connection, deviceName: deviceName, displayName: displayName, stop: stop)
        refreshState()
    }

    private func hostScreenEnded(connection: ObjectIdentifier) {
        guard liveHostScreen?.connection == connection else { return }
        liveHostScreen = nil
        refreshState()
    }

    // MARK: - Pairing

    /// Shows a new pairing code, valid for one machine for a few minutes.
    public func showPairingCode() {
        guard let pairing else { return }
        let code = pairing.issueCode()
        state.pairing = .showing(
            code: code,
            expiresAt: Date().addingTimeInterval(PairingAuthority.defaultLifetime),
            requestingDeviceName: nil
        )
        log("Sensorium host: pairing code shown")
    }

    public func hidePairingCode() {
        state.pairing = .idle
    }

    /// A viewer opened its code screen: show a code if none is up, naming
    /// the machine that asked.
    private func pairingRequested(by deviceName: String) {
        if case .idle = state.pairing {
            showPairingCode()
        }
        if case let .showing(code, expiresAt, _) = state.pairing {
            state.pairing = .showing(code: code, expiresAt: expiresAt, requestingDeviceName: deviceName)
        }
    }

    private func deviceApproved(_ approval: PairingApproval) {
        // Pairing arms a device; pairing again never re-arms one the person
        // here turned off.
        if approval.isNewDevice {
            armingStore.arm(HostScreenDeviceArming.onPairing(
                devicePublicKey: approval.devicePublicKey,
                approvedStore: approvedStore,
                now: Date()
            ))
        }
        state.pairing = .idle
        pairingDeviceName = approval.deviceName
        refreshState()
    }

    // MARK: - Paired machines

    /// Turns sharing the host screen on or off for one machine. Off ends its
    /// live session at once.
    public func setSharing(machineID: String, isOn: Bool) {
        guard let key = Data(base64Encoded: machineID) else { return }
        if isOn {
            armingStore.arm(HostScreenDeviceArming.onPairing(devicePublicKey: key, approvedStore: approvedStore, now: Date()))
        } else {
            revoke { $0.turnOff(devicePublicKey: key) }
        }
        refreshState()
    }

    /// Whether this machine's sessions ask the person here first while
    /// someone has used this machine in the last few minutes.
    public func setAsksFirst(machineID: String, isOn: Bool) {
        guard let key = Data(base64Encoded: machineID) else { return }
        armingStore.setAsksWhenInUse(devicePublicKey: key, isOn)
        refreshState()
    }

    /// Names a paired machine on this host. Its key and arming are untouched.
    public func rename(machineID: String, to name: String) {
        guard let key = Data(base64Encoded: machineID) else { return }
        PairedDeviceName.rename(key, to: name, in: approvedStore)
        refreshState()
    }

    /// Forgets a paired machine and ends every connection it has.
    public func remove(machineID: String) {
        guard let key = Data(base64Encoded: machineID) else { return }
        revoke { $0.removePairedDevice(devicePublicKey: key) }
        refreshState()
    }

    /// Ends the live host-screen session, as the indicator's Stop does.
    public func stopLiveSession() {
        liveHostScreen?.stop()
    }

    /// Turning off or removing goes through the running pairing service, so
    /// the keys a later hello is checked against change with the files.
    private func revoke(_ change: (HostScreenDeviceRevocation) -> Void) {
        guard let pairing else { return }
        change(HostScreenDeviceRevocation(
            armingStore: armingStore,
            pairedDevices: pairing,
            liveSessions: liveSessions,
            connections: connections
        ))
    }

    // MARK: - State

    private func refreshState() {
        var next = state
        next.desktop = indicatorProblem == nil ? .supported : .unsupported
        next.grant = grantState.isGranted ? .allowed : .needed
        next.allowsLocalNetwork = false
        next.lastSessionLine = HostScreenSessionLogPresentation.line(for: sessionLog.lastRecord)
        next.machines = machineRows()
        switch next.status {
        case .notHosting, .couldNotStart:
            break
        default:
            if let liveHostScreen {
                next.status = .sharing(deviceName: liveHostScreen.deviceName, displayName: liveHostScreen.displayName)
            } else if let pairingDeviceName {
                next.status = .pairing(deviceName: pairingDeviceName)
            } else {
                next.status = .waiting
            }
        }
        state = next
    }

    private func machineRows() -> [HostWindowMachine] {
        let approved: [(publicKey: Data, name: String?)] = approvedStore.load()
            .sorted { $0.base64EncodedString() < $1.base64EncodedString() }
            .map { key in (key, approvedStore.customName(for: key) ?? approvedStore.name(for: key)) }
        let rows = HostScreenArmingPresentation.pairedMachineRows(
            approvedDevices: approved,
            arming: armingStore.load(),
            activeDisplays: offeredDisplays()
        )
        return rows.map { row in
            HostWindowMachine(
                id: row.devicePublicKey.base64EncodedString(),
                name: row.deviceName,
                isArmed: row.isSharingRealScreen,
                sharedDisplaysLine: row.sharedDisplaysLine,
                notOfferedReason: row.notOfferedReason,
                keyFingerprintLine: row.keyFingerprintLine,
                asksFirst: row.asksWhenInUse
            )
        }
    }
}

/// The connection a session belongs to, filled in once the session exists.
private final class ConnectionBox: @unchecked Sendable {
    var id: ObjectIdentifier?
}

/// The ask-first question through the platform's prompt.
@MainActor
private final class AskFirstPrompting: HostScreenPresencePrompting {
    private let ask: @MainActor (AskFirstPromptContent) -> AskFirstOutcome

    init(ask: @escaping @MainActor (AskFirstPromptContent) -> AskFirstOutcome) {
        self.ask = ask
    }

    func ask(content: HostScreenBadgeContent) -> HostScreenPresenceRule.Answer? {
        switch ask(AskFirstPromptContent(deviceName: content.deviceName, displayLabel: content.displayLabel)) {
        case .allowed: .approved
        case .denied: .declined
        case .timedOut: nil
        }
    }
}

/// A session's indicator that also tells the runtime the session is live.
@MainActor
private final class SessionIndicator: HostScreenBadgeDisplaying {
    private let badge: LinuxIndicatorBadge
    private let onShown: @MainActor () -> Void
    private let onHidden: @MainActor () -> Void

    init(badge: LinuxIndicatorBadge, onShown: @escaping @MainActor () -> Void, onHidden: @escaping @MainActor () -> Void) {
        self.badge = badge
        self.onShown = onShown
        self.onHidden = onHidden
    }

    func show() throws {
        try badge.show()
        onShown()
    }

    func hide() {
        badge.hide()
        onHidden()
    }
}
#endif

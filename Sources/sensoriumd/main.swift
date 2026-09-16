import AppKit
import CoreMedia
import SensoriumCore
import SensoriumHost
import Foundation
import Network

/// Three entry points:
///   (no arguments)  — a GUI host: menu-bar item, setup window, no terminal needed
///   pair  <port>    — run the one-time ceremony and print the code to read aloud
///   serve <port>    — accept only paired tailnet machines

/// Lets the session workspaces, chosen once at startup, cross into
/// `serveChannel`'s `@Sendable` closure. `CanvasWorkspacePresenting` is
/// `@MainActor`-isolated, so every access to `workspaces` happens from a
/// `@MainActor` `Task`.
private final class HostWorkspaceBox: @unchecked Sendable {
    let workspaces: CanvasSurfaceSlots<any CanvasWorkspacePresenting>
    init(_ workspaces: CanvasSurfaceSlots<any CanvasWorkspacePresenting>) {
        self.workspaces = workspaces
    }
}

/// Lets the two operator-facing objects cross into `serveChannel`'s
/// `@Sendable` closure, exactly as `HostWorkspaceBox` does for the workspaces:
/// both are `@MainActor`-isolated and every access below happens from a
/// `@MainActor` `Task`.
private final class HostOperatorBox: @unchecked Sendable {
    let status: HostOperatorStatusStore
    let shutdown: HostShutdownRegistry
    /// Every canvas display this process created and has not released. Held
    /// here so the adapters `beginHosting` builds, the capability probe, the
    /// quit path and the termination-signal handlers all share one list.
    let canvas: CanvasShutdown
    init(
        status: HostOperatorStatusStore,
        shutdown: HostShutdownRegistry,
        canvas: CanvasShutdown
    ) {
        self.status = status
        self.shutdown = shutdown
        self.canvas = canvas
    }
}

/// `.terminateLater`, because ending the session is asynchronous and the
/// canvases are released after it. A second terminate request joins the
/// first rather than running `forceRelease` under an unfinished teardown; a
/// bounded wait forces the reply so a stuck teardown cannot hang the quit.
@MainActor
private final class HostApplicationDelegate: NSObject, NSApplicationDelegate {
    private let teardown: @MainActor () async -> Void
    private let forceRelease: @MainActor () -> Void
    private let timeoutNanoseconds: UInt64
    private var isTerminating = false
    private var hasReplied = false

    init(
        teardown: @escaping @MainActor () async -> Void,
        forceRelease: @escaping @MainActor () -> Void,
        timeoutNanoseconds: UInt64 = 5_000_000_000
    ) {
        self.teardown = teardown
        self.forceRelease = forceRelease
        self.timeoutNanoseconds = timeoutNanoseconds
        super.init()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else {
            return .terminateLater
        }
        isTerminating = true

        Task { @MainActor [weak self] in
            await self?.teardown()
            self?.reply(sender)
        }
        Task { @MainActor [weak self] in
            guard let timeoutNanoseconds = self?.timeoutNanoseconds else {
                return
            }
            try? await Task.sleep(nanoseconds: timeoutNanoseconds)
            guard let self, !self.hasReplied else {
                return
            }
            self.forceRelease()
            self.reply(sender)
        }
        return .terminateLater
    }

    private func reply(_ sender: NSApplication) {
        guard !hasReplied else {
            return
        }
        hasReplied = true
        sender.reply(toApplicationShouldTerminate: true)
    }
}

/// This connection's own record of who is on it, so the terminal can name the
/// machine that left as well as the one that arrived. Written and read only from
/// the main actor, the same discipline as `HostWorkspaceBox`.
private final class PeerLogBox: @unchecked Sendable {
    var log = HostPeerActivityLog()
}

/// This connection's registration in the quit registry, so the transport's
/// `@Sendable` presence callback can drop it when the session ends. Written
/// once and read once, both on the main actor -- the same discipline as
/// `HostWorkspaceBox`.
private final class QuitRegistrationBox: @unchecked Sendable {
    var ticket: Int?
}

/// This connection's own `ClipboardSyncSession`, filled in after the
/// controller it needs to capture for `isSessionAdmissible` -- so the
/// controller's own `onClipboardSharingChanged` can reach it without the
/// two objects needing each other to already exist at construction time.
private final class ClipboardSessionBox: @unchecked Sendable {
    var session: ClipboardSyncSession?
}

/// Carries no message: `resolveIdentity`/`resolveTLSIdentity` already
/// printed the specific reason. It exists only to tell the CLI, which must
/// not print a second generic line, from the GUI, which offers "Make a new
/// key".
private enum HostStartupError: Error {
    case identityUnavailable
    case tlsIdentityUnavailable
}

/// Owns the arming and approved-device stores and keeps the host window and
/// the menu bar in sync with them. A class rather than closures captured
/// individually in `runGUI`, so "arm", "turn off", and "remove paired
/// device" all update both surfaces from the one place that reads the
/// stores back after writing them.
///
/// Deliberately never handed to `beginHosting`, `HostSessionController`, or
/// `HostSessionCoordinator`: this object's only callers are the host
/// window's switch and button and the menu bar's own item, all driven by an
/// `NSEvent` from a human at this machine. Host-set only by construction:
/// no wire message can reach here.
@MainActor
private final class HostScreenArmingCoordinator {
    private let armingStore: HostScreenArmingStore
    private let approvedStore: any ApprovedDeviceStoring
    private weak var hostWindow: HostSetupWindowController?
    private weak var presence: HostMenuBarPresence?

    init(armingStore: HostScreenArmingStore, approvedStore: any ApprovedDeviceStoring) {
        self.armingStore = armingStore
        self.approvedStore = approvedStore
    }

    func attach(hostWindow: HostSetupWindowController, presence: HostMenuBarPresence) {
        self.hostWindow = hostWindow
        self.presence = presence
        refresh()
    }

    func refresh() {
        let arming = armingStore.load()
        let approvedDevices: [(publicKey: Data, name: String?, credentialStrength: HostScreenCredentialStrength?)] =
            approvedStore.load()
                .sorted { $0.base64EncodedString() < $1.base64EncodedString() }
                .map { key in
                    (
                        key,
                        approvedStore.name(for: key),
                        approvedStore.presenceCredential(for: key)?.strength
                    )
                }
        hostWindow?.updatePairedMachines(
            HostScreenArmingPresentation.pairedMachineRows(
                approvedDevices: approvedDevices,
                arming: arming,
                // `online()`, not `active()`: a row judges from every
                // display this machine has, so one merely asleep or mirrored is
                // counted and reported rather than silently dropped.
                activeDisplays: DisplayInventory.online()
            )
        )
        presence?.updateArming(HostScreenArmingPresentation.lines(for: arming))
    }

    /// One row's own Share host screen toggle. Arms or disarms exactly the
    /// device named, through the same `HostScreenDeviceArming.onPairing`
    /// builder `armOnPairing` below uses, so a person's own click and a
    /// fresh pairing record the credential strength the same way and cannot
    /// drift apart.
    ///
    /// `onPairing` returns `nil`, and this writes nothing, only when no
    /// credential is registered for this device at all -- unreachable in
    /// practice, since `PairedMachinesView`'s own toggle is already
    /// disabled until one exists (`HostScreenArmingPresentation.pairedMachineRows`'
    /// `blockedReason`).
    func toggle(devicePublicKey: Data, isOn: Bool) {
        if isOn {
            if let record = HostScreenDeviceArming.onPairing(
                devicePublicKey: devicePublicKey,
                approvedStore: approvedStore,
                now: Date()
            ) {
                armingStore.arm(record)
            }
        } else {
            armingStore.disarm(devicePublicKey: devicePublicKey)
        }
        refresh()
    }

    /// Arms a device the moment it pairs, when it registered a presence
    /// credential -- the owner's decision that pairing itself grants host
    /// screen, not a separate switch a person must find and flip. Called
    /// only for a key pairing for the first time
    /// (`PairingApproval.isNewDevice`); a device pairing again is never
    /// re-armed here, so re-pairing cannot undo the person at this machine
    /// having turned it off.
    func armOnPairing(devicePublicKey: Data) {
        guard let record = HostScreenDeviceArming.onPairing(
            devicePublicKey: devicePublicKey,
            approvedStore: approvedStore,
            now: Date()
        ) else {
            return
        }
        armingStore.arm(record)
    }

    func turnOff(devicePublicKey: Data) {
        armingStore.disarm(devicePublicKey: devicePublicKey)
        refresh()
    }

    /// The person arming this device's own choice, from the checkbox under
    /// its Share host screen toggle: whether this device's own session
    /// should still ask when this machine saw recent local input.
    func setAsksWhenInUse(devicePublicKey: Data, _ asksWhenInUse: Bool) {
        armingStore.setAsksWhenInUse(devicePublicKey: devicePublicKey, asksWhenInUse)
        refresh()
    }

    /// Removing a paired machine removes its host-screen arming with it.
    /// One call, not two left for a caller to remember to pair.
    func removePairedDevice(devicePublicKey: Data) {
        approvedStore.remove(devicePublicKey)
        armingStore.revoke(devicePublicKey: devicePublicKey)
        refresh()
    }
}

/// The running host's own pairing ceremony, filled in once hosting actually
/// starts. A box rather than a captured `var`: the reveal action closure is
/// built before hosting starts and must see this the moment it is set, not a
/// value frozen at capture time.
private final class PairingServiceBox: @unchecked Sendable {
    var service: HostPairingService?
}

@main
@MainActor
struct sensoriumd {

    /// The key that identifies this machine, read from its own file under
    /// Application Support, or generated there on a first run.
    private static func resolveIdentity() -> DeviceIdentity? {
        do {
            return try FileDeviceIdentityStore(url: identityFileURL()).loadOrCreate()
        } catch {
            print("This machine\u{2019}s identity unavailable at \(identityFileURL().path): \(IdentityFailureReason.describe(error)).")
            return nil
        }
    }

    private static func identityFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Sensorium", isDirectory: true)
            .appendingPathComponent("device-identity.json")
    }

    private static func approvedDevicesURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Sensorium", isDirectory: true)
            .appendingPathComponent("approved-devices.json")
    }

    private static func tlsIdentityFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Sensorium", isDirectory: true)
            .appendingPathComponent("host-tls-identity.json")
    }

    private static func hostScreenArmingFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Sensorium", isDirectory: true)
            .appendingPathComponent("host-screen-arming.json")
    }

    private static func hostScreenSessionLogFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("Sensorium", isDirectory: true)
            .appendingPathComponent("host-screen-sessions.log")
    }

    /// Read from its own file exactly as `resolveIdentity` is. Both failures
    /// reach the window as the one identity problem, whose "Try again" and
    /// "Make a new key" buttons cover this identity too.
    private static func resolveTLSIdentity() -> HostTLSIdentity? {
        do {
            return try FileHostTLSIdentityStore(url: tlsIdentityFileURL(), commonName: "Sensorium Host").loadOrCreate()
        } catch {
            print("Host TLS identity unavailable at \(tlsIdentityFileURL().path): \(IdentityFailureReason.describe(error)).")
            return nil
        }
    }

    /// The GUI's own default: the port the viewer's pairing form defaults to
    /// as well, so a first-time connection needs no port typed on either end.
    private static let defaultGUIPort: UInt16 = 7777

    /// Builds every object one hosting run needs and binds its listener, then
    /// returns -- it never blocks. Shared by the CLI `pair`/`serve` verbs and
    /// the GUI, which always launches as `serve` and reveals a pairing code
    /// later, on request, using the `HostPairingService` this returns.
    ///
    /// `onBindFailure` runs after the failure is already printed to stdout --
    /// every caller keeps that line -- and decides what happens next: the
    /// CLI still exits, the GUI reports the failure on screen and keeps
    /// running so the operator can fix it (free the port, check Tailscale)
    /// without relaunching.
    @discardableResult
    @MainActor
    private static func beginHosting(
        verb: String,
        tailnetAddress: String,
        port: UInt16,
        transport: HostTransportKind,
        tracePath: String?,
        operatorBox: HostOperatorBox,
        // Fires once a pairing is genuinely approved, after the approved
        // store already carries the new key, name, and presence
        // credential -- a safe point for a caller to reload anything it
        // shows of the paired-machines list, and to arm host screen at
        // once for a device pairing for the first time. The GUI path also
        // refreshes that list here; the CLI path only records the status
        // line, as there is no list to refresh and no arming coordinator.
        onDeviceApproved: @escaping (PairingApproval) -> Void,
        onBindFailure: @escaping @Sendable () -> Void = { Foundation.exit(1) },
        currentSession: HostLiveSessionSlot? = nil,
        // The GUI builds and reconciles its own, once, before this is
        // called, so the Host Setup window's "last session" read and the
        // accounting every host-screen connection does share the identical
        // store. `nil` only for the CLI `pair`/`serve` verbs, which have
        // nothing else to share it with: `beginHosting` builds and
        // reconciles one of its own instead, still exactly once, still
        // before any connection can be accepted.
        hostScreenSessionLog: HostScreenSessionLogStore? = nil
    ) throws -> HostPairingService {
        // Never asks macOS to present its approval UI. Approval is the
        // user's to give in System Settings; a host without it still serves
        // video and control, and refuses only input.
        var inputCapability = HostInputCapability.unavailableAccessibilityNotGranted
        if verb == "serve" {
            inputCapability = HostInputAvailability.resolve(gate: AccessibilityPermissionGate())
            if inputCapability == .unavailableAccessibilityNotGranted {
                print("Accessibility is not granted: this host will stream the virtual display but refuse typing and clicking.")
                print("No approval was requested and none will be. To enable input, approve this binary")
                print("yourself in System Settings > Privacy & Security > Accessibility, then run serve again.")
            }
            // A host running unattended on this machine must not fail silently
            // if macOS revokes an approval, or find one newly granted,
            // mid-run — see docs/macos-permissions.md. This never presents
            // UI; it only reports what `request-permissions` would already
            // show if asked again right now.
            let permissionMonitor = HostPermissionMonitor(
                screenCapture: ScreenCapturePermissionGate(),
                accessibility: AccessibilityPermissionGate(),
                onTransition: { transition in
                    print("Sensorium host: \(transition.logLine)")
                    operatorBox.status.apply(transition)
                }
            )
            Task { @MainActor in
                while true {
                    try? await Task.sleep(for: .seconds(HostPermissionMonitor.defaultPollIntervalSeconds))
                    permissionMonitor.poll()
                }
            }
        }
        // Told once, if this process ever loses the ability to capture
        // anything on this machine: the host window is where the person
        // standing at it learns that opening the app again is the only
        // remedy. Every connection's session and every canvas adapter this
        // process builds records into the same shared state.
        HostCaptureAvailability.shared.onBecomingUnavailable = { [operatorBox] in
            operatorBox.status.recordCaptureUnavailable()
        }
        // `resolveIdentity`/`resolveTLSIdentity` already printed the specific
        // reason; these carry no message of their own; see `HostStartupError`.
        guard let identity = resolveIdentity() else {
            throw HostStartupError.identityUnavailable
        }
        guard let tlsIdentity = resolveTLSIdentity() else {
            throw HostStartupError.tlsIdentityUnavailable
        }
        // Named so the presence-proof verifier below can be built over the
        // exact same store `pairing` writes a registered credential to --
        // the credential a device registered at pairing is the one checked
        // at admission, never a second, independently-opened view of the
        // same file that happened to read the same bytes.
        let approvedDeviceStore = FileApprovedDeviceStore(url: approvedDevicesURL())
        let pairing = HostPairingService(
            hostIdentity: identity,
            approvedStore: approvedDeviceStore,
            tlsCertificateHash: tlsIdentity.certificateHash,
            onDeviceApproved: onDeviceApproved
        )
        // Shared with the native workspace below: canvas ownership must
        // never change while that workspace's own placement is still
        // in flight. See `VirtualDisplaySession.start(owner:)`.
        let creationGate = CanvasCreationGate()
        // One display session per session canvas, keyed by surfaceID, all
        // sharing the one gate: the two canvases are created strictly one
        // after the other, each fully settled before the next begins.
        // One adapter per canvas, not one shared between them: the
        // adapter carries the surface's display identity, and two
        // canvases presenting the same identity give macOS nothing to
        // tell them apart.
        let sessions = CanvasSurfaceSlots { surface in
            VirtualDisplaySession(
                adapter: CoreGraphicsVirtualDisplayAdapter(
                    surface: surface,
                    shutdown: operatorBox.canvas,
                    log: { print("Sensorium host: \($0)") }
                ),
                creationGate: creationGate
            )
        }
        // Capture the physical topology before Sensorium creates anything.
        // The workspace uses this deny-list in addition to the owned handle
        // check, so an external monitor can never become its target --
        // taken once, here, before anything below can create a canvas of
        // its own.
        //
        // `online()`, not `active()`: a display asleep at the moment this
        // process starts (the host restarted overnight while a monitor
        // slept) is still present, and must still count as present.
        let physicalDisplayIDs = Set(DisplayInventory.online().map(\.id))
        // Measurement opt-in; unset, `serve` encodes at the canvas's
        // 1920x1200 logical size.
        let encoderConfiguration: VideoEncoderConfiguration =
            ProcessInfo.processInfo.environment["SENSORIUM_ENCODE_RESOLUTION"] == "3840x2400"
                ? .fullHiDPI
                : .remoteDefault
        // Boxed only so the existential can cross into `serveChannel`'s
        // `@Sendable` closure below; every actual use stays on the main
        // actor.
        //
        // One workspace instance per surface, so a second canvas's window
        // is a second window rather than a replacement for the first
        // canvas's; they still share the one creation gate.
        //
        // Built here rather than per connection, so every connection shares
        // these two: like the display sessions above, each identifies
        // itself to them with an owner token, and only the connection that
        // still owns a workspace can close its window.
        // Throughput-measurement opt-in only; unset, `serve` always presents
        // the real, static `NativeCanvasWorkspace`.
        let useAnimatedWorkspace = ProcessInfo.processInfo.environment["SENSORIUM_BENCH_ANIMATED_WORKSPACE"] == "1"
        let workspaceBox = HostWorkspaceBox(
            CanvasSurfaceSlots { _ -> any CanvasWorkspacePresenting in
                useAnimatedWorkspace
                    ? AnimatedMeasurementWorkspace(physicalDisplayIDs: physicalDisplayIDs, creationGate: creationGate)
                    : NativeCanvasWorkspace(physicalDisplayIDs: physicalDisplayIDs, creationGate: creationGate)
            }
        )
        // The host-screen stores: one arming store reading the same file the
        // Host Setup window's own arming coordinator writes, one resume-
        // ticket store held in memory for this process's whole life (never
        // persisted: it must not survive a restart), and this machine's own
        // local-input-idle signal.
        let hostScreenArmingStore = HostScreenArmingStore(url: hostScreenArmingFileURL())
        let hostScreenResumeTicketStore = HostScreenResumeTicketStore()
        // One wrong-guess budget for lock-screen unlock, shared across every
        // connection for the life of this process, so a reconnecting attacker
        // cannot reset it. In memory only: a host restart clears it and voids
        // every resume ticket anyway.
        let hostScreenUnlockThrottle = HostScreenUnlockThrottle()
        // One live host-screen session per device, across every connection: a
        // second concurrent one is refused rather than silently replacing the
        // first. In memory only, like the throttle -- a host restart starts it
        // empty, which is exactly right.
        let hostScreenLiveSessionRegistry = HostScreenLiveSessionRegistry()
        let hostScreenLocalActivitySignal = CoreGraphicsLocalActivitySignal()
        // The accountability record: who drove this machine's screen, which
        // display, and when. Reused from the caller when one was already
        // built and reconciled (the GUI); built and reconciled here,
        // exactly once, when it was not (the CLI verbs).
        let sessionLog: HostScreenSessionLogStore
        if let hostScreenSessionLog {
            sessionLog = hostScreenSessionLog
        } else {
            sessionLog = HostScreenSessionLogStore(url: hostScreenSessionLogFileURL())
            sessionLog.reconcileAbandonedSessionsAtLaunch()
        }
        // Checks a `.signed` proof against the credential registered for
        // this device at pairing, over the challenge this offer minted.
        let hostScreenPresenceProofVerifier: (any HostScreenPresenceProofVerifying)? =
            PresenceCredentialVerifier(approvedDeviceStore: approvedDeviceStore)
        // The ask-the-person-here gate, shared across every connection this
        // process serves -- there is one machine and one person at it to
        // ask, so the gate's own "never more than one at a time" has to
        // hold across connections, not just within one.
        let hostScreenPresenceGate = HostScreenPresenceGate(prompting: HostScreenPresencePanel())
        // The one display configuration Sensorium is allowed to do, and the
        // only object in this process that can do it: the mode of a display
        // a session is already streaming, at the viewer's request, put back
        // when that session ends. Shared across connections because it is
        // also what remembers the mode to put the display back to.
        let hostScreenModeController = CoreGraphicsHostScreenModeController()
        // Belt and braces over the session teardown that already restores:
        // a process that goes down without one still leaves this machine's
        // displays on the modes it found them on. Retrying, because the last
        // thing this process does is exactly when a display may still be
        // settling from a mode change, and there is no later attempt after
        // this one.
        operatorBox.shutdown.register { await hostScreenModeController.restoreEverythingRetrying() }
        // macOS draws nothing at all to a sleeping display, virtual displays
        // included, so a session that starts against a machine whose screens
        // have idled captures a picture that never arrives. This wakes them
        // at session start and keeps them awake while a session is live,
        // through public IOKit power management and nothing else. Shared
        // across connections: this machine has one power state.
        let displayWake = DisplayWakeController(log: { print("Sensorium host: \($0)") })
        // Belt and braces over the session teardown that already drops the
        // hold, exactly as the mode restore above is: a process that goes
        // down without one still leaves this machine idling its displays.
        operatorBox.shutdown.register { displayWake.releaseEveryHold() }
        // One controller per connection: authentication must never outlive
        // the connection that earned it.
        let sessionFactory = HostConnectionSessionFactory(
            sessions: sessions,
            requireAuthentication: true,
            inputInjectorFactory: inputCapability == .available
                ? CoreGraphicsInputInjectorFactory()
                : nil,
            pairing: pairing,
            onPairingRequested: { deviceName in
                operatorBox.status.recordPairingRequest(deviceName: deviceName) {
                    let code = pairing.issueCode()
                    return (code, Date().addingTimeInterval(PairingAuthority.defaultLifetime))
                }
            },
            // The same two workspaces the coordinator places windows on:
            // a key event carries no location, so the controller confines
            // it to the addressed surface's canvas before posting it --
            // to that surface's own window, or, through the scan, to an
            // application the launcher put onto that canvas. The scan is
            // a WindowServer query and needs no Accessibility grant, so a
            // host that has lost Accessibility stops being able to move
            // new windows onto the canvas but keeps typing into the ones
            // already there.
            keyConfinement: .confined(
                to: workspaceBox.workspaces,
                scanning: CoreGraphicsFrontmostWindowScan()
            ),
            // The display count is a viewer-side choice; until it is
            // wired, this host serves every canvas it can address.
            maxSurfaceCount: CanvasSurfaceID.capacity,
            hostScreenArmingProvider: { hostScreenArmingStore.load() },
            hostScreenPresenceProofVerifier: hostScreenPresenceProofVerifier,
            hostScreenResumeTicketStore: hostScreenResumeTicketStore,
            hostScreenUnlockThrottle: hostScreenUnlockThrottle,
            hostScreenLiveSessionRegistry: hostScreenLiveSessionRegistry,
            hostScreenLocalActivitySignal: hostScreenLocalActivitySignal,
            hostScreenPresenceGate: hostScreenPresenceGate,
            hostScreenModeController: hostScreenModeController,
            displayWake: displayWake
        )

        if verb == "pair" {
            let code = pairing.issueCode()
            // The launchers run this under `open`, where stdout reaches
            // nobody unless it is redirected; the menu-bar item is where
            // the operator actually reads the code and its countdown.
            operatorBox.status.showPairingCode(
                code,
                expiresAt: Date().addingTimeInterval(PairingAuthority.defaultLifetime)
            )
            print("Pairing code: \(code)")
            print("It is valid for \(Int(PairingAuthority.defaultLifetime / 60)) minutes and approves exactly one machine.")
        }

        // Created once and appended to across connections, mirroring the
        // viewer's trace writer: a mistyped path fails loudly instead of
        // scattering files.
        let hostTrace: LatencyTraceWriter?
        if let tracePath {
            hostTrace = try LatencyTraceWriter(url: URL(fileURLWithPath: tracePath), sessionLabel: tailnetAddress)
            print("Host latency trace: \(tracePath)")
        } else {
            hostTrace = nil
        }

        let serveChannel: @Sendable (any HostByteChannel) -> Void = { channel in
            Task { @MainActor in
                // Filled in below, once `controller` itself exists to be
                // captured by `isSessionAdmissible` -- `onClipboardSharingChanged`
                // only ever fires later, once a wire message actually
                // arrives, so the box only needs to hold a real session by
                // the time that happens, not at construction.
                let clipboardBox = ClipboardSessionBox()
                let controller = sessionFactory.makeController(
                    onClipboardSharingChanged: { enabled in clipboardBox.session?.setEnabled(enabled) }
                )
                // One recorder per connection: it is fed from the encoder's
                // callback thread and the transport's send-completion task,
                // both of which outlive any single message handler.
                let latencyRecorder = HostMediaLatencyRecorder()
                // One focus state per connection, shared by both media
                // pipelines and the coordinator: which canvas the viewer
                // is looking at is a property of this session, and a new
                // connection must start with none.
                let focus = CanvasFocusTracker()
                // One clipboard per connection, gated on that
                // connection's own authentication and active canvas: the
                // right to write this machine's pasteboard must not outlive
                // the session that earned it.
                let clipboard = ClipboardSyncSession(
                    engine: ClipboardSyncEngine(
                        pasteboard: SystemPasteboard(),
                        isEnabled: ClipboardSyncEngine.sharingEnabledByDefault
                    ),
                    isSessionAdmissible: { controller.isSessionAuthenticatedAndActive },
                    log: { print("Sensorium host: \($0)") }
                )
                clipboardBox.session = clipboard
                // Dropped as soon as this session ends on its own, so a
                // day of reconnects cannot pile up quit teardowns for
                // sessions long gone. Filled in below, once there is a
                // coordinator and a session to tear down.
                let quit = QuitRegistrationBox()
                let peerLog = PeerLogBox()
                // This connection's own session, named so that the end of
                // this connection can be told apart from the end of any
                // other. Filled in below, from the same `let` that fills
                // the process-wide slot: the presence callback is built as
                // part of constructing the session it reports on, so it has
                // no way to name that session directly.
                let thisConnection = HostLiveSessionSlot()
                // The same connection, named for the operator status, which
                // has its own reason to tell one connection's close from
                // another's: a close from a connection already replaced must
                // not take the live session's own headline and Stop control
                // off the window.
                let connectionToken = HostConnectionToken()
                let session = HostNetworkSession(
                    connection: channel,
                    controller: controller,
                    latencyRecorder: latencyRecorder,
                    clipboard: clipboard,
                    onEvent: { print("Sensorium host: \($0)") },
                    // Who is on this machine, for the menu bar. The name
                    // arrives on the wire.
                    onPeerPresence: { peer in
                        Task { @MainActor in
                            // The terminal is the record of what happened
                            // while nobody was at this machine; the menu bar
                            // below only shows what is happening now.
                            if let line = peerLog.log.line(for: peer) {
                                print("Sensorium host: \(line)")
                            }
                            operatorBox.status.apply(peer, from: connectionToken)
                            if case .closed = peer {
                                currentSession?.release(thisConnection.session)
                                if let ticket = quit.ticket {
                                    operatorBox.shutdown.deregister(ticket)
                                }
                            }
                        }
                    }
                )
                thisConnection.session = session
                currentSession?.session = session
                // Structural invariant: this is the only way
                // `HostSessionCoordinator` below can ever obtain a working
                // host-screen media object, and `makeMedia` cannot return
                // one without a log record and a visible badge already
                // existing. `deviceName`/`displayLabel` read the arming
                // record's own name -- `controller.hostScreenDeviceName`/
                // `hostScreenDisplayLabel` -- never the wire's own claim,
                // and are only readable once a request has actually been
                // admitted, which is also the earliest `makeMedia` can run.
                let hostScreenAccountableMedia = HostScreenAccountableMedia(
                    rawFactory: { configuration, sequencer in
                        HostScreenCaptureMedia(
                            configuration: configuration,
                            latencyRecorder: latencyRecorder,
                            focus: focus,
                            admissionGate: controller.encodeAdmission,
                            sequencer: sequencer,
                            log: { print("Sensorium host: \($0)") }
                        )
                    },
                    sessionLog: sessionLog,
                    deviceName: { controller.hostScreenDeviceName ?? "" },
                    displayLabel: { controller.hostScreenDisplayLabel ?? "" },
                    // The badge's own Stop control ends the same session
                    // the window's and menu bar's Stop controls already do.
                    onBadgeStop: { [weak session] in session?.stop() }
                )
                let coordinator = HostSessionCoordinator(
                    controller: controller,
                    // One capture-and-encode pipeline per surface: a
                    // viewer resize on one canvas must rebuild only that
                    // canvas's encoder.
                    media: CanvasSurfaceSlots { surface in
                        ScreenCaptureCanvasMedia(
                            surface: surface,
                            configuration: encoderConfiguration,
                            latencyRecorder: latencyRecorder,
                            focus: focus,
                            // This connection's own encode-admission
                            // gate, from the one object whose lifetime is
                            // exactly this session. Both canvases share
                            // it; the machine's media-engine bound below
                            // it is what the two canvases of *another*
                            // session contend with.
                            admissionGate: controller.encodeAdmission,
                            log: { print("Sensorium host: \($0)") }
                        )
                    },
                    videoSink: session,
                    workspaces: workspaceBox.workspaces,
                    focus: focus,
                    // The same recorder both media pipelines write into:
                    // adaptive fidelity is decided from what this session
                    // actually measured, never from a static guess.
                    latencyRecorder: latencyRecorder,
                    onEvent: { print("Sensorium host: \($0)") },
                    onSessionEnded: {
                        if let summary = HostLatencySummary.line(
                            metrics: latencyRecorder.metrics,
                            droppedFrameCount: session.droppedVideoFrameCount,
                            frameCounts: latencyRecorder.frameCounts
                        ) {
                            print("Sensorium host: \(summary)")
                        }
                        try? hostTrace?.write(latencyRecorder.metrics)
                    },
                    // Drop the connection rather than leave the viewer
                    // looking at a picture that stopped updating; its
                    // reconnect driver then brings a working stream back.
                    onStreamUnrecoverable: { [weak session] reason in
                        print("Sensorium host: ending session: \(reason)")
                        session?.stop()
                    },
                    hostScreenMediaFactory: hostScreenAccountableMedia.makeMedia
                )
                session.attach(coordinator: coordinator)
                // Quitting from the menu bar ends a live session the same
                // way the transport dying ends one: the coordinator takes
                // every workspace window down before any canvas display is
                // released. Awaited to completion before the process ends,
                // which is the whole reason this is not an `exit()`.
                quit.ticket = operatorBox.shutdown.register { [weak session] in
                    await coordinator.sessionDidEnd(reason: "host-quit")
                    session?.stop()
                }
                session.start()
            }
        }

        switch transport {
        case .tcpLocalVerification:
            // NWListener cannot serve accepted connections when it pins its
            // local endpoint on this OS build, so the verification
            // transport binds the tailnet address with BSD sockets.
            print("Transport: TCP local-verification mode. Sessions stay Ed25519-authenticated; TLS is absent.")
            let listener = try PosixTailnetListener(tailnetAddress: tailnetAddress, port: port)
            print("Sensorium host bound \(listener.boundAddress):\(listener.boundPort); tailnet sources only")
            // Registered before any session, and teardowns run in
            // registration order: a quit stops accepting first, so no
            // connection can arrive while the live ones are coming down.
            operatorBox.shutdown.register { listener.stop() }
            // The same for both verbs: a code already on screen is a
            // separate fact from what this listener is doing, so reporting
            // the bound address cannot disturb it.
            operatorBox.status.recordHostedAddress(tailnetAddress)
            operatorBox.status.setConnection(.hosting(address: tailnetAddress))
            listener.start { channel in
                serveChannel(channel)
            }
        case .quic, .quicLocalVerification:
            if transport == .quicLocalVerification {
                print("Transport: QUIC local-verification mode. Loopback sources admitted; LAN still refused.")
            }
            let listener = try HostNetworkListener(
                tailnetAddress: tailnetAddress,
                port: port,
                tlsIdentity: tlsIdentity,
                transport: transport
            )
            listener.start { state in
                switch state {
                case let .ready(boundPort):
                    print("Sensorium host bound \(tailnetAddress):\(boundPort); tailnet sources only")
                    Task { @MainActor in
                        operatorBox.status.recordHostedAddress(tailnetAddress)
                        operatorBox.status.setConnection(.hosting(address: tailnetAddress))
                    }
                case let .failed(reason):
                    print("Sensorium host could not bind \(tailnetAddress):\(port): \(reason)")
                    Task { @MainActor in
                        operatorBox.status.reportProblem("Could not start hosting on \(tailnetAddress): \(reason)")
                        onBindFailure()
                    }
                case .cancelled:
                    print("Sensorium host listener canceled")
                case let .refusedSource(address):
                    print("Sensorium host: \(HostOperatorLog.sourceRefused(address: address))")
                }
            } onConnection: { connection in
                serveChannel(NWByteChannel(connection: connection))
            }
            operatorBox.shutdown.register { listener.stop() }
        }
        return pairing
    }

    /// Kept for the life of the process: a signal source that is released
    /// stops delivering, and `NSApplication` does not keep its delegate alive.
    private static var terminationSignalSources: [any DispatchSourceSignal] = []
    private static var applicationDelegate: HostApplicationDelegate?

    /// Ends the process the way a quit does when something else asks it to
    /// stop: `SIGTERM` from a system shutdown or a `kill`, `SIGINT` from a
    /// terminal. Without this the process dies where it stands and every
    /// canvas display it created stays online, with no owner and no way to
    /// remove it, until the machine restarts.
    ///
    /// The default disposition ends the process before any handler could run,
    /// so it is turned off first; the source then delivers on the main queue,
    /// where releasing a display is allowed. Everything the handler does is
    /// synchronous, because a signal handler has no opportunity to await
    /// anything before the process ends.
    @MainActor
    private static func installTerminationSignalHandlers(
        _ onTerminate: @escaping @MainActor () -> Void
    ) {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated { onTerminate() }
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    /// The no-argument launch: double-clicking `Sensorium Host.app`. The whole
    /// interaction is opening it -- no address to pick or type, this machine's
    /// own tailnet address is auto-detected silently. It waits for a
    /// connection and reveals a pairing code only when asked. See
    /// `TailnetAddressEnumerator.autoSelect` for what "silently" refuses to
    /// guess, and `HostSetupWindowController` for the one window this is.
    @MainActor
    private static func runGUI() {
        let operatorBox = HostOperatorBox(
            status: HostOperatorStatusStore(
                permissions: HostPermissionRequestResult(
                    screenCapture: ScreenCapturePermissionGate().currentStatus,
                    accessibility: AccessibilityPermissionGate().currentStatus
                )
            ),
            shutdown: HostShutdownRegistry(),
            canvas: CanvasShutdown()
        )
        // The one live connection's session, so the window and menu bar's
        // Stop control can end it -- filled in once `beginHosting` accepts
        // a connection, the same lazily-filled shape `pairing` below uses.
        let currentSession = HostLiveSessionSlot()
        // Filled in once hosting actually starts, so the reveal action below
        // has a running pairing ceremony's own service to issue a code from.
        // `nil` the whole run only when auto-detection itself failed.
        let pairing = PairingServiceBox()

        let application = NSApplication.shared
        // A status item is visible under `.accessory`, so this app never
        // takes a Dock icon or focus from whatever the operator is doing --
        // the host window still activates the app for itself when shown.
        application.setActivationPolicy(.accessory)

        let armingCoordinator = HostScreenArmingCoordinator(
            armingStore: HostScreenArmingStore(url: hostScreenArmingFileURL()),
            approvedStore: FileApprovedDeviceStore(url: approvedDevicesURL())
        )
        // A confirmation before either destructive action -- un-pairing and
        // revoking host-screen sharing are both hard to walk back from a
        // click meant for something else.
        func confirmAndRemovePairedDevice(devicePublicKey: Data) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Remove this paired machine?"
            alert.informativeText = "It will need to pair again to reconnect. Any host-screen sharing armed for it "
                + "is removed immediately."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                armingCoordinator.removePairedDevice(devicePublicKey: devicePublicKey)
            }
        }
        // The one store this process writes host-screen records to, reused
        // by `beginHosting`. Reconciled here, before any session of this
        // process can start, so anything still open belongs to a host that
        // is gone.
        let sessionLog = HostScreenSessionLogStore(url: hostScreenSessionLogFileURL())
        sessionLog.reconcileAbandonedSessionsAtLaunch()

        // A machine that cannot create a canvas, find its tailnet address,
        // or read its identity must say so on screen instead of listening.
        // Called at launch and after an identity replacement, so both paths
        // start hosting the same way.
        func startHosting() {
            switch HostVirtualDisplayCapability.probe(
                log: { print("Sensorium host: \($0)") },
                shutdown: operatorBox.canvas
            ) {
            case .supported:
                switch TailnetAddressEnumerator.autoSelect() {
                case let .single(address):
                    do {
                        pairing.service = try beginHosting(
                            verb: "serve",
                            tailnetAddress: address,
                            port: defaultGUIPort,
                            transport: .quic,
                            tracePath: nil,
                            operatorBox: operatorBox,
                            // A device pairing for the first time is armed
                            // for host screen at once, if it registered a
                            // presence credential; a device pairing again is
                            // not -- that would undo an earlier "turn off"
                            // for it.
                            onDeviceApproved: { approval in
                                operatorBox.status.recordPairingApproved(deviceName: approval.deviceName)
                                if approval.isNewDevice {
                                    armingCoordinator.armOnPairing(devicePublicKey: approval.devicePublicKey)
                                }
                                armingCoordinator.refresh()
                            },
                            // A bind failure is already reported to `operatorBox.status`
                            // by `beginHosting` itself; the GUI's whole point is to
                            // keep running so the operator can read why and act,
                            // never to disappear the moment something goes wrong.
                            onBindFailure: {},
                            currentSession: currentSession,
                            hostScreenSessionLog: sessionLog
                        )
                    } catch is HostStartupError {
                        print("Sensorium host failed to start: the file holding this machine\u{2019}s own key could not be read.")
                        operatorBox.status.reportIdentityProblem(.cannotReadKey)
                    } catch {
                        print("Sensorium host failed to start: \(error)")
                        operatorBox.status.reportProblem("Sensorium Host could not start hosting: \(HostOperatorLog.describe(error))")
                    }
                case .none:
                    operatorBox.status.reportProblem(HostStartupProblemCopy.noTailnetAddress)
                }
            case let .unsupported(reason):
                print("Sensorium host: \(reason)")
                operatorBox.status.reportProblem(reason)
            }
        }

        let hostWindow = HostSetupWindowController(
            status: operatorBox.status.status,
            onRevealPairingCode: {
                guard let service = pairing.service else { return }
                let code = service.issueCode()
                // The launchers run this under `open`, where stdout reaches
                // nobody unless it is redirected; the window and the
                // menu-bar item are where the operator actually reads it.
                operatorBox.status.showPairingCode(
                    code,
                    expiresAt: Date().addingTimeInterval(PairingAuthority.defaultLifetime)
                )
                print("Pairing code: \(code)")
                print("It is valid for \(Int(PairingAuthority.defaultLifetime / 60)) minutes and approves exactly one machine.")
            },
            onStop: { currentSession.session?.stop() },
            onHidePairingCode: { operatorBox.status.hidePairingCode() },
            onReplaceIdentity: {
                let copy = HostIdentityFailureCopy.cannotReadKey
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = copy.headline
                alert.informativeText = copy.replaceConsequence
                alert.addButton(withTitle: "Make a new key")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }

                // Both keys are minted before either file is written, so a
                // failure partway leaves this machine with the pair it
                // already had rather than one new key and one old.
                switch HostIdentityRecovery.replaceIdentities(
                    device: FileDeviceIdentityStore(url: identityFileURL()),
                    tls: FileHostTLSIdentityStore(url: tlsIdentityFileURL(), commonName: "Sensorium Host")
                ) {
                case .replaced:
                    operatorBox.status.clearIdentityProblem()
                    startHosting()
                case let .deviceIdentityFailed(reason):
                    operatorBox.status.reportProblem("Sensorium Host could not replace this machine\u{2019}s device identity: \(reason).")
                case let .hostTLSIdentityFailed(reason):
                    operatorBox.status.reportProblem("Sensorium Host could not replace this machine\u{2019}s TLS identity: \(reason).")
                }
            },
            // "Try again": repeats the read this process already made once,
            // at launch or at the last press of this same button. The read
            // comes first, so a key still unreadable says so again rather
            // than reaching the canvas probe and reporting whatever that
            // finds instead.
            onRetryIdentityRead: {
                guard resolveIdentity() != nil, resolveTLSIdentity() != nil else {
                    operatorBox.status.reportIdentityProblem(.cannotReadKey)
                    return
                }
                operatorBox.status.clearIdentityProblem()
                startHosting()
            },
            onToggleSharing: { key, isOn in armingCoordinator.toggle(devicePublicKey: key, isOn: isOn) },
            onRemovePairedDevice: { key in confirmAndRemovePairedDevice(devicePublicKey: key) },
            onToggleAskFirst: { key, isOn in armingCoordinator.setAsksWhenInUse(devicePublicKey: key, isOn) }
        )
        // Every way of quitting goes through the one delegate below, so none
        // of them can end the process with a canvas still online.
        let presence = HostMenuBarPresence(
            status: operatorBox.status.status,
            openSetup: { hostWindow.show() },
            onStop: { currentSession.session?.stop() },
            onTurnOffSharing: { key in armingCoordinator.turnOff(devicePublicKey: key) },
            quit: { application.terminate(nil) }
        )
        applicationDelegate = HostApplicationDelegate(
            teardown: {
                await operatorBox.shutdown.shutDown()
                operatorBox.canvas.releaseEverything()
            },
            forceRelease: {
                operatorBox.canvas.releaseEverything()
            }
        )
        application.delegate = applicationDelegate
        installTerminationSignalHandlers {
            print("Sensorium host: stopping, and releasing every virtual display this host created")
            currentSession.session?.stop()
            operatorBox.canvas.releaseEverything()
            Foundation.exit(0)
        }
        operatorBox.status.onChange = { [weak presence] status in
            presence?.update(status)
        }
        operatorBox.status.addObserver { [weak hostWindow] status in
            hostWindow?.update(status)
        }
        presence.install()
        armingCoordinator.attach(hostWindow: hostWindow, presence: presence)
        // The window's own line is still read once, here, and not observed
        // live: nothing yet re-reads it once this process begins recording
        // its own sessions, so it keeps showing the last *previous* run's
        // session until this window is reopened.
        hostWindow.updateLastHostScreenSession(HostScreenSessionLogPresentation.line(for: sessionLog.lastRecord))
        // "Open app -> wait for connection" is the entire flow: the window
        // is not something the operator opens, it is what opening the app
        // is.
        hostWindow.show()

        startHosting()

        application.run()
    }

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["request-permissions"] {
            let result = HostPermissionRequester.request()
            let launchContext = SystemTerminalLaunchDetector().launchContext
            for line in HostPermissionReport.lines(result: result, launchContext: launchContext) {
                print(line)
            }
            Foundation.exit(result.isReadyForViewerControl ? 0 : 3)
        }
        if arguments.isEmpty {
            runGUI()
            return
        }
        var transport = HostTransportKind.quic
        if let flag = arguments.firstIndex(of: "--transport"), arguments.index(after: flag) < arguments.endIndex {
            let rawKind = arguments[arguments.index(after: flag)]
            let normalized = rawKind == "tcp-local-verification" ? "tcpLocalVerification"
                : rawKind == "quic-local-verification" ? "quicLocalVerification"
                : rawKind
            guard let kind = HostTransportKind(rawValue: normalized) else {
                print("usage: --transport <quic|tcp-local-verification|quic-local-verification>")
                Foundation.exit(2)
            }
            transport = kind
            arguments.removeSubrange(flag...arguments.index(after: flag))
        }
        var tracePath: String?
        if let flag = arguments.firstIndex(of: "--trace"), arguments.index(after: flag) < arguments.endIndex {
            tracePath = arguments[arguments.index(after: flag)]
            arguments.removeSubrange(flag...arguments.index(after: flag))
        }
        guard arguments.count == 3,
              let rawPort = UInt16(arguments[2]),
              ["pair", "serve"].contains(arguments[0]) else {
            print("usage: sensoriumd request-permissions")
            print("   or: sensoriumd <pair|serve> <tailnet-address> <port> [--trace <path.jsonl>]")
            print("  the tailnet address is this machine\u{2019}s own: tailscale ip -4")
            Foundation.exit(2)
        }
        let tailnetAddress = arguments[1]

        do {
            // What the person standing at this machine reads off the menu bar.
            // Built before anything else that can change it -- the permission
            // monitor, the pairing ceremony, and every connection report into
            // this one store. Both status reads are preflights: neither asks
            // macOS to present an approval prompt.
            let operatorBox = HostOperatorBox(
                status: HostOperatorStatusStore(permissions: HostPermissionRequestResult(
                    screenCapture: ScreenCapturePermissionGate().currentStatus,
                    accessibility: AccessibilityPermissionGate().currentStatus
                )),
                shutdown: HostShutdownRegistry(),
                canvas: CanvasShutdown()
            )
            let currentSession = HostLiveSessionSlot()
            try beginHosting(
                verb: arguments[0],
                tailnetAddress: tailnetAddress,
                port: rawPort,
                transport: transport,
                tracePath: tracePath,
                operatorBox: operatorBox,
                onDeviceApproved: { approval in
                    operatorBox.status.recordPairingApproved(deviceName: approval.deviceName)
                },
                currentSession: currentSession
            )
            // Only `serve` opens the session workspace window, so only `serve`
            // needs AppKit's real event loop to deliver keyboard/pointer
            // events to it. `pair` still services a listener forever, but
            // stays headless: no event loop, no Dock icon. Both loops run on
            // this thread, which is already macOS's actual main thread, and
            // both keep servicing Network.framework's own queues and any
            // @MainActor `Task` the listener callbacks schedule.
            let application = NSApplication.shared
            // Idle until a viewer's canvas request opens the workspace;
            // `NativeCanvasWorkspace` flips this to `.regular` on start and
            // back to `.accessory` on stop. A status item is visible under
            // `.accessory`, so the menu-bar presence below adds no Dock icon
            // and takes no focus from the operator's own work.
            application.setActivationPolicy(.accessory)
            let presence = HostMenuBarPresence(
                status: operatorBox.status.status,
                quit: { application.terminate(nil) }
            )
            applicationDelegate = HostApplicationDelegate(
                teardown: {
                    await operatorBox.shutdown.shutDown()
                    operatorBox.canvas.releaseEverything()
                },
                forceRelease: {
                    operatorBox.canvas.releaseEverything()
                }
            )
            application.delegate = applicationDelegate
            // Safe though `beginHosting` above already ran: nothing between
            // its return and `application.run()` below ever awaits, so the
            // main actor cannot run a canvas-creating task queued during
            // `beginHosting` until these handlers are already installed.
            installTerminationSignalHandlers {
                print("Sensorium host: stopping, and releasing every virtual display this host created")
                currentSession.session?.stop()
                operatorBox.canvas.releaseEverything()
                Foundation.exit(0)
            }
            operatorBox.status.onChange = { [weak presence] status in
                presence?.update(status)
            }
            presence.install()
            // Every verb needs this event loop, workspace window or not: the
            // menu-bar item is where its code is readable at this machine,
            // and tracking that item's menu is AppKit event dispatch. This
            // loop also services Network.framework's queues and every
            // @MainActor `Task` the listener schedules.
            application.run()
        } catch is HostStartupError {
            // `resolveIdentity`/`resolveTLSIdentity` already printed the
            // specific reason; nothing more to say before exiting.
            Foundation.exit(1)
        } catch {
            print("Sensorium host failed to start: \(error)")
            Foundation.exit(1)
        }
    }
}

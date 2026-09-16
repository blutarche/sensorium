import CoreMedia
import Foundation
import Security
import SensoriumCore

struct CanvasInputLocation: Equatable {
    let x: Double
    let y: Double
}

@MainActor
public enum HostSessionControllerError: Error, Equatable {
    case invalidCanvasRequest
    case unexpectedMessage
    case invalidAuthentication
    case authenticationRequired
    case inputSessionUnavailable
    case inputInjectionUnavailable
    case invalidInput
    case deviceNotPaired
    case invalidViewerDrawableSize
    case invalidViewerFocus
    case invalidStreamScalePreference
    /// This connection has burned `HostSessionController.maximumPairingFailuresPerConnection`
    /// wrong-code guesses. Distinct from `PairingError.codeAttemptsExhausted`,
    /// which retires the *code*: this ends only the *connection* that did the
    /// guessing, so a scripted attacker pays a fresh handshake per batch of
    /// guesses instead of guessing forever on one open socket.
    case pairingConnectionFailuresExceeded
    /// A second `.hello` or `.authenticatedHello` arrived on a connection
    /// already authenticated. A connection is one shape for its whole life,
    /// and the viewer always opens a fresh connection to change target --
    /// a repeat hello is a protocol violation, not a way to refresh this
    /// connection's own tokens and presence challenge.
    case helloAlreadyAccepted
}

extension HostSessionControllerError {
    /// Whether the session must end. Only errors that say the viewer is not who it
    /// claims are fatal: dropping a session because one pointer event landed a
    /// pixel outside the canvas is a bug, not a defence.
    public nonisolated var isSessionFatal: Bool {
        switch self {
        case .authenticationRequired, .invalidAuthentication, .deviceNotPaired, .unexpectedMessage,
             .pairingConnectionFailuresExceeded, .helloAlreadyAccepted:
            true
        case .invalidCanvasRequest, .invalidInput, .inputSessionUnavailable, .inputInjectionUnavailable,
             .invalidViewerDrawableSize, .invalidViewerFocus, .invalidStreamScalePreference:
            false
        }
    }
}

/// Everything the host keys by surfaceID for the life of one connection.
/// Both slots exist before any viewer message arrives, so no message can
/// create a third.
private struct SurfaceState {
    var inputInjector: (any InputInjecting)?
    /// The canvas this connection actually created for this surface, and the
    /// only thing input for it is bounded against. Bounding against a
    /// compiled-in default instead would turn every event legitimately inside
    /// a differently sized canvas into a non-fatal `invalidInput`, which is
    /// dropped silently.
    var canvas: VirtualCanvasConfiguration?
    var heldButtons: [CanvasPointerButton: CanvasInputLocation] = [:]
    var heldKeys: Set<UInt16> = []
    /// Whether this connection last told the host it has hidden its cursor
    /// and switched to relative motion. Tracked so a session that drops while
    /// captured can be uncaptured on teardown, the same way a held button or
    /// key is released rather than left stuck.
    var isPointerCaptured = false
    /// The stream scale this surface's viewer most recently asked for. `nil`
    /// until one arrives.
    var requestedStreamScale: Double?
    /// The viewer's own cap on the streamed scale, from the same message.
    /// `nil` is no cap, which is what a viewer that predates the field and a
    /// viewer that wants none both send.
    var requestedMaximumStreamScale: Double?
    /// This surface's viewer's own choice of stream scale -- `.automatic`
    /// until a `streamScalePreference` message says otherwise.
    var streamScalePreference: StreamScalePreference = .automatic
}

/// Which of the two mutually exclusive kinds of session this connection has
/// become -- see `HostSessionController.connectionShape`.
private enum ConnectionShape: Equatable {
    case canvas
    case hostScreen
}

/// Everything this connection holds for a live host-screen session -- there
/// is only ever one, never a slot per `CanvasSurfaceID`: one display per
/// session. `displayID` is the real, live
/// `CGDirectDisplayID` `HostScreenSelectionGuard` admitted, kept here so
/// input bounds and any later teardown act on the exact display that was
/// actually resolved, not a value re-derived from a token that may no
/// longer resolve the same way.
private struct HostScreenSurfaceState {
    var geometry: SessionSurfaceGeometry
    var displayID: UInt32
    /// The verified device identity this session was admitted for, and the
    /// arming record it was admitted under -- together the key the unlock
    /// budget is charged against, so every connection this device opens spends
    /// one shared count rather than a fresh one per reconnect.
    var devicePublicKey: Data
    var armingFingerprint: HostScreenArmingFingerprint
    /// The arming record's own name for this device -- what the operator
    /// typed or confirmed while arming, not the name an
    /// `authenticatedHello` merely claims. What the badge names is this,
    /// not the wire's own unverified claim.
    var deviceName: String
    /// `HostScreenArmingPresentation.displayLabel(for:)`'s own words for
    /// the real display this surface was admitted for -- the same label
    /// `hostScreenList` already offered it under.
    var displayLabel: String
    var inputInjector: (any InputInjecting)?
    /// The mode this display was on before this session's first successful
    /// change, and `nil` while it has made none. What the session's end
    /// puts back, and the only mode it ever puts back however many changes
    /// the viewer asked for in between.
    var modeBeforeFirstChange: HostScreenModeEntry?
    var heldButtons: [CanvasPointerButton: CanvasInputLocation] = [:]
    var heldKeys: Set<UInt16> = []
    var isPointerCaptured = false
}

/// Where a *canvas* connection's key events are allowed to land.
///
/// A key event carries no location, so macOS delivers it to whatever holds
/// this machine's one process-wide keyboard focus. Confining it to the addressed
/// surface's own workspace window is the only thing that keeps it inside the
/// canvas, so the choice is a required argument with no default: a caller that
/// wants no confinement has to name `unconfined`, and a caller that forgets
/// does not get it by omission.
///
/// It says nothing about a host-screen connection, which owns no window to be
/// confined to and posts its keys wherever the host's own focus is. One host
/// serves both kinds of connection
/// from one wired value, so what a connection may do with a key follows from
/// its own shape, not from this -- see
/// `HostSessionController.mayPostHostScreen(key:isDown:)`.
public enum HostKeyConfinement {
    /// Post a key only where this connection's own canvas is: into the
    /// addressed surface's workspace window, or into an application whose
    /// windows the scan finds standing wholly on that surface's canvas.
    /// A key that can be confined to neither is dropped. What `sensoriumd`
    /// wires, for every connection it serves.
    case confined(to: CanvasSurfaceSlots<any CanvasWorkspacePresenting>, scanning: any FrontmostWindowScanning)
    /// Post keys wherever this machine's keyboard focus already is. Only for
    /// callers that present no workspace window at all -- protocol and media
    /// tests -- and never for a connection serving a real viewer.
    case unconfined
    /// A host-screen connection: the same behaviour as `.unconfined` for
    /// canvas keys it will never send, kept as its own case for readability.
    case hostScreen

    /// Confinement with no window scan, which is the strictest form: only this
    /// connection's own workspace window can take a key, never an application
    /// launched onto its canvas. The default for callers that launch nothing,
    /// and the safe answer for a caller that forgot to state a scanner -- it
    /// costs typing into launched applications, never a key on a physical
    /// display.
    @MainActor
    public static func confined(
        to workspaces: CanvasSurfaceSlots<any CanvasWorkspacePresenting>
    ) -> HostKeyConfinement {
        .confined(to: workspaces, scanning: NoFrontmostWindowScan())
    }
}

/// A claim on one unlock guess slot, naming the exact budget key it charged.
/// Minted only by `HostSessionController.tryReserveUnlockAttempt` and handed
/// back to `refund` or `recordUnlockSuccess`, so the slot is released against
/// the key it was taken from rather than whatever the connection's surface
/// happens to name after the attempt -- the surface may have been torn down or
/// re-armed while the multi-second unlock was in flight. Opaque to callers:
/// they hold it and return it, never read it.
public struct UnlockReservation {
    let devicePublicKey: Data
    let armingFingerprint: HostScreenArmingFingerprint
}

@MainActor
public final class HostSessionController {
    private let sessions: CanvasSurfaceSlots<VirtualDisplaySession>
    private let approvedPublicKeys: Set<Data>
    private let requireAuthentication: Bool
    private let inputInjectorFactory: (any InputInjectingFactory)?
    /// Where this connection's key events may land. Stated by every caller.
    private let keyConfinement: HostKeyConfinement
    private var isAuthenticated = false
    private var authenticatedClientKey: Data?
    private var surfaces: CanvasSurfaceSlots<SurfaceState>
    /// This connection's read-only view of arming: no mutating API to the
    /// session controller. `nil` means host screen is simply unavailable
    /// through this controller -- every test that does not care about it
    /// never needs to supply one.
    private let hostScreenArmingProvider: (() -> HostScreenArming)?
    /// A live display read, injected so a test can hand this controller a
    /// display without a real one to match against -- unlike arming and
    /// the verifier, there is no honest reason for this to default to
    /// "nothing", so it defaults to the real `DisplayInventory.online`.
    /// `online`, not `active`: a display asleep at the moment of an offer
    /// must still be seen and named, not silently treated as gone the way
    /// `CGGetActiveDisplayList` itself would.
    private let hostScreenCurrentDisplaysProvider: () -> [DisplaySnapshot]
    /// `nil` refuses every proof rather than approximating one.
    private let hostScreenPresenceProofVerifier: (any HostScreenPresenceProofVerifying)?
    /// Where a `.resumeTicket` proof is minted and validated -- a wholly
    /// separate mechanism from `hostScreenPresenceProofVerifier`, which is
    /// the presence-*credential* seam and never sees a resume ticket. `nil`
    /// reads the same way the verifier's own absence does: every resume
    /// attempt refuses honestly rather than being approximated. Held by
    /// reference, not a provider closure like arming: this store *is* the
    /// mutable state a resume must outlive one connection to reach, so the
    /// same instance has to be handed to every controller
    /// `HostConnectionSessionFactory` builds for the life of a host-screen
    /// grant, not rebuilt fresh per connection.
    private let hostScreenResumeTicketStore: (any HostScreenResumeTicketStoring)?
    /// The host-only, process-lifetime wrong-guess budget for lock-screen
    /// unlock, shared across every connection this same device opens so a
    /// reconnect cannot mint a fresh budget. Held by reference for the same
    /// reason `hostScreenResumeTicketStore` is: the count is state a reconnect
    /// must reach, not something rebuilt per connection. `nil` refuses every
    /// unlock honestly, the same way a missing verifier does -- an absent
    /// budget is treated as no budget, never as an unlimited one.
    private let hostScreenUnlockThrottle: (any HostScreenUnlockThrottling)?
    /// The process-wide record of which devices currently hold a live
    /// host-screen session, shared across every connection so a device cannot
    /// open a second concurrent one. `nil` does not enforce the one-live rule at
    /// all -- an absent registry is no cap, the same way an absent throttle is
    /// no budget -- so a caller that wants the rule must supply one.
    private let hostScreenLiveSessionRegistry: (any HostScreenLiveSessionRegistering)?
    /// This connection's claim on its device's one live host-screen session,
    /// held from admission until `goodbye` releases it. `nil` until a
    /// host-screen session is admitted and again after it ends.
    private var hostScreenSessionClaim: HostScreenLiveSessionClaim?
    /// `nil` reads as `.unavailable` (unknown is not absent), exactly what
    /// `HostScreenPresenceRule.assess` already does with that
    /// reading -- this controller adds no separate handling for a missing
    /// signal.
    private let hostScreenLocalActivitySignal: (any HostLocalActivitySignal)?
    private let hostScreenPresenceThreshold: TimeInterval
    /// The ask-the-person-here gate, shared across every connection. `nil`
    /// refuses a `.mustAsk` request outright, with the same reason asking it and
    /// being refused or ignored both produce -- every host-screen seam in
    /// this controller reads its own absence as "refuse honestly rather
    /// than approximate," and this one is no exception.
    private let hostScreenPresenceGate: (any HostScreenPresenceGating)?
    /// Where a viewer's display-mode pick is actually carried out -- the
    /// one permitted display reconfiguration. `nil` is a host
    /// that offers no mode list at all, and every pick is refused as naming
    /// a mode nobody offered -- the same "refuse honestly rather than
    /// approximate" every other host-screen seam here reads its own absence
    /// as.
    private let hostScreenModeController: (any HostScreenModeControlling)?
    /// How a restore that the display would not take right now is tried
    /// again. Injectable so a test can prove the retry without waiting out
    /// the real spacing.
    private let hostScreenModeRestorePolicy: HostScreenModeRestorePolicy
    /// How this session wakes a sleeping display and keeps it awake while
    /// it runs. `nil` is a host that makes no power call at all, in which
    /// case a display that is asleep at session start stays asleep and
    /// every refusal it causes stands. Readable so the coordinator, which
    /// owns the session's own start and end, holds and drops the same hold
    /// this connection's controller was built with rather than a second one.
    public let displayWake: DisplayWakeController?
    /// The retry in flight, if any: one at a time, since one connection has
    /// one host screen. Held so a later restore cannot end up racing an
    /// earlier one for the same display.
    private var hostScreenModeRestoreRetry: Task<Void, Never>?
    /// This session's own offer: which token names which display, and the
    /// single-use challenge a signed proof must have signed. Both are
    /// replaced, never accumulated, by each call to `offerHostScreenList()`,
    /// and the challenge is cleared the moment a signed proof consumes it,
    /// whether or not that proof goes on to verify.
    private var hostScreenMintedTokens: [Data: HostScreenDisplayIdentity] = [:]
    private var hostScreenChallenge: Data?
    /// This connection's single-use unlock challenge, minted on a
    /// `hostScreenUnlockChallengeRequest` and consumed by the matching arm.
    /// Wholly separate from `hostScreenChallenge` above, which is the session
    /// offer's challenge: an offer re-mint must not void a pending unlock arm,
    /// nor a pending unlock void the offer.
    private var hostScreenPendingUnlockChallenge: Data?
    /// When `hostScreenPendingUnlockChallenge` was minted, read from this
    /// connection's own seconds source, so `armUnlock` can refuse one that has
    /// aged past its short lifetime rather than verify it.
    private var hostScreenPendingUnlockChallengeMintedAt: Double?
    /// Whether a fresh presence arm has authorised exactly one subsequent
    /// `hostScreenUnlockRequest` on this connection. Set only by a verified
    /// `armUnlock`, cleared by the one unlock attempt that consumes it and by
    /// `goodbye`.
    private var unlockArmed = false
    private var hostScreenSurface: HostScreenSurfaceState?
    /// The first admitted `canvasRequest` or `hostScreenRequest` fixes this
    /// connection's shape; the other kind refuses for the rest of its life.
    /// Both kinds share `CanvasSurfaceID`-keyed machinery and host screen
    /// owns no slot, so mixing them would conflate admission and telemetry
    /// tagging in `HostSessionCoordinator`. Reset at `goodbye`.
    private var connectionShape: ConnectionShape?
    /// This connection's claim on each surface: the canvas display and the
    /// workspace window standing on it are owned together, by one token. A
    /// teardown that arrives after a reconnect has taken the surface over must
    /// not release either, and a connection must not front a window it does
    /// not own. Readable so the coordinator installs each window under the
    /// same token this controller fronts it with -- two tokens for one
    /// ownership would make an owner-checked `raise` refuse everything.
    public let canvasOwner = CanvasOwnerToken()
    /// Counts a held button or key whose release `inputInjector.inject`
    /// itself threw for, as opposed to one that was actually posted. Kept
    /// separate from silent bookkeeping so a genuinely failed release is
    /// visible instead of indistinguishable from success.
    public private(set) var heldInputReleaseFailureCount = 0
    /// Counts key events dropped because the addressed surface's workspace
    /// window could not be brought to the front.
    public private(set) var keyConfinementDropCount = 0
    /// The surface whose workspace window this connection last brought to
    /// the front, and so where this machine's one keyboard focus is believed to be,
    /// together with the window that raise actually landed on. The window is
    /// half of the pair because a surface alone cannot tell "still the window
    /// I fronted" from "another connection's window, or none at all, in its
    /// place" -- and both of those can happen between two keystrokes.
    private var raisedSurface: CanvasSurfaceID?
    private var raisedWindow: CanvasWorkspaceWindowToken?

    /// This connection's encode-admission gate, handed to both of its
    /// canvases' media pipelines.
    ///
    /// Owned here because this is the object whose lifetime is exactly one
    /// session: it is minted per connection by
    /// `HostConnectionSessionFactory`, and it outlives both canvases, which
    /// come and go with `canvasRequest` and `goodbye` and are rebuilt outright
    /// by a resolution change. A gate owned by a canvas would be thrown away
    /// mid-session; a gate owned by the process has no owner at all, and a
    /// slot leaked into it could never be reclaimed.
    /// It bounds this session only; the bound on the machine's media engines
    /// is `SharedEncodeAdmissionGate.machineWide`, which this one defers to.
    public nonisolated let encodeAdmission: SharedEncodeAdmissionGate<CMSampleBuffer>

    /// Which canvas the viewer last reported it is looking at, or `nil` for
    /// both of the states that mean "prefer nobody": no focus report has ever
    /// arrived, or the viewer reported the user is looking at a local app.
    /// The two are deliberately one value here -- both mean fair share, and a
    /// distinction nothing can act on would be state a later change has to
    /// keep correct for nothing.
    public private(set) var focusedSurface: CanvasSurfaceID?

    /// Set immediately before this controller calls `hostScreenPresenceGate.ask`
    /// while handling a `.hostScreenRequest`, and reset to `nil` at the start
    /// of every `.hostScreenRequest` this controller handles, whether or not
    /// that one asks. What a coordinator reads right after `handle` returns
    /// to log that a person at this machine was asked at all -- neither
    /// `hostScreenDeviceName` nor `hostScreenSurface` exists yet at the
    /// moment of asking, since both are set only once the request goes on to
    /// be admitted, which a request that is refused after asking never is.
    public private(set) var hostScreenLastPresencePromptContent: HostScreenBadgeContent?

    /// The latest reading each surface's viewer sent about its own end of the
    /// wire (`viewerTelemetry`). Kept, and read by nothing here: what the host
    /// does about a viewer that cannot keep up is a separate decision, and
    /// this controller's job is to hold the evidence for it rather than to
    /// act on it.
    private var viewerTelemetry = ViewerTelemetryStore()

    /// The surface a host-screen session's picture is reported and steered
    /// under. Host screen owns no `CanvasSurfaceID` of its own -- one display
    /// per session -- so it borrows the primary, exactly as
    /// `HostSessionCoordinator` and `HostScreenCaptureMedia` already do. A
    /// report naming any other surface names nothing this connection streams.
    private static let hostScreenReportingSurface = CanvasSurfaceID.allCases[0]

    private static let maximumScrollDelta: Double = 10_000
    /// Same bound and same rationale as `maximumScrollDelta`, kept as its own
    /// constant because relative pointer motion is a different event with no
    /// reason to move in lockstep if one bound ever needs to change alone.
    private static let maximumPointerDelta: Double = 10_000

    private let pairing: HostPairingService?
    /// Fires the moment a `pairRequest` arrives, before `pairing` even
    /// looks at its code -- design's own "shown the moment a new machine asks
    /// to pair," which cannot wait for approval the way
    /// `HostPairingService.onDeviceApproved` does, because a wrong or
    /// already-consumed code is exactly the ordinary case this exists to
    /// surface, not just the ones that go on to succeed. Carries the
    /// request's own `deviceName`, empty string included -- unauthenticated
    /// and unvalidated, since nothing about who is asking is provable yet;
    /// a caller that wants an address instead of an empty name has one only
    /// the transport layer holds, not this controller.
    private let onPairingRequested: ((String) -> Void)?
    /// Fires once `.clipboardSharing`'s own authentication guard has
    /// passed -- see that case in `handle(_:)`. This controller owns no
    /// `ClipboardSyncSession` of its own; `HostNetworkSession` supplies
    /// this to reach the one it does own, only after the same gate every
    /// other state-changing message already goes through.
    private let onClipboardSharingChanged: ((Bool) -> Void)?
    /// How many of `CanvasSurfaceID`'s two slots this host will actually
    /// serve, per the operator's own settings -- `CanvasSurfaceID.capacity`
    /// by default. A request for a surface at or beyond this count is
    /// refused the same way a request for a surface outside the wire
    /// protocol's own two-canvas cap already is: `invalidCanvasRequest`,
    /// non-fatal, no reply, matching the existing out-of-range precedent
    /// rather than adding a new refusal shape.
    private let maxSurfaceCount: Int
    /// Whether this process can still capture anything on this machine. Read
    /// on every canvas request, because the answer is a fact about the
    /// process rather than about this connection.
    private let captureAvailability: HostCaptureAvailability
    /// Wrong-code guesses this connection has made. Distinct from
    /// `PairingAuthority`'s own per-code budget: that one belongs to the
    /// issued code and survives a redial, this one belongs to the socket and
    /// does not. Reset only by opening a new connection, which is the point.
    private var pairingConnectionFailureCount = 0
    /// Wrong-code guesses one connection may make before
    /// `HostNetworkSession.run()` ends it. Independent of
    /// `PairingAuthority.maximumFailedAttempts`: the per-code budget already
    /// caps an attacker at 10 guesses total, however many connections it
    /// takes to spend them; this cap makes each of those connections cost a
    /// full handshake and end after a handful of guesses, so a scripted
    /// attacker shows up as churn in the host log instead of one socket
    /// quietly working through the budget. Five is well above what a person
    /// reading six digits off this machine mistypes in one sitting -- the
    /// legitimate case redials for a fresh five rather than being cut off --
    /// and well below what makes an attacker's reconnect rate worth noticing.
    public static let maximumPairingFailuresPerConnection = 5
    /// Set once this connection has reached the cap above. The `pairRejected`
    /// reply for the guess that tripped it is still returned normally by
    /// `handle`, so the viewer is told why before `HostNetworkSession.run()`
    /// reads this flag and drops the connection.
    public private(set) var pairingConnectionFailureCapReached = false
    /// Where this controller's own diagnostics go. Injectable so a test can
    /// read what a line actually says rather than only that something
    /// happened -- see `releaseHeldInput`, whose lines are the only ones here
    /// that touch held input at all.
    private let log: @MainActor (String) -> Void
    /// The seconds source used to age the pending unlock challenge. Monotonic,
    /// so a wall-clock jump cannot lengthen or shorten a challenge's life;
    /// injected only so a test can age a challenge without waiting.
    private let unlockChallengeNowSeconds: () -> Double
    /// How long a minted unlock challenge stays armable. Sized to comfortably
    /// exceed the human interaction between challenge delivery and arm arrival
    /// -- the challenge, the person's confirmation, then the arm -- while still
    /// bounded.
    /// Not a security-critical bound (the challenge is single-use,
    /// per-connection and presence-gated); it is the human-interaction window.
    public static let unlockChallengeTimeToLiveSeconds: Double = 60

    public init(
        sessions: CanvasSurfaceSlots<VirtualDisplaySession>,
        approvedPublicKeys: Set<Data> = [],
        requireAuthentication: Bool = false,
        inputInjector: (any InputInjecting)? = nil,
        inputInjectorFactory: (any InputInjectingFactory)? = nil,
        pairing: HostPairingService? = nil,
        onPairingRequested: ((String) -> Void)? = nil,
        onClipboardSharingChanged: ((Bool) -> Void)? = nil,
        keyConfinement: HostKeyConfinement,
        maxSurfaceCount: Int = CanvasSurfaceID.capacity,
        encodeAdmission: SharedEncodeAdmissionGate<CMSampleBuffer> = SharedEncodeAdmissionGate(
            capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity,
            machineGate: .machineWide
        ),
        hostScreenArmingProvider: (() -> HostScreenArming)? = nil,
        hostScreenCurrentDisplaysProvider: @escaping () -> [DisplaySnapshot] = DisplayInventory.online,
        hostScreenPresenceProofVerifier: (any HostScreenPresenceProofVerifying)? = nil,
        hostScreenResumeTicketStore: (any HostScreenResumeTicketStoring)? = nil,
        hostScreenUnlockThrottle: (any HostScreenUnlockThrottling)? = nil,
        hostScreenLiveSessionRegistry: (any HostScreenLiveSessionRegistering)? = nil,
        hostScreenLocalActivitySignal: (any HostLocalActivitySignal)? = nil,
        hostScreenPresenceThreshold: TimeInterval = HostScreenPresenceRule.recommendedPresenceThreshold,
        hostScreenPresenceGate: (any HostScreenPresenceGating)? = nil,
        hostScreenModeController: (any HostScreenModeControlling)? = nil,
        hostScreenModeRestorePolicy: HostScreenModeRestorePolicy = .standard,
        displayWake: DisplayWakeController? = nil,
        captureAvailability: HostCaptureAvailability = .shared,
        log: @escaping @MainActor (String) -> Void = { print($0) },
        unlockChallengeNowSeconds: @escaping () -> Double = { Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000 }
    ) {
        self.captureAvailability = captureAvailability
        self.encodeAdmission = encodeAdmission
        self.sessions = sessions
        self.approvedPublicKeys = approvedPublicKeys
        self.requireAuthentication = requireAuthentication
        self.inputInjectorFactory = inputInjectorFactory
        self.keyConfinement = keyConfinement
        self.pairing = pairing
        self.onPairingRequested = onPairingRequested
        self.onClipboardSharingChanged = onClipboardSharingChanged
        self.maxSurfaceCount = min(max(maxSurfaceCount, 1), CanvasSurfaceID.capacity)
        self.hostScreenArmingProvider = hostScreenArmingProvider
        self.hostScreenCurrentDisplaysProvider = hostScreenCurrentDisplaysProvider
        self.hostScreenPresenceProofVerifier = hostScreenPresenceProofVerifier
        self.hostScreenResumeTicketStore = hostScreenResumeTicketStore
        self.hostScreenUnlockThrottle = hostScreenUnlockThrottle
        self.hostScreenLiveSessionRegistry = hostScreenLiveSessionRegistry
        self.hostScreenLocalActivitySignal = hostScreenLocalActivitySignal
        self.hostScreenPresenceThreshold = hostScreenPresenceThreshold
        self.hostScreenPresenceGate = hostScreenPresenceGate
        self.hostScreenModeController = hostScreenModeController
        self.hostScreenModeRestorePolicy = hostScreenModeRestorePolicy
        self.displayWake = displayWake
        self.log = log
        self.unlockChallengeNowSeconds = unlockChallengeNowSeconds
        surfaces = CanvasSurfaceSlots { _ in SurfaceState(inputInjector: inputInjector) }
    }

    /// The stream scale `surface`'s viewer most recently asked for.
    public func requestedStreamScale(for surface: CanvasSurfaceID) -> Double? {
        surfaces[surface].requestedStreamScale
    }

    public func requestedMaximumStreamScale(for surface: CanvasSurfaceID) -> Double? {
        surfaces[surface].requestedMaximumStreamScale
    }

    /// `surface`'s viewer's own choice of stream scale, `.automatic` until a
    /// `streamScalePreference` message says otherwise.
    public func streamScalePreference(for surface: CanvasSurfaceID) -> StreamScalePreference {
        surfaces[surface].streamScalePreference
    }

    /// `surface`'s viewer's own latest reading, or `nil` when none has ever
    /// arrived or the last one is older than the same staleness window every
    /// other telemetry reading is judged by. Deliberately not a last-known
    /// number: a viewer whose link has failed sends nothing at all, so its
    /// final reading is exactly the flattering one.
    public func latestViewerTelemetry(for surface: CanvasSurfaceID, atSeconds now: Double) -> ViewerTelemetrySample? {
        viewerTelemetry.latest(surfaceID: surface.wireValue, atSeconds: now)
    }

    /// The real display this connection's host-screen surface was admitted
    /// for, or `nil` when none is live -- what `HostSessionCoordinator`
    /// needs to actually start capturing it. Nothing about admission
    /// itself reads this; it exists only for the caller that brings
    /// capture up after `hostScreenReady` was already decided.
    public var hostScreenDisplayID: UInt32? {
        hostScreenSurface?.displayID
    }

    /// The arming record's own name for the device this connection's live
    /// host-screen surface was admitted for, or `nil` when none is live --
    /// what the session log and the badge name, never a value read back
    /// from the connection's own claim.
    public var hostScreenDeviceName: String? {
        hostScreenSurface?.deviceName
    }

    /// The same real display's own label, for the same connection
    /// `hostScreenDeviceName` names.
    public var hostScreenDisplayLabel: String? {
        hostScreenSurface?.displayLabel
    }

    /// The largest stream scale this connection's live host-screen surface
    /// may be encoded at, or `nil` when none is live. Read by
    /// `HostSessionCoordinator` so a scale reaching the encoder by any route
    /// -- the viewer's window geometry, a person's own fixed choice, the
    /// fidelity ladder -- is bounded by the same display and the same
    /// encoder limit.
    public var hostScreenMaximumStreamScale: Double? {
        hostScreenSurface.map { HostScreenEncoderSizing.maximumStreamScale(for: $0.geometry) }
    }

    /// Whether this connection has earned the right to a side effect on
    /// this machine beyond its own canvas — today, writing the viewer's clipboard onto
    /// the host pasteboard.
    ///
    /// The authentication half is exactly `input`'s gate. The active half is
    /// session-scoped rather than surface-scoped on purpose: there is one
    /// pasteboard per machine however many canvases the session opened, so any
    /// live canvas means a live session. A pairing-only connection never
    /// creates one, and `goodbye` clears them, so neither is admissible.
    public var isSessionAuthenticatedAndActive: Bool {
        guard !requireAuthentication || isAuthenticated else {
            return false
        }
        return CanvasSurfaceID.allCases.contains { surface in
            surfaces[surface].canvas != nil && sessions[surface].isActive
        }
    }

    /// Whether this connection is authenticated and has a live surface of
    /// either kind, which is what a per-surface picture decision and the
    /// telemetry reporting it are driven off.
    ///
    /// Deliberately wider than `isSessionAuthenticatedAndActive` above, and
    /// never a replacement for it: a host-screen session streams a display it
    /// did not create, so it opens no canvas and would never satisfy that
    /// one. The right to steer this session's own encoder and to describe
    /// what it is producing is not the right to write this machine's
    /// pasteboard, so the two are separate properties rather than one
    /// loosened to cover both.
    public var isSessionAuthenticatedAndStreaming: Bool {
        if isSessionAuthenticatedAndActive {
            return true
        }
        guard !requireAuthentication || isAuthenticated else {
            return false
        }
        return hostScreenSurface != nil
    }

    /// Whether this connection is a valid, live host-screen session at all:
    /// authenticated with a live host-screen surface. The valid-session gate,
    /// independent of the budget, so the coordinator can tell "not a valid
    /// session" (`.notAuthorized`) apart from "session valid but out of
    /// guesses" (`.tooManyAttempts`).
    public func canObserveHostScreenLockState() -> Bool {
        guard !requireAuthentication || isAuthenticated else {
            return false
        }
        return hostScreenSurface != nil
    }

    /// Whether this connection is currently streaming a host screen, which is
    /// what the live-session registry reads back to tell a live entry from a
    /// stale one. A session that has ended (`goodbye`) has cleared its surface,
    /// and a connection whose object is gone answers `false` through the weak
    /// reference the registry holds -- so a teardown that never fired cannot
    /// leave a device permanently marked busy.
    public var hasLiveHostScreenSession: Bool {
        hostScreenSurface != nil
    }

    /// Atomically claims one unlock guess against this device's shared budget:
    /// the cap check and the charge are one step, so N connections cannot each
    /// read the same pre-charge count and all proceed. Returns a reservation
    /// naming the exact key it charged when a slot was claimed, or `nil` when
    /// the device is at the cap or there is no live surface or no throttle
    /// (refuse honestly -- an absent budget is no budget, never an unlimited
    /// one). Every reservation must later be settled by a real guess, or
    /// released with `refund`, using the returned token -- never a fresh read
    /// of the current surface, which may have been torn down or re-armed during
    /// the multi-second attempt.
    public func tryReserveUnlockAttempt() -> UnlockReservation? {
        guard let surface = hostScreenSurface,
              let throttle = hostScreenUnlockThrottle else {
            return nil
        }
        guard throttle.tryReserve(
            devicePublicKey: surface.devicePublicKey,
            armingFingerprint: surface.armingFingerprint
        ) else {
            return nil
        }
        return UnlockReservation(
            devicePublicKey: surface.devicePublicKey,
            armingFingerprint: surface.armingFingerprint
        )
    }

    /// Releases the slot `reservation` claimed, for an attempt that consumed no
    /// real guess. Operates on the key captured at reserve time, so a surface
    /// torn down or re-armed mid-attempt neither loses the slot nor charges the
    /// wrong device.
    public func refund(_ reservation: UnlockReservation) {
        hostScreenUnlockThrottle?.refund(
            devicePublicKey: reservation.devicePublicKey,
            armingFingerprint: reservation.armingFingerprint
        )
    }

    /// Clears the shared budget for the key `reservation` claimed, as a
    /// successful unlock does. On the captured key, for the same reason `refund`
    /// is.
    public func recordUnlockSuccess(_ reservation: UnlockReservation) {
        hostScreenUnlockThrottle?.reset(
            devicePublicKey: reservation.devicePublicKey,
            armingFingerprint: reservation.armingFingerprint
        )
    }

    /// Mints this connection's single-use unlock challenge and stores it,
    /// replacing any earlier pending one. Only for a valid, live host-screen
    /// session: for anything else it mints nothing and returns `nil`, so a peer
    /// that is not entitled to unlock learns nothing -- a host that emitted a
    /// challenge on a locked screen would itself be a lock-state oracle.
    public func mintUnlockChallenge() -> Data? {
        guard canObserveHostScreenLockState() else {
            return nil
        }
        let challenge = Self.secureRandomToken()
        hostScreenPendingUnlockChallenge = challenge
        hostScreenPendingUnlockChallengeMintedAt = unlockChallengeNowSeconds()
        return challenge
    }

    /// Verifies a fresh presence proof over this connection's pending unlock
    /// challenge and, on success, arms exactly one subsequent unlock request.
    ///
    /// The pending challenge is consumed whether or not the proof verifies, so a
    /// captured arm cannot be replayed and a challenge is strictly single-use.
    /// Only a `.signed` proof can arm an unlock -- a resume ticket is a
    /// substitute for a fresh presence check, which is exactly what an unlock
    /// arm must not accept. The proof is checked against the device's registered
    /// public key at its registered minimum strength, the same verifier and the
    /// same strength admission uses; a device names neither.
    ///
    /// An arm never touches the wrong-guess budget, at either registered
    /// strength. Every unlock attempt has to arm first, so an arm that cleared
    /// the budget would put the cap out of reach and leave the login window an
    /// unbounded password oracle. Only a correct password clears it, through
    /// `recordUnlockSuccess`; someone at this Mac re-arming the machine starts a
    /// fresh budget, because that changes the arming record the budget is keyed
    /// by.
    @discardableResult
    public func armUnlock(presence: HostScreenPresenceProof) -> Bool {
        guard let challenge = hostScreenPendingUnlockChallenge else {
            return false
        }
        hostScreenPendingUnlockChallenge = nil
        let mintedAt = hostScreenPendingUnlockChallengeMintedAt
        hostScreenPendingUnlockChallengeMintedAt = nil
        // Consumed above, then refused here before any verification: an expired
        // challenge is never verified, only cleared so it cannot be reused.
        if let mintedAt, unlockChallengeNowSeconds() - mintedAt > Self.unlockChallengeTimeToLiveSeconds {
            return false
        }
        guard case .signed = presence, let surface = hostScreenSurface else {
            return false
        }
        let minimumStrength = hostScreenArmingProvider?()
            .devices.first { $0.devicePublicKey == surface.devicePublicKey }?
            .minimumCredentialStrength
        guard hostScreenPresenceProofVerifier?.verify(
            proof: presence,
            devicePublicKey: surface.devicePublicKey,
            minimumStrength: minimumStrength,
            challenge: challenge
        ) ?? false else {
            return false
        }
        unlockArmed = true
        return true
    }

    /// Gives this connection's live-session claim back to the registry, and only
    /// that one. Released against the captured claim, so a teardown landing after
    /// the same device already opened a new session evicts nothing of that new
    /// session's. A no-op when nothing is held.
    private func releaseHostScreenSessionClaim() {
        if let claim = hostScreenSessionClaim {
            hostScreenLiveSessionRegistry?.release(claim)
            hostScreenSessionClaim = nil
        }
    }

    /// Consumes this connection's one-shot unlock arm: `true` exactly once after
    /// a successful `armUnlock`, `false` otherwise. The unlock gate calls this
    /// so a single arm authorises exactly one attempt and every later attempt
    /// needs a fresh presence proof of its own.
    public func consumeUnlockArmed() -> Bool {
        guard unlockArmed else {
            return false
        }
        unlockArmed = false
        return true
    }

    /// This connection's host-side offer of the displays an armed machine
    /// may be handed -- never a consequence of anything on the wire. A
    /// caller outside this file decides when to call this: once
    /// authenticated, an armed device receives it; nothing here reacts to a
    /// `SensoriumMessage`.
    ///
    /// Replaces whatever an earlier call minted rather than adding to it --
    /// every token and the challenge are one-shot and scoped to this one
    /// offer, not an ever-growing set of things this session has ever
    /// promised were valid.
    /// The same offer, with this machine's displays woken first.
    ///
    /// macOS draws nothing to a sleeping display, so a screen that has
    /// merely idled would otherwise be refused as asleep while sitting
    /// awake in front of the person at this machine. The wake runs before
    /// the offer and the offer then reads the display list fresh, so a
    /// display that comes back is offered and one that does not is refused
    /// exactly as it was. Only a display an armed machine could already be
    /// offered is ever woken, so nothing on the wire reaches this machine's
    /// power state on its own.
    public func offerHostScreenListWakingDisplays() async throws -> SensoriumMessage {
        if let displayWake {
            let sleeping = armedSleepingDisplayIDs
            if !sleeping.isEmpty {
                await displayWake.wakeDisplays(targets: sleeping)
            }
        }
        return try offerHostScreenList()
    }

    /// The displays this connection's own device could be offered that
    /// macOS is not drawing to right now. Sleep is the one gap waking can
    /// close, so `HostScreenOfferEligibility` -- the same rule the offer
    /// itself runs -- is what decides: a display held back for any other
    /// reason, a canvas Sensorium created among them, never reaches this
    /// machine's power state.
    private var armedSleepingDisplayIDs: Set<UInt32> {
        guard let clientKey = authenticatedClientKey,
              let arming = hostScreenArmingProvider?(),
              arming.devices.contains(where: { $0.devicePublicKey == clientKey }) else {
            return []
        }
        return Set(
            hostScreenCurrentDisplaysProvider()
                .filter { HostScreenOfferEligibility.offerGapReason(for: $0) == .asleep }
                .map(\.id)
        )
    }

    /// Which display a token this host itself minted names right now, or
    /// `nil` if it names none this machine currently has. Read by the
    /// coordinator before a host-screen request is judged, so the one
    /// display a session is about to be admitted for can be woken first. A
    /// token this host never minted resolves to nothing, which is what
    /// keeps a wire message from reaching this machine's power state.
    public func hostScreenTargetDisplayID(for token: Data) -> UInt32? {
        guard let identity = hostScreenMintedTokens[token] else {
            return nil
        }
        return hostScreenCurrentDisplaysProvider().first { HostScreenDisplayIdentity($0) == identity }?.id
    }

    public func offerHostScreenList() throws -> SensoriumMessage {
        guard !requireAuthentication || isAuthenticated else {
            throw HostSessionControllerError.authenticationRequired
        }
        hostScreenMintedTokens = [:]
        hostScreenChallenge = nil

        guard let clientKey = authenticatedClientKey,
              let arming = hostScreenArmingProvider?(),
              let device = arming.devices.first(where: { $0.devicePublicKey == clientKey }) else {
            return .hostScreenRefused(reason: "host-screen-not-allowed")
        }

        let current = hostScreenCurrentDisplaysProvider()
        let eligible = HostScreenOfferEligibility.offerable(from: current)
        // One line per display this Mac has but cannot hand over, so an
        // operator reading the log is never left guessing. A canvas
        // Sensorium created is not a gap: it was never a candidate.
        for display in current {
            guard let reason = HostScreenOfferEligibility.offerGapReason(for: display), reason != .createdBySensorium else {
                continue
            }
            let label = HostScreenArmingPresentation.displayLabel(for: display)
            log("Sensorium host: did not offer host screen \"\(label)\" to \(device.deviceName): \(reason.words)")
        }

        var entries: [HostScreenListEntry] = []
        var minted: [Data: HostScreenDisplayIdentity] = [:]
        let labels = HostScreenArmingPresentation.displayLabels(for: eligible)
        for (display, label) in zip(eligible, labels) {
            let token = Self.secureRandomToken()
            let identity = HostScreenDisplayIdentity(display)
            minted[token] = identity
            entries.append(HostScreenListEntry(
                opaqueToken: token,
                label: label,
                logicalWidth: display.modeWidth,
                logicalHeight: display.modeHeight,
                backingScale: display.modeWidth > 0
                    ? Double(display.modePixelWidth) / Double(display.modeWidth) : 1.0,
                isBuiltin: display.builtin,
                displayIdentity: identity.wireStableIdentifier
            ))
        }
        if !entries.isEmpty {
            log("Sensorium host: offered \(entries.count) host screens to \(device.deviceName): \(labels.joined(separator: ", "))")
        }
        hostScreenMintedTokens = minted
        let challenge = Self.secureRandomToken()
        hostScreenChallenge = challenge
        return .hostScreenList(displays: entries, challenge: challenge)
    }

    /// The viewer's own pick of a display mode for the host screen this
    /// session is streaming, only on the viewer's explicit request during
    /// a live host-screen session. Refuses rather than
    /// acts unless a host-screen session is live on this very connection,
    /// which is also the only thing that names a display this may touch:
    /// there is no path here that reaches any display but the one this
    /// session was already admitted for.
    private func hostScreenModeChange(toModeID modeID: String) -> SensoriumMessage {
        guard var surface = hostScreenSurface, let modeController = hostScreenModeController else {
            return .hostScreenModeRefused(
                reason: hostScreenSurface == nil
                    ? HostScreenModeRefusalReason.notLive
                    : HostScreenModeRefusalReason.unknown
            )
        }
        let offered = modeController.modes(for: surface.displayID)
        guard let target = offered.first(where: { $0.modeID == modeID }) else {
            return .hostScreenModeRefused(reason: HostScreenModeRefusalReason.unknown)
        }
        // Read before anything is set, so what the session has to put back
        // is the mode the display was actually on -- and recorded only once
        // a change has actually taken, so a refused one leaves nothing
        // behind to undo.
        let modeBefore = surface.modeBeforeFirstChange
            ?? offered.first { $0.modeID == modeController.currentModeID(for: surface.displayID) }
        guard modeController.apply(modeID: modeID, to: surface.displayID) else {
            return .hostScreenModeRefused(reason: HostScreenModeRefusalReason.failed)
        }
        surface.modeBeforeFirstChange = modeBefore
        surface.geometry = Self.hostScreenGeometry(of: target)
        hostScreenSurface = surface
        log(
            "Sensorium host: host screen mode changed to \(target.width)x\(target.height) "
                + "(\(target.pixelWidth)x\(target.pixelHeight)) for \(surface.deviceName)"
        )
        return .hostScreenModeApplied(geometry: surface.geometry, currentModeID: target.modeID)
    }

    /// Every mode this session's host screen can be set to, and the one it
    /// is on right now, or `nil` when there is no live host-screen session
    /// or no mode controller to ask. Built here rather than sent from here:
    /// what reaches the wire, and when, is the caller's
    /// (`HostSessionCoordinator`), exactly as `offerHostScreenList` already
    /// works.
    public func hostScreenModeListMessage() -> SensoriumMessage? {
        guard let surface = hostScreenSurface,
              let modeController = hostScreenModeController,
              let currentModeID = modeController.currentModeID(for: surface.displayID) else {
            return nil
        }
        return .hostScreenModeList(
            modes: modeController.modes(for: surface.displayID), currentModeID: currentModeID
        )
    }

    /// Puts this session's host screen back on the mode it was on before
    /// this session's first change, and returns the geometry it is back at
    /// so the caller can restart capture at that size. `nil` when there was
    /// nothing to put back, or when the display would not take it right
    /// now -- in which case what it owes is still recorded, both here and in
    /// the mode controller, and a retry is scheduled.
    ///
    /// Called from this connection's own `goodbye` -- which every way a
    /// session can end runs through, a transport drop and the Stop control
    /// included -- and by the coordinator when capture cannot be restarted
    /// at a mode that was just applied.
    @discardableResult
    public func restoreHostScreenMode() -> SessionSurfaceGeometry? {
        guard var surface = hostScreenSurface,
              let modeBefore = surface.modeBeforeFirstChange,
              let modeController = hostScreenModeController else {
            return nil
        }
        guard modeController.restore(displayID: surface.displayID) else {
            // Nothing is cleared here. A display that refused is a display
            // this session still owes a mode to, and a record dropped now is
            // a machine left on a resolution somebody else's session chose.
            log(
                "Sensorium host: host screen mode could not be restored to "
                    + "\(modeBefore.width)x\(modeBefore.height) yet; will retry"
            )
            scheduleHostScreenModeRestoreRetry(
                displayID: surface.displayID, modeLabel: "\(modeBefore.width)x\(modeBefore.height)"
            )
            return nil
        }
        surface.modeBeforeFirstChange = nil
        surface.geometry = Self.hostScreenGeometry(of: modeBefore)
        hostScreenSurface = surface
        log("Sensorium host: host screen mode restored to \(modeBefore.width)x\(modeBefore.height)")
        return surface.geometry
    }

    /// Asks the display again, a few times, spaced out. A display that
    /// refuses at the moment a session ends is usually one still
    /// reconfiguring from the change a moment earlier, not one that will
    /// refuse forever -- and by the time it settles the session that owed
    /// the restore is gone, so something has to outlive it. The mode
    /// controller is what remembers which mode is owed, so this needs
    /// nothing of the session but the display it named.
    private func scheduleHostScreenModeRestoreRetry(displayID: UInt32, modeLabel: String) {
        hostScreenModeRestoreRetry?.cancel()
        let policy = hostScreenModeRestorePolicy
        let retries = policy.attempts - 1
        guard retries > 0 else {
            log("Sensorium host: host screen mode could not be restored to \(modeLabel); "
                + "Sensorium will try again when it quits")
            return
        }
        hostScreenModeRestoreRetry = Task { @MainActor in
            for _ in 1...retries {
                try? await Task.sleep(for: .seconds(policy.delaySeconds))
                if Task.isCancelled {
                    return
                }
                if self.hostScreenModeController?.restore(displayID: displayID) == true {
                    self.log("Sensorium host: host screen mode restored to \(modeLabel)")
                    return
                }
            }
            // Said out loud rather than left silent: the machine is on a mode
            // a session chose for it, and the only attempt left is the sweep
            // this process runs as it quits.
            self.log("Sensorium host: host screen mode could not be restored to \(modeLabel); "
                + "Sensorium will try again when it quits")
        }
    }

    /// A mode's own geometry: the points it lays out in, and the real
    /// pixels behind them as the backing scale -- the same derivation
    /// `offerHostScreenList` already makes from a display's current mode.
    private static func hostScreenGeometry(of mode: HostScreenModeEntry) -> SessionSurfaceGeometry {
        SessionSurfaceGeometry(
            logicalWidth: mode.width,
            logicalHeight: mode.height,
            backingScale: mode.width > 0 ? Double(mode.pixelWidth) / Double(mode.width) : 1.0
        )
    }

    /// 32 bytes from the platform CSPRNG -- never a counter, a hash of
    /// anything this method already knows, or any other value a viewer
    /// could derive. Fatal on failure rather than falling back to a weaker
    /// source: `SecRandomCopyBytes` failing is not a condition this
    /// function can recover from and still hand back something that is
    /// actually unguessable.
    private static func secureRandomToken() -> Data {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return bytes
    }

    /// A `.signed` proof consumes this session's single-use challenge
    /// whether or not it goes on to verify -- a challenge that survives an
    /// unsuccessful attempt is a second attempt waiting to happen -- and is
    /// checked against `hostScreenPresenceProofVerifier`, the
    /// presence-*credential* seam. A `.resumeTicket` proof never touches the
    /// challenge (it is a separate proof shape with nothing here to
    /// consume) and never reaches that verifier at all: a resume ticket is
    /// its own, self-contained substitute for a fresh
    /// presence check, validated entirely by `hostScreenResumeTicketStore`
    /// against the device, display, and arming record this request actually
    /// names. `displayIdentity`/`armingFingerprint` are `nil` only when
    /// admission has already failed for an unrelated reason (an unarmed
    /// device or an unminted token), in which case a resume ticket has
    /// nothing to be validated against and refuses -- the request refuses
    /// on the failed obligation either way.
    private func verifyHostScreenPresenceProof(
        _ presence: HostScreenPresenceProof,
        devicePublicKey: Data,
        minimumStrength: HostScreenCredentialStrength?,
        displayIdentity: HostScreenDisplayIdentity?,
        armingFingerprint: HostScreenArmingFingerprint?
    ) -> Bool {
        switch presence {
        case .signed:
            guard let challenge = hostScreenChallenge else {
                return false
            }
            hostScreenChallenge = nil
            return hostScreenPresenceProofVerifier?.verify(
                proof: presence, devicePublicKey: devicePublicKey, minimumStrength: minimumStrength, challenge: challenge
            ) ?? false
        case let .resumeTicket(token):
            guard let hostScreenResumeTicketStore, let displayIdentity, let armingFingerprint else {
                return false
            }
            return hostScreenResumeTicketStore.validate(
                token: token,
                devicePublicKey: devicePublicKey,
                displayIdentity: displayIdentity,
                armingFingerprint: armingFingerprint
            )
        }
    }

    public func handle(_ message: SensoriumMessage) throws -> SensoriumMessage? {
        switch message {
        case .hello:
            guard !isAuthenticated else {
                throw HostSessionControllerError.helloAlreadyAccepted
            }
            guard !requireAuthentication else {
                throw HostSessionControllerError.authenticationRequired
            }
            return nil
        case let .pairIntent(deviceName):
            // The true "shown the moment a new machine asks to pair" moment --
            // earlier than pairRequest, which already carries a typed code.
            // Fires the same hook and nothing else: no authentication
            // check, no state change here, no reply. A device sends this
            // before it has anything else to offer.
            onPairingRequested?(deviceName)
            return nil
        case let .clipboardSharing(enabled):
            // Gated exactly like every other state-changing message this
            // controller admits -- an unauthenticated viewer flipping the
            // host's own clipboard sync state is exactly the kind of
            // write requireAuthentication exists to refuse, fatally, not
            // silently ignore. The actual state change happens in
            // HostNetworkSession, which owns the ClipboardSyncSession this
            // controller has none of its own -- onClipboardSharingChanged
            // fires only once this guard has already passed.
            guard !requireAuthentication || isAuthenticated else {
                throw HostSessionControllerError.authenticationRequired
            }
            onClipboardSharingChanged?(enabled)
            return nil
        case let .authenticatedHello(protocolVersion, deviceName, publicKey, signature):
            guard !isAuthenticated else {
                throw HostSessionControllerError.helloAlreadyAccepted
            }
            guard protocolVersion == 1,
                  !deviceName.isEmpty,
                  DeviceIdentity.verify(
                    signature: signature,
                    message: SensoriumFrameCodec.authenticatedHelloTranscript(
                        protocolVersion: protocolVersion,
                        deviceName: deviceName,
                        publicKey: publicKey
                    ),
                    publicKey: publicKey
                  ) else {
                throw HostSessionControllerError.invalidAuthentication
            }
            guard isKeyAllowed(publicKey) else {
                throw HostSessionControllerError.deviceNotPaired
            }
            isAuthenticated = true
            authenticatedClientKey = publicKey
            pairing?.recordDeviceName(deviceName, for: publicKey)
            return nil
        case let .pairRequest(deviceName, publicKey, code, presenceCredential, signature):
            guard let pairing else {
                throw HostSessionControllerError.unexpectedMessage
            }
            // Fires unconditionally, before `code` is looked at at all: a
            // wrong or already-consumed code is a machine asking to pair just
            // as much as a correct one is, and this must not wait to find
            // out which.
            onPairingRequested?(deviceName)
            // A pairing connection carries no `authenticatedHello` -- the
            // machine is asking to pair, not opening a session -- so the
            // request's own signature is the only proof of possession this
            // connection can offer. A request that carries one and cannot
            // back it up is refused outright, exactly as an
            // `authenticatedHello` with an unverifiable signature is; one
            // that carries none proves nothing and writes nothing an
            // already-approved key has on file.
            var provenPublicKey = authenticatedClientKey
            if let signature {
                guard DeviceIdentity.verify(
                    signature: signature,
                    message: SensoriumFrameCodec.pairRequestTranscript(
                        deviceName: deviceName,
                        clientPublicKey: publicKey,
                        code: code,
                        presenceCredential: presenceCredential
                    ),
                    publicKey: publicKey
                ) else {
                    throw HostSessionControllerError.invalidAuthentication
                }
                provenPublicKey = publicKey
            }
            let response = pairing.handlePairRequest(
                deviceName: deviceName, publicKey: publicKey, code: code, presenceCredential: presenceCredential,
                connectionProvenPublicKey: provenPublicKey
            )
            // Only an actual wrong guess counts against this connection's
            // cap. A code already spent, expired, or retired is not this
            // connection guessing -- the ceremony is already over for a
            // different reason, and counting it here would let an attacker
            // exhaust a connection's budget for free by replaying a stale
            // request instead of guessing.
            if case .pairRejected(reason: "invalid-code") = response {
                pairingConnectionFailureCount += 1
                if pairingConnectionFailureCount >= Self.maximumPairingFailuresPerConnection {
                    pairingConnectionFailureCapReached = true
                    log("Sensorium host: pairing connection failure cap reached, closing connection: attempts=\(pairingConnectionFailureCount)")
                }
            }
            return response
        case .pairApproved, .pairRejected:
            throw HostSessionControllerError.unexpectedMessage
        case let .canvasRequest(logicalWidth, logicalHeight, scale, surfaceID):
            guard !requireAuthentication || isAuthenticated else {
                throw HostSessionControllerError.authenticationRequired
            }
            // A connection is one shape for its whole life: once
            // a host-screen request has been admitted, a canvas request
            // refuses from then on, with its own reason, never a silent
            // no-op that would leave the viewer waiting out a timeout.
            guard connectionShape != .hostScreen else {
                return .canvasRefused(reason: "host-screen-session-active", surfaceID: surfaceID)
            }
            // Refused rather than created: a canvas this process cannot
            // capture is a black window the viewer has no way to tell from a
            // stalled one, and the state says the next attempt would fail the
            // same way.
            guard !captureAvailability.isUnavailable else {
                return .canvasRefused(reason: CanvasRefusalReason.canvasUnavailable, surfaceID: surfaceID)
            }
            let requested = VirtualCanvasConfiguration(
                logicalWidth: logicalWidth,
                logicalHeight: logicalHeight,
                scale: scale
            )
            // A canvas of any other size is refused outright. The host has
            // exactly one supported canvas geometry, and answering a
            // differently sized request with a default-sized display would
            // be a mismatch the viewer could only discover as a wrongly
            // scaled picture.
            guard requested == .remoteDefault,
                  let surface = CanvasSurfaceID(wireValue: surfaceID),
                  surface.index < maxSurfaceCount else {
                throw HostSessionControllerError.invalidCanvasRequest
            }
            connectionShape = .canvas
            return try admitCanvas(
                surface: surface,
                configuration: requested,
                surfaceID: surfaceID
            )
        case let .displayCount(count):
            // Gated like canvasRequest: this creates or ends a session
            // display, so an unauthenticated viewer never gets to touch it.
            guard !requireAuthentication || isAuthenticated else {
                throw HostSessionControllerError.authenticationRequired
            }
            // Session-wide, and it always names the
            // *second* canvas's presence -- the first is unconditionally
            // whatever an explicit canvasRequest for it already established,
            // and this message never touches it.
            let secondSurface = CanvasSurfaceID.allCases[1]
            // A connection is one shape for its whole life: a
            // host-screen-shaped connection has no second canvas of this
            // kind to add or remove, and refuses the same way a canvasRequest
            // would rather than a silent no-op.
            guard connectionShape != .hostScreen else {
                return .canvasRefused(reason: "host-screen-session-active", surfaceID: secondSurface.wireValue)
            }
            if count >= 2 {
                // Already up: this request already describes the current
                // state, so there is nothing to change and nothing to reply
                // about -- the same "no reply for no change" precedent
                // `viewerDrawableSize`'s own unchanged-report follows.
                guard surfaces[secondSurface].canvas == nil else {
                    return nil
                }
                // The operator's own cap (a launch-time setting this message
                // never changes) still bounds what a
                // live request can bring up, exactly as it already bounds
                // an explicit canvasRequest for the same surface.
                guard secondSurface.index < maxSurfaceCount else {
                    return .canvasRefused(reason: "display-count-exceeds-host-limit", surfaceID: secondSurface.wireValue)
                }
                connectionShape = .canvas
                // A change that fails leaves the session as it was and
                // tells the viewer: caught here, never left to propagate,
                // because nothing downstream of this controller answers a
                // failed `displayCount` the way it already answers a failed
                // `canvasRequest` (`HostNetworkSession`'s own
                // `CanvasCreationGateError` translation is keyed to the
                // `canvasRequest` message shape specifically and would not
                // fire for this one).
                do {
                    return try admitCanvas(surface: secondSurface, configuration: .remoteDefault, surfaceID: secondSurface.wireValue)
                } catch is CanvasCreationGateError {
                    return .canvasRefused(reason: CanvasRefusalReason.creationInProgress, surfaceID: secondSurface.wireValue)
                } catch {
                    return .canvasRefused(reason: "display-count-change-failed", surfaceID: secondSurface.wireValue)
                }
            } else {
                // Already down: nothing to change, matching the symmetric
                // case above.
                guard surfaces[secondSurface].canvas != nil else {
                    return nil
                }
                // Removing a display never fails (design's own rule): there
                // is no admission to lose, only a live session to end, so
                // this never returns a refusal.
                releaseCanvas(surface: secondSurface)
                return nil
            }
        case .canvasReady, .inputApplied:
            // Host-to-viewer replies. A host never receives either from a
            // viewer -- `inputApplied` is this controller's own answer to
            // `.input`, never something a viewer sends it.
            throw HostSessionControllerError.unexpectedMessage
        case let .input(event, surfaceID, sequence):
            guard !requireAuthentication || isAuthenticated else {
                throw HostSessionControllerError.authenticationRequired
            }
            // A host-screen surface is not part of CanvasSurfaceID's world
            // and carries no surfaceID of its own: one display per
            // session. So it is checked before -- and instead of --
            // resolving surfaceID against the canvas slots below.
            if hostScreenSurface != nil {
                let injected = try handleHostScreenInput(event)
                return inputAppliedReply(injected: injected, sequence: sequence)
            }
            guard let surface = CanvasSurfaceID(wireValue: surfaceID) else {
                throw HostSessionControllerError.invalidInput
            }
            guard let canvas = surfaces[surface].canvas, sessions[surface].isActive else {
                throw HostSessionControllerError.inputSessionUnavailable
            }
            guard isValid(event, on: canvas) else {
                throw HostSessionControllerError.invalidInput
            }
            guard let inputInjector = surfaces[surface].inputInjector else {
                throw HostSessionControllerError.inputInjectionUnavailable
            }
            var injected = false
            if case .releaseAllInput = event {
                // The wire case carries no payload; only this controller's own
                // heldButtons/heldKeys (with the locations a mouse-up needs) can
                // turn it into the actual key-ups and mouse-up it names.
                releaseHeldInput(on: surface)
            } else {
                if case let .key(keyCode, isDown, _) = event,
                   !mayPost(key: keyCode, isDown: isDown, on: surface) {
                    return nil
                }
                try inputInjector.inject(event)
                track(event, on: surface)
                injected = true
            }
            return inputAppliedReply(injected: injected, sequence: sequence)
        case let .viewerDrawableSize(pixelWidth, pixelHeight, surfaceID, maximumScale):
            // Gated like input: this sizes the host's encoder, so an
            // unauthenticated viewer never gets to touch it.
            guard !requireAuthentication || isAuthenticated else {
                throw HostSessionControllerError.authenticationRequired
            }
            guard let surface = CanvasSurfaceID(wireValue: surfaceID) else {
                throw HostSessionControllerError.invalidViewerDrawableSize
            }
            // A host-screen session owns no canvas, so the geometry this
            // scale is a fraction of is the real display's own -- the very
            // `SessionSurfaceGeometry` `hostScreenReady` named, kept current
            // by every mode change since. Checked before the canvas slots
            // below, exactly as `.input` already is, and bounded by what
            // that display and this machine's encoder can actually produce.
            if let hostScreen = hostScreenSurface {
                guard surface == Self.hostScreenReportingSurface else {
                    throw HostSessionControllerError.inputSessionUnavailable
                }
                guard let scale = StreamScalePolicy.scale(
                    drawablePixelWidth: pixelWidth,
                    drawablePixelHeight: pixelHeight,
                    canvasLogicalWidth: Double(hostScreen.geometry.logicalWidth),
                    canvasLogicalHeight: Double(hostScreen.geometry.logicalHeight)
                ) else {
                    throw HostSessionControllerError.invalidViewerDrawableSize
                }
                surfaces[surface].requestedStreamScale = Swift.min(
                    scale, HostScreenEncoderSizing.maximumStreamScale(for: hostScreen.geometry)
                )
                surfaces[surface].requestedMaximumStreamScale = maximumScale
                return nil
            }
            guard let canvas = surfaces[surface].canvas, sessions[surface].isActive else {
                throw HostSessionControllerError.inputSessionUnavailable
            }
            guard let scale = StreamScalePolicy.scale(
                drawablePixelWidth: pixelWidth,
                drawablePixelHeight: pixelHeight,
                canvasLogicalWidth: Double(canvas.logicalWidth),
                canvasLogicalHeight: Double(canvas.logicalHeight)
            ) else {
                throw HostSessionControllerError.invalidViewerDrawableSize
            }
            surfaces[surface].requestedStreamScale = scale
            surfaces[surface].requestedMaximumStreamScale = maximumScale
            return nil
        case let .streamScalePreference(preference, surfaceID):
            // Gated like viewerDrawableSize: this steers the host's encoder,
            // so an unauthenticated viewer never gets to touch it. Accepted
            // whether or not this surface's canvas exists yet -- unlike
            // viewerDrawableSize, this is a standing choice rather than a
            // real measurement of a live window, so a viewer that sends its
            // saved preference right after pairing, before any canvas is up,
            // is not refused for it.
            guard !requireAuthentication || isAuthenticated else {
                throw HostSessionControllerError.authenticationRequired
            }
            guard let surface = CanvasSurfaceID(wireValue: surfaceID) else {
                throw HostSessionControllerError.invalidStreamScalePreference
            }
            surfaces[surface].streamScalePreference = preference
            return nil
        case let .viewerFocus(surfaceID, hasViewerFocus):
            // Gated like input: this steers which canvas wins the shared
            // encoder and the shared wire, so an unauthenticated viewer never
            // gets to touch it.
            guard !requireAuthentication || isAuthenticated else {
                throw HostSessionControllerError.authenticationRequired
            }
            // Validated whether or not the viewer claims focus: the routing
            // key obeys the same {nil, 0, 1} rule everywhere, and a report
            // that names no focus carries no surface to act on either way.
            guard let surface = CanvasSurfaceID(wireValue: surfaceID) else {
                throw HostSessionControllerError.invalidViewerFocus
            }
            guard hasViewerFocus else {
                focusedSurface = nil
                return nil
            }
            // The same canvas-less reasoning as `viewerDrawableSize` above: a
            // host-screen session has one surface to be looking at, and it is
            // not a canvas.
            if hostScreenSurface != nil {
                guard surface == Self.hostScreenReportingSurface else {
                    throw HostSessionControllerError.inputSessionUnavailable
                }
                focusedSurface = surface
                return nil
            }
            guard surfaces[surface].canvas != nil, sessions[surface].isActive else {
                throw HostSessionControllerError.inputSessionUnavailable
            }
            focusedSurface = surface
            return nil
        case let .timeSyncRequest(clientTimeNanoseconds):
            // Gated like input: the host's uptime clock is not something an
            // unpaired tailnet viewer gets to read.
            guard !requireAuthentication || isAuthenticated else {
                throw HostSessionControllerError.authenticationRequired
            }
            return .timeSyncReply(
                clientTimeNanoseconds: clientTimeNanoseconds,
                hostTimeNanoseconds: MonotonicClock.nowNanoseconds()
            )
        case let .viewerTelemetry(sample):
            // Gated like `viewerFocus`: an unauthenticated viewer does not get
            // to supply the evidence this host will steer its own encoder by.
            // An out-of-range surfaceID is dropped inside the store rather
            // than refused here -- a measurement grants nothing and steers
            // nothing on its own, so there is no session worth ending over
            // one that names a surface this connection cannot have.
            guard !requireAuthentication || isAuthenticated else {
                throw HostSessionControllerError.authenticationRequired
            }
            viewerTelemetry.record(
                sample,
                atSeconds: Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000
            )
            return nil
        case .timeSyncReply, .telemetry, .canvasRefused, .hostScreenUnlockResult, .hostScreenLockState,
             .hostScreenUnlockChallenge:
            // All host-to-viewer only; the host itself never expects to receive
            // any of them.
            throw HostSessionControllerError.unexpectedMessage
        case .hostScreenUnlockRequest:
            // Handled entirely by `HostSessionCoordinator`, which short-circuits
            // it before dispatch here so the password and the loopback IO stay
            // out of this controller. Reaching this line means it was not
            // short-circuited, which is a wiring bug, not a message to act on.
            throw HostSessionControllerError.unexpectedMessage
        case .hostScreenUnlockChallengeRequest:
            // Carries no password or loopback IO, so it is handled here rather
            // than short-circuited in the coordinator: the challenge is minted
            // where the offer challenge already is. `mintUnlockChallenge` mints
            // only for a valid, live host-screen session and returns `nil`
            // otherwise, so an unentitled request gets no reply and learns no
            // lock state.
            guard let challenge = mintUnlockChallenge() else {
                return nil
            }
            return .hostScreenUnlockChallenge(challenge: challenge)
        case let .hostScreenUnlockArm(presence):
            // Verified here, where the presence verifier and the arming record
            // already live. The client sends the unlock request next without
            // waiting for an acknowledgement, so a failed arm simply leaves the
            // connection unarmed and the later unlock refuses as
            // `.presenceRequired`; there is nothing to reply.
            _ = armUnlock(presence: presence)
            return nil
        case let .hostScreenRequest(token, presence):
            guard !requireAuthentication || isAuthenticated else {
                throw HostSessionControllerError.authenticationRequired
            }
            // Reset for this request before anything below can set it, so a
            // coordinator reading it after `handle` returns never sees a
            // stale value an earlier request on this same connection left
            // behind.
            hostScreenLastPresencePromptContent = nil
            // Once a canvas request has been admitted, a host-screen
            // request refuses from then on.
            guard connectionShape != .canvas else {
                return .hostScreenRefused(reason: "canvas-session-active")
            }
            // A second host-screen request would overwrite `hostScreenSurface`
            // underneath whatever already has it.
            guard hostScreenSurface == nil else {
                return .hostScreenRefused(reason: "host-screen-session-active")
            }
            guard let clientKey = authenticatedClientKey, let arming = hostScreenArmingProvider?() else {
                return .hostScreenRefused(reason: "host-screen-not-allowed")
            }
            let currentDisplays = hostScreenCurrentDisplaysProvider()
            // Every obligation below is computed independently, before any
            // of them is acted on.
            let admission = HostScreenSelectionGuard.admit(
                deviceKey: clientKey,
                token: token,
                mintedTokens: hostScreenMintedTokens,
                arming: arming,
                currentDisplays: currentDisplays
            )
            // Resolved once, as its own independent value, so the geometry
            // reply and a resume ticket's own device/display/arming binding
            // both read the exact same snapshot rather than two separate
            // re-derivations of "the display admission just resolved."
            // `nil` exactly when admission itself failed, in which case
            // there is no display for a resume ticket to be bound to either.
            let resolvedDisplay: DisplaySnapshot? = {
                guard case let .success(displayID) = admission else {
                    return nil
                }
                return currentDisplays.first(where: { $0.id == displayID })
            }()
            let armingFingerprint = arming.devices
                .first { $0.devicePublicKey == clientKey }
                .map(HostScreenArmingFingerprint.init)
            let minimumStrength = arming.devices.first { $0.devicePublicKey == clientKey }?.minimumCredentialStrength
            let proofVerified = verifyHostScreenPresenceProof(
                presence,
                devicePublicKey: clientKey,
                minimumStrength: minimumStrength,
                displayIdentity: resolvedDisplay.map(HostScreenDisplayIdentity.init),
                armingFingerprint: armingFingerprint
            )
            // A person is asked only once admission and the
            // presence-credential proof have both held: a paired device can
            // reach a valid arming record and a minted token with no human
            // at the viewer, and the proof is what stands for that. No path
            // through this closure reaches `.mustAsk` while `proofVerified`
            // is false.
            let presenceOutcome: HostScreenPresenceOutcome? = {
                guard case .success = admission, proofVerified, let display = resolvedDisplay else { return nil }
                // A validated resume ticket is the prior session's grant;
                // it resumes silently and never re-runs the fresh-presence
                // rule or its gate.
                if case .resumeTicket = presence {
                    return .proceed
                }
                let armedDevice = arming.devices.first { $0.devicePublicKey == clientKey }
                guard armedDevice?.asksWhenSomeoneIsUsingThisMachine == true else {
                    log("host screen: \(armedDevice?.deviceName ?? "") is armed without asking first; no presence prompt")
                    return .proceed
                }
                let assessment = HostScreenPresenceRule.assess(
                    reading: hostScreenLocalActivitySignal?.currentReading() ?? .unavailable,
                    presenceThreshold: hostScreenPresenceThreshold
                )
                switch assessment {
                case .mayProceed:
                    return .proceed
                case .mustAsk:
                    let content = HostScreenBadgeContent(
                        deviceName: arming.devices.first { $0.devicePublicKey == clientKey }?.deviceName ?? "",
                        displayLabel: HostScreenArmingPresentation.displayLabel(for: display)
                    )
                    guard let gate = hostScreenPresenceGate else {
                        return .refused(reason: "host-screen-presence-check-required")
                    }
                    hostScreenLastPresencePromptContent = content
                    return gate.ask(content: content)
                }
            }()

            guard case let .success(displayID) = admission,
                  proofVerified,
                  case .proceed = presenceOutcome,
                  let display = resolvedDisplay else {
                if case .success = admission, !proofVerified {
                    // The presence-credential proof is checked, and its
                    // own refusal reported, before presence is ever
                    // considered -- a resume ticket is its own,
                    // self-contained substitute for a fresh presence
                    // check, expired or minted for another device or
                    // display, refused on its own terms, never folded
                    // into the `.signed` path's credential-strength
                    // reasons below, which describe a wholly different
                    // proof this ticket never touches at all.
                    if case .resumeTicket = presence {
                        return .hostScreenRefused(reason: "host-screen-resume-refused")
                    }
                    // A `nil` minimum with a verifier configured means this
                    // device was armed before strengths were recorded;
                    // re-arming, not another presence check, fixes it. With
                    // no verifier at all every request refuses anyway, so
                    // `nil` there gets the ordinary reason.
                    if minimumStrength == nil, hostScreenPresenceProofVerifier != nil {
                        return .hostScreenRefused(reason: "host-screen-needs-rearming")
                    }
                    return .hostScreenRefused(reason: "host-screen-credential-unknown")
                }
                // A person's own decline and the window's own timeout carry
                // their own wire reasons; every other cause a gate can
                // refuse for -- no gate configured, or one already showing
                // for another connection -- keeps the one existing reason,
                // since neither says anything a person at the viewer can
                // act on differently.
                if case .success = admission, case let .refused(gateReason) = presenceOutcome {
                    switch gateReason {
                    case HostScreenPresenceRule.declinedReason:
                        return .hostScreenRefused(reason: "host-screen-presence-declined")
                    case HostScreenPresenceRule.unansweredReason:
                        return .hostScreenRefused(reason: "host-screen-presence-unanswered")
                    default:
                        return .hostScreenRefused(reason: "host-screen-presence-check-required")
                    }
                }
                return .hostScreenRefused(reason: "host-screen-not-allowed")
            }

            // One live host-screen session per device. A second concurrent
            // session for a device already streaming one is refused, with its
            // own distinct reason -- never `.tooManyAttempts` or an unlock
            // outcome, which describe wholly different refusals. A device whose
            // recorded session is no longer live (a connection that dropped
            // without releasing) is evicted and this one admitted, so an
            // unattended host always recovers. Captured before the surface is
            // built and released at `goodbye`, or right here if the injector
            // below fails to build. A resume that replaces a dead session for
            // the same device passes here exactly as a fresh request does.
            if let registry = hostScreenLiveSessionRegistry {
                guard let claim = registry.admit(
                    devicePublicKey: clientKey,
                    isLive: { [weak self] in self?.hasLiveHostScreenSession ?? false }
                ) else {
                    return .hostScreenRefused(reason: "host-screen-already-live")
                }
                hostScreenSessionClaim = claim
            }
            let geometry = SessionSurfaceGeometry(
                logicalWidth: display.modeWidth,
                logicalHeight: display.modeHeight,
                backingScale: display.modeWidth > 0
                    ? Double(display.modePixelWidth) / Double(display.modeWidth) : 1.0
            )
            // No session or display to unwind on failure here, unlike
            // canvasRequest: a host-screen surface resolves and validates a
            // display it did not create and never releases. The one thing
            // recorded before this point is the live-session claim above, so an
            // injector failure gives it back deterministically rather than
            // leaving the device to self-heal on its next admission.
            let injector: (any InputInjecting)?
            do {
                injector = try inputInjectorFactory?.make(canvasDisplayID: displayID)
            } catch {
                releaseHostScreenSessionClaim()
                throw error
            }
            connectionShape = .hostScreen
            // `armingFingerprint` is never nil on this path: admission's own
            // success at :1284 above already required an arming record for
            // `clientKey` to exist, and `armingFingerprint` is that same
            // record's fingerprint. `HostScreenSelectionGuard.admit` returns
            // `.success` only when `arming.devices` contains this device, so
            // the `.first` this was mapped from cannot have been nil.
            let admittedFingerprint = armingFingerprint!
            hostScreenSurface = HostScreenSurfaceState(
                geometry: geometry,
                displayID: displayID,
                devicePublicKey: clientKey,
                armingFingerprint: admittedFingerprint,
                deviceName: arming.devices.first { $0.devicePublicKey == clientKey }?.deviceName ?? "",
                displayLabel: HostScreenArmingPresentation.displayLabel(for: display),
                inputInjector: injector
            )
            // `armingFingerprint` is never nil here: admission's own success
            // already required an arming record for this device to exist,
            // computed the same way. The fallback below only ever protects
            // against that invariant being wrong, not a real reachable path.
            let resumeTicket: Data
            if let hostScreenResumeTicketStore, let armingFingerprint {
                resumeTicket = hostScreenResumeTicketStore.mint(
                    devicePublicKey: clientKey,
                    displayIdentity: HostScreenDisplayIdentity(display),
                    armingFingerprint: armingFingerprint
                )
            } else {
                resumeTicket = Self.secureRandomToken()
            }
            return .hostScreenReady(geometry: geometry, resumeTicket: resumeTicket)
        case let .hostScreenModeRequest(modeID):
            guard !requireAuthentication || isAuthenticated else {
                throw HostSessionControllerError.authenticationRequired
            }
            return hostScreenModeChange(toModeID: modeID)
        case .hostScreenList, .hostScreenReady, .hostScreenRefused,
             .hostScreenModeList, .hostScreenModeApplied, .hostScreenModeRefused:
            // All six are host-to-viewer only; the host itself never
            // expects to receive any of them, the same as
            // timeSyncReply/telemetry/canvasRefused above.
            throw HostSessionControllerError.unexpectedMessage
        case let .goodbye(reason):
            focusedSurface = nil
            for surface in CanvasSurfaceID.allCases {
                releaseHeldInput(on: surface)
                sessions[surface].stop(owner: canvasOwner)
                surfaces[surface].canvas = nil
            }
            // A person at this machine ended a host-screen session, so the
            // grant ends with it: the surface being torn down is a
            // genuinely new session, and a new session prompts. Done here
            // rather than left to the goodbye reaching the viewer -- a
            // redial that never received it must be refused just the same.
            if reason == GoodbyeReason.stoppedByHost, hostScreenSurface != nil, let clientKey = authenticatedClientKey {
                hostScreenResumeTicketStore?.invalidateAll(for: clientKey)
            }
            // No display to stop or release here -- this connection never
            // owned one -- but held input on it is this connection's own
            // and must be released the same as canvas
            // input, and the offer this session made dies with it.
            releaseHostScreenHeldInput()
            // Before the surface is forgotten, since the display it names
            // is what a restore acts on: a session that changed its host
            // screen's mode puts that mode back however it ends -- restored
            // when the session ends or the host quits.
            restoreHostScreenMode()
            hostScreenSurface = nil
            releaseHostScreenSessionClaim()
            hostScreenMintedTokens = [:]
            hostScreenChallenge = nil
            hostScreenPendingUnlockChallenge = nil
            hostScreenPendingUnlockChallengeMintedAt = nil
            unlockArmed = false
            connectionShape = nil
            return nil
        case .unrecognized:
            // A message type this build doesn't know, from a newer viewer.
            // Skip it rather than treating an unknown message type as fatal.
            return nil
        }
    }

    /// `.inputApplied` for an event that actually reached `inputInjector.inject(_:)`
    /// and was tagged with a sequence, silence otherwise -- an untagged event
    /// (an old viewer) has nothing to reply to, and an event this controller
    /// never injected (a suppressed key, `releaseAllInput`) was never applied
    /// and must not be reported as if it were.
    private func inputAppliedReply(injected: Bool, sequence: UInt64?) -> SensoriumMessage? {
        guard injected, let sequence else { return nil }
        return .inputApplied(sequence: sequence)
    }

    /// Whether a key event may be posted at all.
    ///
    /// A key event carries no location, so macOS delivers it to whatever holds
    /// this machine's one process-wide keyboard focus -- which both session
    /// canvases share with everything on a physical display. The question is
    /// therefore not whether the focused window is *ours* but whether it is
    /// *on the canvas we own*: an application launched onto the canvas holds
    /// the keyboard itself, and typing into it is the whole point of having
    /// launched it. A key that can be confined to neither this connection's
    /// own workspace window nor an application standing wholly on its canvas
    /// is dropped, because posting it would type into whatever is frontmost
    /// instead.
    private func mayPost(key keyCode: UInt16, isDown: Bool, on surface: CanvasSurfaceID) -> Bool {
        // A key-up for a key this connection never successfully pressed has
        // nothing to release and would land as a bare key-up wherever focus
        // happens to be. A dropped key-down is exactly that case: it left
        // nothing held, so its key-up must not be posted either.
        guard isDown || surfaces[surface].heldKeys.contains(keyCode) else {
            return false
        }
        guard case let .confined(workspaces, scanner) = keyConfinement else {
            return true
        }
        // Re-asked for every key, because the answer changes underneath a
        // connection: these workspaces are shared, so another connection can
        // take the surface over, and that connection's teardown can close the
        // window outright, between one keystroke and the next. It reads the
        // workspace's own stored state, so it costs no AppKit round trip --
        // only the `raise` below does.
        guard let window = workspaces[surface].installedWindow(owner: canvasOwner) else {
            forgetRaise()
            return dropKey(on: surface, reason: .rejectUnownedWorkspace)
        }
        // Still the same window this connection fronted, and still the window
        // the machine's keys are going to: every further key for it lands
        // there, and fronting a window per keystroke would thrash the screen
        // and cost an AppKit round trip per key. Focus is the second half
        // because the window alone cannot answer it -- this machine's one
        // keyboard focus is process-wide, so anything on a physical display,
        // or another connection's canvas window, can take it away without
        // touching this window at all.
        if raisedSurface == surface, raisedWindow == window,
           workspaces[surface].hasKeyFocus(owner: canvasOwner) {
            return true
        }
        // The keyboard is somewhere other than our own window. It may be on
        // an application launched onto this canvas, which is a place a key is
        // allowed to go -- so ask where the frontmost application's windows
        // actually stand before doing anything about it.
        //
        // Asked before the raise: a cached answer would keep posting into a
        // window that has left the canvas, and raising first would front
        // our window over the application the person is typing into.
        let decision = CanvasKeyConfinement.decide(
            ownsWorkspace: true,
            canvasBounds: workspaces[surface].canvasBounds(owner: canvasOwner),
            scan: scanner.scan()
        )
        if decision == .allow {
            // Deliberately no raise bookkeeping: our own window is not where
            // the keyboard is, so the next key must ask again rather than take
            // the identity path above.
            return true
        }
        // Not our window and not our canvas: a genuine change -- a different
        // surface, a different window on this one, or the keyboard gone to a
        // physical display. One raise is the remedy for all three, so a lost
        // focus costs a raise rather than a raise per key. The key rides on it
        // only once the raise has actually won the keyboard: AppKit resolves
        // `makeKeyAndOrderFront` and `activate` on its own schedule, and a key
        // posted before that lands wherever the focus still is. A failed raise
        // deliberately records nothing, so the next key retries it rather than
        // latching the surface off.
        guard workspaces[surface].raise(owner: canvasOwner),
              workspaces[surface].hasKeyFocus(owner: canvasOwner) else {
            forgetRaise()
            return dropKey(on: surface, reason: decision)
        }
        raisedSurface = surface
        raisedWindow = window
        return true
    }

    /// Drops the key that could not be confined. The count, the surface and
    /// which of the three checks refused -- never the key code: keystroke
    /// material stays out of every log line here, as it does in
    /// `releaseHeldInput`.
    private func dropKey(on surface: CanvasSurfaceID, reason: CanvasKeyConfinementDecision) -> Bool {
        keyConfinementDropCount += 1
        log(
            "Sensorium host: key input dropped, workspace not frontmost: surface=\(surface.wireValue) "
                + "reason=\(reason.reasonCode) dropped=\(keyConfinementDropCount)"
        )
        return false
    }

    /// Whatever this connection had fronted is gone or no longer its own, so
    /// the next key it does get to post must front a window again rather than
    /// trust a raise that no longer describes anything.
    private func forgetRaise() {
        raisedSurface = nil
        raisedWindow = nil
    }

    private func isValid(_ event: SensoriumInputEvent, on canvas: VirtualCanvasConfiguration) -> Bool {
        isValid(event, logicalWidth: canvas.logicalWidth, logicalHeight: canvas.logicalHeight)
    }

    /// Shared by both capture intents: a session canvas validates against
    /// its own `VirtualCanvasConfiguration`, a host-screen surface against
    /// the real display's `SessionSurfaceGeometry` -- the bounds check
    /// itself only ever needed the width and height either one carries.
    private func isValid(_ event: SensoriumInputEvent, logicalWidth: Int, logicalHeight: Int) -> Bool {
        switch event {
        case let .pointerMoved(x, y):
            isOnCanvas(x: x, y: y, logicalWidth: logicalWidth, logicalHeight: logicalHeight)
        case let .pointerMovedRelative(deltaX, deltaY):
            deltaX.isFinite
                && deltaY.isFinite
                && abs(deltaX) <= Self.maximumPointerDelta
                && abs(deltaY) <= Self.maximumPointerDelta
        case let .pointerButton(_, _, x, y):
            isOnCanvas(x: x, y: y, logicalWidth: logicalWidth, logicalHeight: logicalHeight)
        case let .scrolled(deltaX, deltaY, x, y, _, _):
            isOnCanvas(x: x, y: y, logicalWidth: logicalWidth, logicalHeight: logicalHeight)
                && deltaX.isFinite
                && deltaY.isFinite
                && abs(deltaX) <= Self.maximumScrollDelta
                && abs(deltaY) <= Self.maximumScrollDelta
        case let .key(_, _, modifiers):
            modifiers.isSubset(of: .all)
        case .releaseAllInput, .pointerCaptureChanged:
            true
        }
    }

    /// Starts `surface` at `configuration` and answers exactly as a
    /// `canvasRequest` for it already does -- shared so `displayCount`'s own
    /// live "bring the second display up" path reuses the identical
    /// session-start, injector-creation, and `canvasReady` construction
    /// rather than a second, divergent copy of it. `surfaceID` is the value
    /// to echo on the reply; `canvasRequest` passes the one the viewer sent,
    /// `displayCount` passes the second surface's own wire value since it
    /// carries none of its own to echo.
    private func admitCanvas(
        surface: CanvasSurfaceID,
        configuration: VirtualCanvasConfiguration,
        surfaceID: UInt32?
    ) throws -> SensoriumMessage {
        let handle = try sessions[surface].start(owner: canvasOwner, configuration: configuration)
        surfaces[surface].canvas = configuration
        if surfaces[surface].inputInjector == nil, let inputInjectorFactory {
            do {
                surfaces[surface].inputInjector = try inputInjectorFactory.make(
                    canvasDisplayID: handle.rawValue
                )
            } catch {
                sessions[surface].stop(owner: canvasOwner)
                surfaces[surface].canvas = nil
                throw error
            }
        }
        return .canvasReady(
            displayID: handle.rawValue,
            logicalWidth: configuration.logicalWidth,
            logicalHeight: configuration.logicalHeight,
            hostSignature: canvasReadySignature(
                displayID: handle.rawValue,
                logicalWidth: configuration.logicalWidth,
                logicalHeight: configuration.logicalHeight,
                surfaceID: surfaceID
            ),
            // Echoed rather than normalized: a request that omitted
            // surfaceID gets a reply that omits it too.
            surfaceID: surfaceID,
            // So the viewer's window title can say who it is talking to
            // instead of only the address the user dialled. Read fresh
            // per canvas, not cached: a machine name changed in System
            // Settings during a long-lived host process should still
            // reach the next connection.
            hostName: Host.current().localizedName
        )
    }

    /// Tears down exactly `surface`, live, mid-session -- unlike `goodbye`'s
    /// own teardown loop, which always tears down every surface because a
    /// connection is ending. `displayCount`'s own "take the second display
    /// down" path is what this exists for: releasing held input on it and
    /// stopping its session, but never touching any other surface, and
    /// never touching this connection's `connectionShape` (a session that
    /// still has one canvas up is still a canvas-shaped session).
    private func releaseCanvas(surface: CanvasSurfaceID) {
        releaseHeldInput(on: surface)
        sessions[surface].stop(owner: canvasOwner)
        surfaces[surface].canvas = nil
        // A focus report naming a surface that no longer exists is a stale
        // one this connection must not keep believing.
        if focusedSurface == surface {
            focusedSurface = nil
        }
    }

    /// Proves to the viewer that this exact canvas came from the host it paired
    /// with. Unsigned when the host has no identity to sign with.
    private func canvasReadySignature(
        displayID: UInt32,
        logicalWidth: Int,
        logicalHeight: Int,
        surfaceID: UInt32?
    ) -> Data? {
        guard let pairing, let clientKey = authenticatedClientKey else {
            return nil
        }
        return try? pairing.signCanvasReady(
            displayID: displayID,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            clientPublicKey: clientKey,
            surfaceID: surfaceID
        )
    }

    /// Without a pairing service an empty approval set means "no allowlist
    /// configured"; with one it means "nothing paired yet", which must deny.
    private func isKeyAllowed(_ publicKey: Data) -> Bool {
        if let pairing {
            return pairing.isApproved(publicKey) || approvedPublicKeys.contains(publicKey)
        }
        return approvedPublicKeys.isEmpty || approvedPublicKeys.contains(publicKey)
    }

    private func isOnCanvas(x: Double, y: Double, logicalWidth: Int, logicalHeight: Int) -> Bool {
        x.isFinite
            && y.isFinite
            && (0...Double(logicalWidth)).contains(x)
            && (0...Double(logicalHeight)).contains(y)
    }

    /// Tracks what the host believes is physically held so a lost session cannot
    /// strand a button or modifier down on this machine.
    private func track(_ event: SensoriumInputEvent, on surface: CanvasSurfaceID) {
        switch event {
        case let .pointerButton(button, isDown, x, y):
            if isDown {
                surfaces[surface].heldButtons[button] = CanvasInputLocation(x: x, y: y)
            } else {
                surfaces[surface].heldButtons[button] = nil
            }
        case let .key(keyCode, isDown, _):
            if isDown {
                surfaces[surface].heldKeys.insert(keyCode)
            } else {
                surfaces[surface].heldKeys.remove(keyCode)
            }
        case .releaseAllInput:
            surfaces[surface].heldButtons = [:]
            surfaces[surface].heldKeys = []
        case let .pointerCaptureChanged(isCaptured):
            surfaces[surface].isPointerCaptured = isCaptured
        case .pointerMoved, .pointerMovedRelative, .scrolled:
            break
        }
    }

    /// Injects the exact release for everything still held, then forgets only
    /// what was actually released. A release that throws leaves its button or
    /// key in `heldButtons`/`heldKeys` rather than being discarded as if it
    /// had succeeded: the physical input is still down, and clearing the
    /// bookkeeping here would delete the only record of that and make a
    /// later retry (the next `releaseAllInput`, or `goodbye`) skip it too.
    private func releaseHeldInput(on surface: CanvasSurfaceID) {
        guard let inputInjector = surfaces[surface].inputInjector else {
            surfaces[surface].heldButtons = [:]
            surfaces[surface].heldKeys = []
            return
        }
        var failedButtonCount = 0
        var failedKeyCount = 0
        for button in surfaces[surface].heldButtons.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let location = surfaces[surface].heldButtons[button] else { continue }
            do {
                try inputInjector.inject(
                    .pointerButton(button: button, isDown: false, x: location.x, y: location.y)
                )
                surfaces[surface].heldButtons[button] = nil
            } catch {
                heldInputReleaseFailureCount += 1
                failedButtonCount += 1
            }
        }
        for keyCode in surfaces[surface].heldKeys.sorted() {
            do {
                try inputInjector.inject(.key(keyCode: keyCode, isDown: false, modifiers: []))
                surfaces[surface].heldKeys.remove(keyCode)
            } catch {
                heldInputReleaseFailureCount += 1
                failedKeyCount += 1
            }
        }
        // A session that drops while captured must not leave this machine's
        // mouse/cursor association turned off for good; best-effort, since
        // there is no held-input bookkeeping equivalent to retry this from.
        if surfaces[surface].isPointerCaptured {
            try? inputInjector.inject(.pointerCaptureChanged(isCaptured: false))
            surfaces[surface].isPointerCaptured = false
        }
        // Counts and the outcome, never which button or which key: what is
        // still held at teardown is keystroke material, and the rest of this
        // design keeps input out of every log.
        guard failedButtonCount > 0 || failedKeyCount > 0 else {
            return
        }
        log("Sensorium host: held input release failed, still held: buttons=\(failedButtonCount) keys=\(failedKeyCount)")
    }

    /// Mirrors the canvas branch of `.input` above, against the one
    /// host-screen surface instead of a `CanvasSurfaceID`-keyed slot. Returns
    /// whether the event actually reached `inputInjector.inject(_:)` -- never
    /// for `releaseAllInput`, which has no injector call of its own, and
    /// never for a key `mayPostHostScreen` suppressed -- so the caller can
    /// decide whether an `.inputApplied` reply is honest to send.
    @discardableResult
    private func handleHostScreenInput(_ event: SensoriumInputEvent) throws -> Bool {
        guard let surface = hostScreenSurface else {
            throw HostSessionControllerError.inputSessionUnavailable
        }
        guard isValid(
            event, logicalWidth: surface.geometry.logicalWidth, logicalHeight: surface.geometry.logicalHeight
        ) else {
            throw HostSessionControllerError.invalidInput
        }
        guard let inputInjector = surface.inputInjector else {
            throw HostSessionControllerError.inputInjectionUnavailable
        }
        if case .releaseAllInput = event {
            releaseHostScreenHeldInput()
            return false
        }
        if case let .key(keyCode, isDown, _) = event, !mayPostHostScreen(key: keyCode, isDown: isDown) {
            return false
        }
        try inputInjector.inject(event)
        trackHostScreen(event)
        return true
    }

    /// Host-screen keys go wherever the host's own focus is; that is the
    /// feature, so `keyConfinement`, wired `.confined` for canvas
    /// connections, is deliberately not read here. Only the key-up rule
    /// survives: a key-up for a key never pressed would land bare on
    /// whatever has focus.
    private func mayPostHostScreen(key keyCode: UInt16, isDown: Bool) -> Bool {
        isDown || hostScreenSurface?.heldKeys.contains(keyCode) == true
    }

    private func trackHostScreen(_ event: SensoriumInputEvent) {
        switch event {
        case let .pointerButton(button, isDown, x, y):
            if isDown {
                hostScreenSurface?.heldButtons[button] = CanvasInputLocation(x: x, y: y)
            } else {
                hostScreenSurface?.heldButtons[button] = nil
            }
        case let .key(keyCode, isDown, _):
            if isDown {
                hostScreenSurface?.heldKeys.insert(keyCode)
            } else {
                hostScreenSurface?.heldKeys.remove(keyCode)
            }
        case .releaseAllInput:
            hostScreenSurface?.heldButtons = [:]
            hostScreenSurface?.heldKeys = []
        case let .pointerCaptureChanged(isCaptured):
            hostScreenSurface?.isPointerCaptured = isCaptured
        case .pointerMoved, .pointerMovedRelative, .scrolled:
            break
        }
    }

    /// Mirrors `releaseHeldInput(on:)` against the one host-screen surface.
    /// A no-op when none is active, the same as that function is a no-op
    /// for a surface with nothing held.
    private func releaseHostScreenHeldInput() {
        guard var surface = hostScreenSurface else {
            return
        }
        guard let inputInjector = surface.inputInjector else {
            surface.heldButtons = [:]
            surface.heldKeys = []
            hostScreenSurface = surface
            return
        }
        var failedButtonCount = 0
        var failedKeyCount = 0
        for button in surface.heldButtons.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard let location = surface.heldButtons[button] else { continue }
            do {
                try inputInjector.inject(.pointerButton(button: button, isDown: false, x: location.x, y: location.y))
                surface.heldButtons[button] = nil
            } catch {
                heldInputReleaseFailureCount += 1
                failedButtonCount += 1
            }
        }
        for keyCode in surface.heldKeys.sorted() {
            do {
                try inputInjector.inject(.key(keyCode: keyCode, isDown: false, modifiers: []))
                surface.heldKeys.remove(keyCode)
            } catch {
                heldInputReleaseFailureCount += 1
                failedKeyCount += 1
            }
        }
        if surface.isPointerCaptured {
            try? inputInjector.inject(.pointerCaptureChanged(isCaptured: false))
            surface.isPointerCaptured = false
        }
        hostScreenSurface = surface
        guard failedButtonCount > 0 || failedKeyCount > 0 else {
            return
        }
        log("Sensorium host: held input release failed, still held: buttons=\(failedButtonCount) keys=\(failedKeyCount)")
    }
}

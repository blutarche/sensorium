import SensoriumCore
import Foundation

public enum ClientSessionError: Error, Equatable {
    case unexpectedMessage
    case notConnected
    case invalidInput
    case pairingRejected(String)
    case identityRequired
    case hostKeyMismatch
    case timedOut
    /// The host refused the canvas this session cannot do without. Only ever
    /// the primary: a refused second canvas is survivable and drops the viewer
    /// to single-window instead of throwing.
    case canvasRefused(String)
    /// The host echoed a `surfaceID` on `canvasReady` that does not match what
    /// this viewer sent on `canvasRequest` — neither absent (an old host) nor
    /// identical (a host that understands it), so it cannot be trusted.
    case surfaceIDMismatch
    /// A `.hostScreen` connect ended in anything but `hostScreenReady`: the
    /// host's own named reason when it sent `hostScreenRefused`, or a reason
    /// this viewer names itself when the offered list never named the
    /// display asked for. Never a partial session: it never degrades to a
    /// view-only session.
    case hostScreenRefused(String)
    /// A person at the host ended this session from that machine, through the
    /// host's own Stop control -- `GoodbyeReason.stoppedByHost` on the wire.
    /// Thrown by the session itself rather than by a connect attempt: it is
    /// what turns an ending nothing here chose into one nothing here redials.
    case stoppedByHost
    /// The host ended this session because its own displays were asleep and
    /// would not wake -- `GoodbyeReason.hostDisplaysAsleep` on the wire.
    /// Thrown by the session rather than by a connect attempt, exactly as
    /// `stoppedByHost` above is, and for the same reason: redialling would
    /// find the same dark screen and end the same way, so only a person
    /// waking it changes the answer.
    case hostDisplaysAsleep
}

/// What a session connects as: a session streams exactly
/// one of two targets, and the target is named explicitly when the session
/// is set up." `.hostScreen` names the display by its stable
/// `HostScreenListEntry.displayIdentity`, never a raw token: a token is
/// minted fresh by whichever `hostScreenList` this connect's own
/// `authenticatedHello` provokes, so nothing from an earlier connection's
/// offer could be replayed into this one even if a caller tried.
public enum SessionTarget: Equatable, Sendable {
    case sessionCanvas
    case hostScreen(displayIdentity: String)
}

/// What `connect()` returns -- the two targets' replies carry nothing in
/// common (a canvas display ID versus a captured display's own geometry and
/// resume ticket), so this is not a widening of one shared shape but a
/// choice between two, matching `SessionTarget` case for case.
public enum ConnectOutcome: Equatable, Sendable {
    /// `hostScreenOffer` is `docs/host-screen-design.md` §2.3's pushed offer, read before
    /// `canvasRequest` is ever sent on this same connection: every display
    /// this machine is armed for, or empty when it is not armed at all. Never
    /// a second, later message -- this connect's own offer is the only one
    /// it will ever receive.
    case canvas(displayID: UInt32, hostScreenOffer: [HostScreenListEntry])
    case hostScreen(geometry: SessionSurfaceGeometry, resumeTicket: Data)
}

/// What this pairing attempt did about registering a presence credential.
/// Never affects whether pairing itself succeeded: registering a credential
/// is never required for pairing to succeed.
public enum PresenceCredentialRegistrationOutcome: Equatable, Sendable {
    /// No `PresenceCredentialProviding` was given to register with.
    case notOffered
    case registered(PresenceCredentialRegistration)
    /// `line` is `PresenceCredentialRegistrationCopy.line(for:)`, already
    /// turned into a sentence -- computed once, here, since nothing later
    /// still has the thrown error to translate.
    case failed(line: String)

    var registration: PresenceCredentialRegistration? {
        if case let .registered(registration) = self {
            return registration
        }
        return nil
    }
}

public struct PairingApproval: Equatable, Sendable {
    public let hostPublicKey: Data
    public let tlsCertificateHash: Data?
    public let presenceCredentialRegistration: PresenceCredentialRegistrationOutcome

    public init(
        hostPublicKey: Data,
        tlsCertificateHash: Data?,
        presenceCredentialRegistration: PresenceCredentialRegistrationOutcome = .notOffered
    ) {
        self.hostPublicKey = hostPublicKey
        self.tlsCertificateHash = tlsCertificateHash
        self.presenceCredentialRegistration = presenceCredentialRegistration
    }
}

/// Observes the owned-canvas lifecycle so a presentation surface cannot accept
/// input outside an active session.
public protocol CanvasLifecycleObserving: Sendable {
    /// Reconfigures the input mapper for this session's own surface --
    /// always called, and always awaited to completion, before
    /// `canvasDidBecomeReady()`. `ClientViewportController` is an actor,
    /// reentrant across `canvasDidBecomeReady()`'s own suspension inside a
    /// real drawable-size round trip; a pointer event queued during that
    /// suspension already sees the gate open, so the mapper it maps
    /// through must already be correct by the time that gate opens, not
    /// after.
    func updateMapper(geometry: SessionSurfaceGeometry) async
    func canvasDidBecomeReady() async
    func canvasDidEnd() async
}

public actor ClientSessionController {
    private let transport: any SensoriumControlTransport
    private let identity: DeviceIdentity?
    /// `nil` for every caller that does not offer one -- pairing then sends
    /// no `presenceCredential` at all, exactly today's wire shape. Only
    /// `pair()` ever calls this; a session already past pairing has nothing
    /// left to register.
    private let credentialProvider: (any PresenceCredentialProviding)?
    /// Set once pairing has approved a host; every later session must prove it.
    private let pinnedHostPublicKey: Data?
    private var canvasDisplayID: UInt32?
    /// The display a `.hostScreen` session is streaming, once `hostScreenReady`
    /// has named it. A host-screen session creates no canvas, so this, not
    /// `canvasDisplayID`, is what says it is live -- and its size, not the
    /// session canvas's fixed preset, is what bounds every coordinate it
    /// sends.
    private var hostScreenGeometry: SessionSurfaceGeometry?
    /// Set only when this actor's own `connect()` both requested and had
    /// confirmed a second canvas. Not how a live session gains or loses its
    /// second display any more -- docs/ux-spec.md's "Displays" menu does
    /// that through `SensoriumMessage.displayCount(_:)`, sent by
    /// `ClientSessionRunner` at any point after connect, with its reply
    /// verified by `verifyLiveCanvasReady(...)` below rather than read here.
    /// This connect-time path remains for a caller with nothing to toggle
    /// later (`requestSecondCanvas` below) and is what this actor's own
    /// tests exercise directly.
    private var secondCanvasDisplayID: UInt32?
    private var canvasObserver: (any CanvasLifecycleObserving)?
    /// Every session asks for this canvas first; sending it explicitly
    /// (instead of `nil`) gives `connect()` something a real echo can match,
    /// so `hostSupportsSurfaceIDs` distinguishes a host that understands the
    /// field from one that has never heard of it. A second canvas — asked
    /// for only once that echo proves the host supports `surfaceID` at all —
    /// always requests `secondarySurfaceID`.
    private static let primarySurfaceID: UInt32 = 0
    private static let secondarySurfaceID: UInt32 = 1
    /// Whether this session should ask for a second canvas at connect,
    /// unrelated to whether one can be added or removed live afterwards --
    /// see `secondCanvasDisplayID`'s own note. A session always starts at
    /// one display; the live "Displays" menu is the only way a second one
    /// opens.
    private let requestSecondCanvas: Bool
    /// This session's own counter for `SensoriumMessage.input`'s `sequence`
    /// tag -- see `SessionMetricStage.inputRoundTrip`.
    private var nextInputSequence: UInt64 = 0
    /// Sequence -> the moment this session sent it, so a later `inputApplied`
    /// can be turned into an elapsed round trip. Bounded, not exact over the
    /// whole session: a host that never replies -- an old build, or every
    /// reply simply lost -- must not grow this forever, so the oldest entry
    /// is evicted once the bound is reached, the same trade `LatencySamples`
    /// already makes for the same reason.
    private static let pendingInputSendCapacity = 512
    private var pendingInputSends: [UInt64: Int64] = [:]
    /// Set once `connect()` sees the host echo `primarySurfaceID` back. A
    /// host that predates `surfaceID` leaves it unset instead.
    public private(set) var hostSupportsSurfaceIDs = false
    /// The host's own name, from the primary canvas's `canvasReady`. `nil`
    /// from a host that predates the field or has none configured; the
    /// window title falls back to the address either way.
    public private(set) var hostMachineName: String?
    /// Whether the second canvas was actually opened this session — false
    /// whenever `requestSecondCanvas` is false, or the host turned out not
    /// to support `surfaceID` at all.
    public var didOpenSecondCanvas: Bool { secondCanvasDisplayID != nil }

    public init(
        transport: any SensoriumControlTransport,
        identity: DeviceIdentity? = nil,
        credentialProvider: (any PresenceCredentialProviding)? = nil,
        pinnedHostPublicKey: Data? = nil,
        requestSecondCanvas: Bool = false
    ) {
        self.transport = transport
        self.identity = identity
        self.credentialProvider = credentialProvider
        self.pinnedHostPublicKey = pinnedHostPublicKey
        self.requestSecondCanvas = requestSecondCanvas
    }

    public func setCanvasObserver(_ observer: any CanvasLifecycleObserving) {
        canvasObserver = observer
    }

    /// One-time ceremony: the user reads the code off the host and types it here.
    /// Returns every trust anchor issued by the one-time ceremony.
    public func pair(deviceName: String, code: String) async throws -> PairingApproval {
        guard let identity else {
            throw ClientSessionError.identityRequired
        }
        let credentialOutcome = await Self.attemptCredentialRegistration(credentialProvider)
        // The host will not replace what an already-paired machine has on
        // file -- its recorded name, its registered presence credential --
        // for a request that has not proven it holds the identity key it
        // names, and a pairing connection sends no authenticated hello
        // ahead of this message. This signature is that proof.
        let signature = try identity.sign(SensoriumFrameCodec.pairRequestTranscript(
            deviceName: deviceName,
            clientPublicKey: identity.publicKey,
            code: code,
            presenceCredential: credentialOutcome.registration
        ))
        try await transport.send(.pairRequest(
            deviceName: deviceName,
            publicKey: identity.publicKey,
            code: code,
            presenceCredential: credentialOutcome.registration,
            signature: signature
        ))
        switch try await transport.receive() {
        case let .pairApproved(hostPublicKey, tlsCertificateHash, signature):
            guard let signature,
                  DeviceIdentity.verify(
                    signature: signature,
                    message: SensoriumFrameCodec.pairApprovalTranscript(
                        deviceName: deviceName,
                        clientPublicKey: identity.publicKey,
                        tlsCertificateHash: tlsCertificateHash
                    ),
                    publicKey: hostPublicKey
                  ) else {
                throw ClientSessionError.hostKeyMismatch
            }
            return PairingApproval(
                hostPublicKey: hostPublicKey,
                tlsCertificateHash: tlsCertificateHash,
                presenceCredentialRegistration: credentialOutcome
            )
        case let .pairRejected(reason):
            throw ClientSessionError.pairingRejected(reason)
        default:
            throw ClientSessionError.unexpectedMessage
        }
    }

    /// The one part of "shown the moment a new machine asks to pair" `pairRequest`
    /// itself cannot be: it already carries a typed code. Sent as soon as the
    /// Code screen appears, before any digits exist, carrying only the name
    /// the later `pairRequest` will also carry. Fire-and-forget -- the host
    /// acts on it with no reply, so this never waits on `transport.receive()`.
    public func sendPairIntent(deviceName: String) async throws {
        try await transport.send(.pairIntent(deviceName: deviceName))
    }

    /// Never a pairing failure: a credential is never required for pairing
    /// to succeed. A machine with nothing to offer, or whose attempt fails,
    /// still pairs and uses the session canvas.
    private static func attemptCredentialRegistration(
        _ provider: (any PresenceCredentialProviding)?
    ) async -> PresenceCredentialRegistrationOutcome {
        guard let provider else {
            return .notOffered
        }
        do {
            return .registered(try await provider.register())
        } catch {
            return .failed(line: PresenceCredentialRegistrationCopy.line(for: error))
        }
    }

    /// Races the handshake against a deadline so a host that never answers
    /// surfaces as a timeout instead of an indefinite wait. `target` names
    /// which of the two a session streams: the target is named explicitly
    /// when the session is set up; `.sessionCanvas` is the default.
    ///
    /// `timeout`, when given, overrides the deadline outright. Left `nil`
    /// (every real caller), the deadline is chosen from `timeouts` by
    /// `target`: `.hostScreen` waits `hostScreenGrant` -- long enough for a
    /// person at the host to answer that machine's own confirmation prompt --
    /// while `.sessionCanvas` keeps waiting only `canvasCreation`, since no
    /// other person's answer can be behind it.
    public func connect(
        deviceName: String,
        target: SessionTarget = .sessionCanvas,
        resumeTicket: Data? = nil,
        timeout: TimeInterval? = nil,
        timeouts: SessionTimeouts = .remoteDefault
    ) async throws -> ConnectOutcome {
        let deadline = timeout ?? Self.defaultTimeout(for: target, timeouts: timeouts)
        return try await withThrowingTaskGroup(of: ConnectOutcome.self) { group in
            group.addTask { [self] in
                try await performConnect(deviceName: deviceName, target: target, resumeTicket: resumeTicket)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(deadline))
                throw ClientSessionError.timedOut
            }
            do {
                guard let outcome = try await group.next() else {
                    throw ClientSessionError.unexpectedMessage
                }
                group.cancelAll()
                return outcome
            } catch {
                group.cancelAll()
                if error is ClientSessionError, case ClientSessionError.timedOut = error {
                    await transport.close()
                }
                throw error
            }
        }
    }

    private static func defaultTimeout(for target: SessionTarget, timeouts: SessionTimeouts) -> TimeInterval {
        switch target {
        case .sessionCanvas:
            return timeouts.canvasCreation
        case .hostScreen:
            return timeouts.hostScreenGrant
        }
    }

    private func performConnect(deviceName: String, target: SessionTarget, resumeTicket: Data?) async throws -> ConnectOutcome {
        if let identity {
            let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
                protocolVersion: 1,
                deviceName: deviceName,
                publicKey: identity.publicKey
            )
            let signature = try identity.sign(transcript)
            try await transport.send(.authenticatedHello(
                protocolVersion: 1,
                deviceName: deviceName,
                publicKey: identity.publicKey,
                signature: signature
            ))
        } else {
            try await transport.send(.hello(protocolVersion: 1, deviceName: deviceName))
        }
        switch target {
        case .sessionCanvas:
            let (displayID, hostScreenOffer) = try await performCanvasConnect()
            return .canvas(displayID: displayID, hostScreenOffer: hostScreenOffer)
        case let .hostScreen(displayIdentity):
            return try await performHostScreenConnect(displayIdentity: displayIdentity, presentedTicket: resumeTicket)
        }
    }

    /// Never sends `canvasRequest`: a session never mixes canvas and host
    /// screen, and `HostSessionController`'s own one-shape-per-connection
    /// gate means a connection that ever sends one can no longer become
    /// this.
    private func performHostScreenConnect(displayIdentity: String, presentedTicket: Data?) async throws -> ConnectOutcome {
        let offer = try await transport.receive()
        if case let .hostScreenRefused(reason) = offer {
            throw ClientSessionError.hostScreenRefused(reason)
        }
        guard case let .hostScreenList(displays, challenge) = offer else {
            throw ClientSessionError.unexpectedMessage
        }
        // The list is per connection, minted fresh by this connect's own
        // `hostScreenList` -- never the token from an earlier offer, which
        // `displayIdentity` (the display's stable identity, unlike `opaqueToken`)
        // exists specifically so a caller never has to carry forward. A
        // duplicate identity is refused the same way a missing one is: which
        // of two identically-named entries was meant is not this viewer's to
        // guess at, so `first(where:)` never silently picks one.
        let matchingEntries = displays.filter { $0.displayIdentity == displayIdentity }
        guard matchingEntries.count == 1, let entry = matchingEntries.first else {
            throw ClientSessionError.hostScreenRefused("host-screen-display-unavailable")
        }
        let proof: HostScreenPresenceProof
        if let presentedTicket {
            // A held ticket is a self-contained substitute for a fresh
            // presence check, never a supplement to one -- this
            // branch never touches `credentialProvider` or signs the
            // challenge this offer just minted. A ticket the host refuses
            // is never retried as `.signed` on this same connection; the
            // caller's own retry policy (it either presents a valid
            // ticket or stops) decides what happens next, not this method.
            proof = .resumeTicket(presentedTicket)
        } else {
            guard let credentialProvider else {
                throw ClientSessionError.hostScreenRefused("host-screen-credential-unknown")
            }
            proof = try await Self.hostScreenPresenceProof(challenge: challenge, credentialProvider: credentialProvider)
        }
        try await transport.send(.hostScreenRequest(token: entry.opaqueToken, presence: proof))
        let reply = try await transport.receive()
        if case let .hostScreenRefused(reason) = reply {
            throw ClientSessionError.hostScreenRefused(reason)
        }
        guard case let .hostScreenReady(geometry, resumeTicket) = reply else {
            throw ClientSessionError.unexpectedMessage
        }
        // Mirrors `performCanvasConnect`'s own `canvasDidBecomeReady()` call:
        // without it the window's `isCanvasReady` gate never opens, so a
        // decoded frame arriving over this connection would never be shown.
        // `hostScreenReady` carries no host signature to verify first, unlike
        // `canvasReady` -- the presence-signed `hostScreenRequest` this reply
        // answers is this connection's own proof. `updateMapper` is awaited
        // to completion first: a real display is whatever size it already
        // is, never the session-canvas preset, and the mapper must already
        // reflect that before the gate below can open.
        hostScreenGeometry = geometry
        await canvasObserver?.updateMapper(geometry: geometry)
        await canvasObserver?.canvasDidBecomeReady()
        return .hostScreen(geometry: geometry, resumeTicket: resumeTicket)
    }

    /// Signs the exact bytes a `hostScreenList` offer challenged, for the
    /// connect-time host-screen flow this actor drives.
    public nonisolated static func hostScreenPresenceProof(
        challenge: Data,
        credentialProvider: any PresenceCredentialProviding
    ) async throws -> HostScreenPresenceProof {
        let registration = try await credentialProvider.register()
        let signature = try await credentialProvider.sign(challenge: challenge)
        return .signed(
            credentialID: registration.credentialID,
            credentialFormat: registration.credentialFormat,
            signature: signature
        )
    }

    /// The host pushes its host-screen offer unprompted, right after
    /// `authenticatedHello`, before `canvasRequest` is ever sent -- so
    /// this reads exactly one message first, but only when this connect sent
    /// `authenticatedHello` in the first place: a host never offers anything
    /// to a connection that only ever sent the unauthenticated `hello`,
    /// exactly like `HostNetworkSession`'s own push, which is conditioned on
    /// the same message. `hostScreenList` is this connect's own offer;
    /// `hostScreenRefused` (an unarmed machine) is the same offer, empty;
    /// anything else is a host this viewer does not understand.
    private func performCanvasConnect() async throws -> (displayID: UInt32, hostScreenOffer: [HostScreenListEntry]) {
        var hostScreenOffer: [HostScreenListEntry] = []
        if identity != nil {
            let offer = try await transport.receive()
            switch offer {
            case let .hostScreenList(displays, _):
                hostScreenOffer = displays
            case .hostScreenRefused:
                hostScreenOffer = []
            default:
                throw ClientSessionError.unexpectedMessage
            }
        }
        try await transport.send(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: Self.primarySurfaceID))
        let response = try await transport.receive()
        if case let .canvasRefused(reason, _) = response {
            // Losing surface 0 is not a degraded session, it is no session:
            // there is nothing to show, nothing to send input to, and nothing
            // to fall back to. Unlike a refused second canvas this ends the
            // connect, and the surface the refusal names cannot change that,
            // so it is not inspected here.
            throw ClientSessionError.canvasRefused(reason)
        }
        guard case let .canvasReady(displayID, logicalWidth, logicalHeight, hostSignature, echoedSurfaceID, hostName) = response,
              logicalWidth == 1920,
              logicalHeight == 1200 else {
            throw ClientSessionError.unexpectedMessage
        }
        switch echoedSurfaceID {
        case nil:
            hostSupportsSurfaceIDs = false
        case Self.primarySurfaceID:
            hostSupportsSurfaceIDs = true
        default:
            throw ClientSessionError.surfaceIDMismatch
        }
        try verifyCanvasReadySignature(
            hostSignature: hostSignature,
            displayID: displayID,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            surfaceID: echoedSurfaceID
        )
        canvasDisplayID = displayID
        hostMachineName = hostName
        // Restores the session-canvas preset before the gate opens -- the
        // same ordering `performHostScreenConnect` needs, for a window
        // whose mapper a prior host-screen connect on this same session
        // may have reconfigured.
        await canvasObserver?.updateMapper(geometry: .sessionCanvasDefault)
        await canvasObserver?.canvasDidBecomeReady()
        try await requestSecondCanvasIfConfigured()
        return (displayID, hostScreenOffer)
    }

    /// A second canvas is only ever asked for here, as part of the same
    /// connect that established the first — never later, and never at all
    /// unless the primary canvas's echo already proved the host understands
    /// `surfaceID`.
    private func requestSecondCanvasIfConfigured() async throws {
        guard requestSecondCanvas, hostSupportsSurfaceIDs else {
            return
        }
        try await transport.send(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: Self.secondarySurfaceID))
        let response = try await transport.receive()
        if case let .canvasRefused(_, refusedSurfaceID) = response {
            guard refusedSurfaceID == Self.secondarySurfaceID else {
                // A refusal naming a surface this viewer did not just ask
                // about is a protocol violation, not a canvas to give up on.
                throw ClientSessionError.surfaceIDMismatch
            }
            // The graceful outcome this message exists for: the primary canvas
            // and the session are untouched and this viewer is single-window
            // for the rest of the session. There is no retry — a second canvas
            // is only ever created here, and asking again later is exactly the
            // display-allocator race the host's creation gate refuses.
            //
            // The shipped host never sends `canvasRefused` for its creation
            // gate, because no request reaches that gate while a creation
            // holds it; it is correct against the protocol and live once the
            // host's readiness wait stops blocking its main actor. Unsigned,
            // unlike `canvasReady`, and it does not need to be: a refusal
            // grants nothing.
            return
        }
        guard case let .canvasReady(displayID, logicalWidth, logicalHeight, hostSignature, echoedSurfaceID, _) = response,
              logicalWidth == 1920,
              logicalHeight == 1200 else {
            throw ClientSessionError.unexpectedMessage
        }
        guard echoedSurfaceID == Self.secondarySurfaceID else {
            throw ClientSessionError.surfaceIDMismatch
        }
        try verifyCanvasReadySignature(
            hostSignature: hostSignature,
            displayID: displayID,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            surfaceID: echoedSurfaceID
        )
        secondCanvasDisplayID = displayID
    }

    /// Verifies a `canvasReady` this session's own `connect()` did not
    /// receive -- docs/ux-spec.md's live "Displays" control mints its own
    /// reply, read by `ClientSessionRunner`'s already-running receive loop
    /// rather than by this actor, so there is exactly one reader of the
    /// connection for the whole session. Same check `connect()` already
    /// applies to the replies it does read itself.
    public func verifyLiveCanvasReady(
        displayID: UInt32,
        logicalWidth: Int,
        logicalHeight: Int,
        hostSignature: Data?,
        surfaceID: UInt32?
    ) throws {
        try verifyCanvasReadySignature(
            hostSignature: hostSignature,
            displayID: displayID,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            surfaceID: surfaceID
        )
    }

    private func verifyCanvasReadySignature(
        hostSignature: Data?,
        displayID: UInt32,
        logicalWidth: Int,
        logicalHeight: Int,
        surfaceID: UInt32?
    ) throws {
        guard let pinnedHostPublicKey, let identity else {
            return
        }
        guard let hostSignature,
              DeviceIdentity.verify(
                signature: hostSignature,
                message: SensoriumFrameCodec.canvasReadyTranscript(
                    displayID: displayID,
                    logicalWidth: logicalWidth,
                    logicalHeight: logicalHeight,
                    clientPublicKey: identity.publicKey,
                    surfaceID: surfaceID
                ),
                publicKey: pinnedHostPublicKey
              ) else {
            throw ClientSessionError.hostKeyMismatch
        }
    }

    public func disconnect(reason: String = "client-disconnected") async {
        // A host-screen session has no canvas, and it is the one that can
        // least afford to skip this: what it leaves held is held on somebody's
        // own machine, not on a private canvas nobody else can see.
        guard canvasDisplayID != nil || hostScreenGeometry != nil else {
            await transport.close()
            return
        }
        _ = try? await transport.send(.input(.releaseAllInput, surfaceID: nil))
        // Each opened surface holds its own input state on the host; releasing
        // only the primary would leave the second canvas's input stuck.
        if secondCanvasDisplayID != nil {
            _ = try? await transport.send(.input(.releaseAllInput, surfaceID: Self.secondarySurfaceID))
        }
        _ = try? await transport.send(.goodbye(reason: reason))
        canvasDisplayID = nil
        secondCanvasDisplayID = nil
        hostScreenGeometry = nil
        await canvasObserver?.canvasDidEnd()
        await transport.close()
    }

    public func sendPointer(_ point: CanvasInputPoint) async throws {
        try await sendInput(.pointerMoved(x: point.x, y: point.y))
    }

    /// A live host-screen mode change moves the display's own bound, and
    /// `isWithinTarget` below must track it or a coordinate inside the new,
    /// larger picture but outside the one this session connected to is
    /// refused for the rest of the session. `ClientSessionRunner` calls this
    /// from its own `hostScreenModeApplied` handling, ahead of the callback a
    /// viewer or probe uses to move its mapper, so the two never disagree
    /// about where the display's edge is. A no-op when `hostScreenGeometry`
    /// is `nil`: a canvas session streams no display for any mode change to
    /// be about, and its own bound must never widen because one arrived.
    public func hostScreenModeDidApply(geometry: SessionSurfaceGeometry) {
        guard hostScreenGeometry != nil else { return }
        hostScreenGeometry = geometry
    }

    /// Tells the host what this viewer's drawable actually is, so it streams
    /// that resolution instead of a constant. Validated here as well as on the
    /// host: a value that could not have come from a real surface is a bug
    /// worth catching on the side that produced it.
    /// `maximumScale` is the user's own cap on what the host may stream, sent
    /// alongside the real drawable rather than by shrinking the dimensions:
    /// the host sizes its encoder from those, and a faked size would tell it
    /// the wrong thing about the window.
    public func sendViewerDrawableSize(
        pixelWidth: Double,
        pixelHeight: Double,
        maximumScale: Double?
    ) async throws {
        try await sendViewerDrawableSize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            surfaceID: nil,
            maximumScale: maximumScale
        )
    }

    /// The second surface's counterpart to
    /// `sendViewerDrawableSize(pixelWidth:pixelHeight:)`, carrying an explicit
    /// `surfaceID` so the host applies it to the right canvas.
    public func sendViewerDrawableSize(
        pixelWidth: Double,
        pixelHeight: Double,
        surfaceID: UInt32,
        maximumScale: Double?
    ) async throws {
        try await sendViewerDrawableSize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            surfaceID: Optional(surfaceID),
            maximumScale: maximumScale
        )
    }

    private func sendViewerDrawableSize(
        pixelWidth: Double,
        pixelHeight: Double,
        surfaceID: UInt32?,
        maximumScale: Double?
    ) async throws {
        guard isSurfaceActive(surfaceID) else {
            throw ClientSessionError.notConnected
        }
        guard StreamScalePolicy.isPlausibleDrawableDimension(pixelWidth),
              StreamScalePolicy.isPlausibleDrawableDimension(pixelHeight),
              maximumScale.map(StreamScalePolicy.isPlausibleMaximumScale) ?? true else {
            throw ClientSessionError.invalidInput
        }
        try await transport.send(.viewerDrawableSize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            surfaceID: surfaceID,
            maximumScale: maximumScale
        ))
    }

    /// Tells the host this canvas's own choice of stream scale, or a return
    /// to `.automatic` -- see `StreamScalePreference`.
    public func sendStreamScalePreference(_ preference: StreamScalePreference) async throws {
        try await sendStreamScalePreference(preference, surfaceID: nil)
    }

    /// The second surface's counterpart, carrying an explicit `surfaceID` so
    /// the host applies it to the right canvas.
    public func sendStreamScalePreference(_ preference: StreamScalePreference, surfaceID: UInt32) async throws {
        try await sendStreamScalePreference(preference, surfaceID: Optional(surfaceID))
    }

    private func sendStreamScalePreference(_ preference: StreamScalePreference, surfaceID: UInt32?) async throws {
        guard isSurfaceActive(surfaceID) else {
            throw ClientSessionError.notConnected
        }
        try await transport.send(.streamScalePreference(preference, surfaceID: surfaceID))
    }

    /// Tells the host which canvas the user is actually looking at, so it can
    /// prefer that canvas when both contend for the one encoder and the one
    /// wire. Sent on genuine focus transitions only — see
    /// `ViewerFocusReporter`, which decides what counts as one.
    ///
    /// `hasViewerFocus: false` means no canvas is focused at all; `surfaceID`
    /// carries no meaning then, and the host clears its preference.
    public func sendViewerFocus(surfaceID: UInt32?, hasViewerFocus: Bool) async throws {
        guard isSurfaceActive(surfaceID) else {
            throw ClientSessionError.notConnected
        }
        try await transport.send(.viewerFocus(surfaceID: surfaceID, hasViewerFocus: hasViewerFocus))
    }

    public func sendInput(_ event: SensoriumInputEvent) async throws {
        try await sendInput(event, surfaceID: nil)
    }

    /// The second surface's counterpart to `sendInput(_:)`, carrying an
    /// explicit `surfaceID` so the host applies it to the right canvas.
    public func sendInput(_ event: SensoriumInputEvent, surfaceID: UInt32) async throws {
        try await sendInput(event, surfaceID: Optional(surfaceID))
    }

    private func sendInput(_ event: SensoriumInputEvent, surfaceID: UInt32?) async throws {
        guard isSurfaceActive(surfaceID) else {
            throw ClientSessionError.notConnected
        }
        guard isWithinTarget(event) else {
            throw ClientSessionError.invalidInput
        }
        let sequence = nextInputSequence
        nextInputSequence += 1
        recordPendingInputSend(sequence: sequence, atNanoseconds: MonotonicClock.nowNanoseconds())
        try await transport.send(.input(event, surfaceID: surfaceID, sequence: sequence))
    }

    private func recordPendingInputSend(sequence: UInt64, atNanoseconds: Int64) {
        if pendingInputSends.count >= Self.pendingInputSendCapacity, let oldest = pendingInputSends.keys.min() {
            pendingInputSends[oldest] = nil
        }
        pendingInputSends[sequence] = atNanoseconds
    }

    /// Resolves one pending `input` this session sent, returning when it was
    /// sent -- `nil` for a sequence this session does not recognise, whether
    /// because it was already resolved, evicted for capacity, or never sent
    /// at all. `ClientSessionRunner`'s receive loop is the only caller: it
    /// owns the connection this session's `inputApplied` replies arrive on.
    public func resolvePendingInputSend(sequence: UInt64) -> Int64? {
        pendingInputSends.removeValue(forKey: sequence)
    }

    /// `nil` and `0` both mean the primary canvas — the wire keeps sending
    /// `nil` for it so an old host sees exactly the bytes it always has.
    private func isSurfaceActive(_ surfaceID: UInt32?) -> Bool {
        switch surfaceID {
        case nil, Self.primarySurfaceID:
            // A host-screen session never creates a canvas, so a gate that
            // only knew about one would refuse every pointer and key it ever
            // sent.
            return canvasDisplayID != nil || hostScreenGeometry != nil
        case Self.secondarySurfaceID:
            return secondCanvasDisplayID != nil
        default:
            return false
        }
    }

    /// Whether this coordinate stands on what this session is actually
    /// streaming. A session canvas is always the fixed preset; a host screen
    /// is whatever size the display already was, which `hostScreenReady`
    /// named -- checked here as well as at the host, because a coordinate
    /// that could not have come from a real surface is worth catching on the
    /// side that produced it.
    private func isWithinTarget(_ event: SensoriumInputEvent) -> Bool {
        let width = hostScreenGeometry.map { Double($0.logicalWidth) } ?? 1920
        let height = hostScreenGeometry.map { Double($0.logicalHeight) } ?? 1200
        func onCanvas(_ x: Double, _ y: Double) -> Bool {
            x.isFinite && y.isFinite && (0...width).contains(x) && (0...height).contains(y)
        }

        switch event {
        case let .pointerMoved(x, y):
            return onCanvas(x, y)
        case let .pointerMovedRelative(deltaX, deltaY):
            return deltaX.isFinite && deltaY.isFinite
        case let .pointerButton(_, _, x, y):
            return onCanvas(x, y)
        case let .scrolled(deltaX, deltaY, x, y, _, _):
            return onCanvas(x, y) && deltaX.isFinite && deltaY.isFinite
        case let .key(_, _, modifiers):
            return modifiers.isSubset(of: .all)
        case .releaseAllInput, .pointerCaptureChanged:
            return true
        }
    }
}

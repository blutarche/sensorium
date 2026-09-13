import Foundation

public enum SensoriumProtocolError: Error, Equatable {
    case frameTooShort
    case frameLengthMismatch
    case frameTooLarge
    case unsupportedMessage
    case malformedMessage
}

public enum SensoriumMessage: Equatable, Sendable {
    case hello(protocolVersion: UInt16, deviceName: String)
    case authenticatedHello(protocolVersion: UInt16, deviceName: String, publicKey: Data, signature: Data)
    case canvasRequest(logicalWidth: Int, logicalHeight: Int, scale: Int, surfaceID: UInt32?)
    /// `surfaceID` names one of the (currently at most two) session-owned
    /// canvases. `hostName` is the host's own machine name, so the viewer's
    /// window title can say who it is talking to instead of only the
    /// address dialled; `nil` when the host has no name configured, and the
    /// viewer falls back to the address.
    case canvasReady(displayID: UInt32, logicalWidth: Int, logicalHeight: Int, hostSignature: Data?, surfaceID: UInt32?, hostName: String? = nil)
    /// `surfaceID` routes the event to one of the (currently at most two)
    /// session-owned canvases; `nil` means canvas 0.
    /// The other answer to a `canvasRequest`: this canvas was not created,
    /// and why. A separate message rather than a flag on `canvasReady`, so a
    /// refusal decodes as `.unrecognized` rather than as a canvas that may
    /// be drawn on. `surfaceID` names the surface that was refused, so a
    /// refusal of the second canvas is distinguishable from a refusal of
    /// the first, which ends the session.
    case canvasRefused(reason: String, surfaceID: UInt32?)
    /// `sequence` is this viewer's own monotonic tag for
    /// `SessionMetricStage.inputRoundTrip` -- a counter, never anything
    /// about what the event contains. `nil` means the event is untagged and
    /// no round trip is measured for it.
    case input(SensoriumInputEvent, surfaceID: UInt32?, sequence: UInt64? = nil)
    /// The host's acknowledgement of one `input` message, sent only once the
    /// named event has actually been injected -- never for one the host
    /// refused or suppressed, since a refusal is already reported another
    /// way and is not a round trip worth measuring. Echoes `sequence`
    /// unchanged so the viewer can match it back to the send it timed.
    case inputApplied(sequence: UInt64)
    case goodbye(reason: String)
    /// Sent the moment a device's own pairing-code screen appears, before
    /// it has a code to send -- ux-spec.md's "shown the moment a new machine
    /// asks to pair," the true first moment, since `pairRequest` already
    /// carries a typed code and so cannot be it. Carries only `deviceName`:
    /// there is no key to offer yet (this device may not even have paired
    /// before) and nothing here is ever trusted as more than an unverified
    /// claim -- see `HostSessionController.onPairingRequested`'s own doc
    /// comment, which this message reaches the same way `pairRequest`
    /// already does.
    case pairIntent(deviceName: String)
    /// docs/ux-spec.md's "Clipboard: on or off," on the wire -- a viewer-to-host
    /// message, live for the session it arrives on, never a launch-time
    /// choice. `false` stops both directions at the host: nothing it polls
    /// from its own pasteboard is sent, and nothing the viewer sends is
    /// applied. `true` resumes without replaying anything that changed
    /// while off -- see `ClipboardSyncEngine.setEnabled(_:)`, the one place
    /// that owns what either transition actually does. A session begins
    /// with sharing on; this message only ever changes it from there.
    case clipboardSharing(enabled: Bool)
    /// `presenceCredential` is docs/host-screen-design.md §6.3's registration, riding the
    /// pairing exchange rather than a message of its own: "whose public
    /// half is registered with this host when the devices pair." `nil` is
    /// the ordinary case for a device that can offer neither acceptable
    /// strength (CLAUDE.md's own invariant: it "may pair and use a session
    /// canvas, but may not register for host screen") or one that simply
    /// has not tried yet -- pairing itself never requires a credential.
    ///
    /// `signature` is this machine's own proof that it holds `publicKey`'s
    /// private half: its signature over
    /// `SensoriumFrameCodec.pairRequestTranscript(...)`, which covers every
    /// value this request asks the host to write. Without it a valid code --
    /// which proves only that someone read six digits off the host -- is all
    /// that stands between a request and an already-paired machine's
    /// registered name and credential, so the host refuses those writes for
    /// an already-approved key that has not proven possession. `nil` is a
    /// machine that predates this proof: it still pairs, and still cannot
    /// change what an already-approved key has on file.
    case pairRequest(deviceName: String, publicKey: Data, code: String, presenceCredential: PresenceCredentialRegistration? = nil, signature: Data? = nil)
    case pairApproved(hostPublicKey: Data, tlsCertificateHash: Data?, signature: Data?)
    case pairRejected(reason: String)
    /// Carried on the control stream so the client can read host capture
    /// timestamps on its own clock. Both timestamps are monotonic nanoseconds
    /// from their own machine and share no origin.
    case timeSyncRequest(clientTimeNanoseconds: Int64)
    case timeSyncReply(clientTimeNanoseconds: Int64, hostTimeNanoseconds: Int64)
    /// The viewer's current drawable size in real backing pixels. The host
    /// derives the stream scale from it (`StreamScalePolicy`) so the encoded
    /// resolution follows the window instead of a constant. A viewer that
    /// sends no drawable size is streamed at `StreamScalePolicy.defaultScale`.
    /// `surfaceID` identifies which canvas the size applies to; see `input`.
    /// `maximumScale` is the viewer's own cap on the streamed scale, folded
    /// into the host's clamp alongside the ceiling it learns by measurement;
    /// `nil` means no cap. A cap rather than a faked drawable, because the
    /// pixel dimensions are what tell the encoder how big the window really
    /// is.
    case viewerDrawableSize(pixelWidth: Double, pixelHeight: Double, surfaceID: UInt32?, maximumScale: Double?)
    /// Which canvas the viewer is actually looking at, so the host can prefer
    /// that canvas's frames when two of them contend for one encoder and one
    /// wire. Three states, not two: `hasViewerFocus == false` means the user
    /// is looking at a local app and no canvas is focused, which is why it is
    /// a separate field rather than an absent `surfaceID` -- absent means
    /// canvas 0 everywhere else on this wire. Sent on genuine focus
    /// transitions only. A host that never receives one schedules both
    /// canvases by fair share, exactly as it does without this message.
    case viewerFocus(surfaceID: UInt32?, hasViewerFocus: Bool)
    /// Host-measured, per-surface latency and drop counts, sent periodically
    /// while a session streams. The host sends it regardless of whether the
    /// viewer has a telemetry surface showing.
    case telemetry(surfaces: [SurfaceTelemetrySample])
    /// The same measurement in the other direction: what one surface's
    /// stream looked like from the viewer's end of the wire, sent
    /// periodically while a session runs. The host measures its own stages
    /// and can see none of these, so without it a link that cannot carry
    /// what the host is producing is indistinguishable from one that can.
    case viewerTelemetry(ViewerTelemetrySample)
    /// A person's explicit choice of stream scale, or a return to
    /// `.automatic` -- see `StreamScalePreference`. `surfaceID` identifies
    /// which canvas the choice applies to; see `input`.
    case streamScalePreference(StreamScalePreference, surfaceID: UInt32?)
    /// The viewer's own choice of how many session displays this connection
    /// should have, `1` or `2` -- docs/ux-spec.md: "how many displays" is
    /// entirely the viewer's, applied within whatever the host permits, not
    /// a setting on the host. Session-wide, so it carries no `surfaceID` of
    /// its own; it always names the *second* canvas's presence, since the
    /// first is unconditionally whatever a `canvasRequest` for it already
    /// established. Sendable at connect and again at any later point to
    /// change it live: the host brings the second canvas up or takes it
    /// down to match and reports the outcome through the same
    /// `canvasReady`/`canvasRefused` pair an explicit second `canvasRequest`
    /// already uses for exactly that surface.
    case displayCount(Int)
    /// The host's offer of its own displays, sent instead of `canvasReady`
    /// on the host-screen path. `challenge` is single-use, minted for this
    /// offer, and is what `hostScreenRequest`'s presence proof must sign --
    /// see docs/host-screen-design.md §6.3.
    case hostScreenList(displays: [HostScreenListEntry], challenge: Data)
    /// The viewer's choice from a `hostScreenList` offer, naming a
    /// previously-minted `token` and proving presence for this session.
    /// There is deliberately no field here for a credential strength, an
    /// armed-display description, or a device key: everything this message
    /// can name is a reference to something the host already minted or
    /// already registered, never an assertion the host would have to trust
    /// -- a viewer-asserted strength or description is never trusted, only
    /// referenced.
    case hostScreenRequest(token: Data, presence: HostScreenPresenceProof)
    /// The host-screen answer to a `hostScreenRequest` that was admitted.
    /// `geometry` is the target display's own logical size and backing
    /// scale (docs/host-screen-design.md §5.1); `resumeTicket` is minted fresh for this session
    /// and presented back on a silent reconnect (docs/host-screen-design.md §6.5).
    case hostScreenReady(geometry: SessionSurfaceGeometry, resumeTicket: Data)
    /// The other answer to a `hostScreenRequest`: refused, and why. A
    /// separate message rather than a flag, the same reasoning
    /// `canvasRefused` already follows -- a mode field on `canvasRequest`
    /// would let an old host silently misread it as an ordinary canvas
    /// request.
    case hostScreenRefused(reason: String)
    /// Every display mode the host screen this session streams can be set
    /// to, and which one it is on now. Sent unprompted right after
    /// `hostScreenReady`, and again after every change the viewer asks for
    /// and the host applies, so the viewer never has to ask for the list
    /// and never holds one the host has since moved on from. Host to
    /// viewer only.
    case hostScreenModeList(modes: [HostScreenModeEntry], currentModeID: String)
    /// The viewer's pick from that list, naming one `HostScreenModeEntry.modeID`
    /// the host itself minted for this session. There is deliberately no
    /// field here for a width, a height, or a scale: a message that
    /// described a mode rather than naming one the host already offered
    /// would be a viewer asking this host to configure a display to
    /// something macOS never said it could do -- see CLAUDE.md's own
    /// "choosing among the modes macOS already offers".
    case hostScreenModeRequest(modeID: String)
    /// The host applied the mode and restarted its capture at the new size.
    /// `geometry` is the target display's own logical size and backing
    /// scale after the change, exactly what `hostScreenReady` carries for
    /// the size it started at.
    case hostScreenModeApplied(geometry: SessionSurfaceGeometry, currentModeID: String)
    /// The other answer: the mode did not change, and why. The session
    /// itself is untouched -- a refused mode change is never a refused
    /// session, and the display is on whatever mode it was already on.
    case hostScreenModeRefused(reason: String)
    /// A wire `type` this build does not know, from a peer running a
    /// different protocol revision. Decode-only: nothing ever constructs this
    /// to send, and `encode` refuses it -- fabricating wire bytes for it
    /// would itself be inventing a new message type.
    case unrecognized(type: String)
}

/// The reasons a `canvasRefused` can name. Stable tokens rather than prose,
/// like `pairRejected`'s, so a client can branch on one.
public enum CanvasRefusalReason {
    /// Another canvas creation held the host's single-flight creation gate.
    /// Serialising creation is a safety property — overlapping registrations
    /// corrupt the display-ID allocator — so this is a canvas the client does
    /// not get, not one worth retrying into.
    public static let creationInProgress = "canvas-creation-in-progress"
    /// This host process cannot open a session canvas: macOS refused every
    /// identity it has, or capture on this machine delivers nothing, so there
    /// is no canvas it could stream whatever it created. Retrying from the
    /// viewer cannot help; only the host being opened again at the machine
    /// changes the answer.
    public static let canvasUnavailable = "canvas-unavailable"
}

/// The reasons a `goodbye` can name. Stable tokens, like
/// `CanvasRefusalReason`'s: most endings are a transport that died and need
/// no name, but one of them is a decision a person made and the viewer has
/// to be able to tell the two apart.
public enum GoodbyeReason {
    /// A person at the host ended this session from that machine, through the
    /// host's own Stop control. The viewer never redials this: an ending the
    /// operator chose is not a dropout, and redialling into it would make
    /// Stop look like it did nothing.
    public static let stoppedByHost = "stopped-by-host"
    /// The host's capture delivered nothing at all and could not be brought
    /// back, so the session had no picture to send. Only quitting and
    /// opening the host at that machine changes the answer, and the viewer
    /// must not redial into it forever.
    public static let captureUnavailable = "capture-unavailable"
    /// The same silence with a cause a person can fix in a second: the
    /// host's own displays were asleep and would not wake, and macOS draws
    /// nothing at all while they are. Told apart from `captureUnavailable`
    /// because the remedies are nothing alike -- one is a host that has to
    /// be reopened, the other is a screen that has to come back on.
    public static let hostDisplaysAsleep = "host-displays-asleep"
}

/// One display the host is offering, docs/host-screen-design.md §5.4's exact five fields plus
/// `opaqueToken`. Never a raw `CGDirectDisplayID` -- that is not stable
/// across sleep or replug, and a viewer choosing an ID is a viewer choosing
/// what to capture. The viewer echoes `opaqueToken` back verbatim in
/// `hostScreenRequest`; it names nothing on its own without the host's own
/// per-session record of what it was minted for.
public struct HostScreenListEntry: Equatable, Sendable {
    public let opaqueToken: Data
    public let label: String
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let backingScale: Double
    public let isBuiltin: Bool
    /// The same physical display's own stable identity -- docs/host-screen-design.md §5.4's
    /// `HostScreenDisplayIdentity`, the one the arming record already
    /// uses, opaque to the viewer and not secret (the token stays the
    /// one-shot capability; this is what lets a viewer say "the same
    /// display as last time" across two separate offers, since a token is
    /// deliberately per-connection and a label is not unique). The same
    /// value for the same display on every offer this host ever makes,
    /// including across a restart.
    public let displayIdentity: String

    public init(
        opaqueToken: Data,
        label: String,
        logicalWidth: Int,
        logicalHeight: Int,
        backingScale: Double,
        isBuiltin: Bool,
        displayIdentity: String
    ) {
        self.opaqueToken = opaqueToken
        self.label = label
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.backingScale = backingScale
        self.isBuiltin = isBuiltin
        self.displayIdentity = displayIdentity
    }
}

/// One display mode the host screen a session streams can be set to,
/// exactly as macOS reports it -- never a mode this code composed. `width`
/// and `height` are the points a window is laid out in ("looks like
/// 1920x1080"); `pixelWidth` and `pixelHeight` are the real pixels behind
/// them, so a HiDPI mode and a plain one of the same point size are
/// distinguishable without reading `isHiDPI` at all.
///
/// `modeID` is opaque to the viewer and stable only for the session it was
/// offered in: it names one mode of one display on this host, and a viewer
/// that echoes it back is naming something this host already offered
/// rather than describing a configuration it wants.
public struct HostScreenModeEntry: Equatable, Sendable {
    public let modeID: String
    public let width: Int
    public let height: Int
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Double
    public let isHiDPI: Bool

    public init(
        modeID: String,
        width: Int,
        height: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        isHiDPI: Bool
    ) {
        self.modeID = modeID
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isHiDPI = isHiDPI
    }
}

/// A device's registration of its presence-bound credential, riding
/// `pairRequest` -- docs/host-screen-design.md §6.3: registered "with this host when the
/// devices pair," never as a message of its own.
///
/// `credentialID` is what a later `hostScreenRequest`'s signed proof will
/// reference; `publicKey` is what a signature over that later proof's
/// challenge is actually checked against. The two are kept separate, never
/// collapsed into one field, because docs/host-screen-design.md §6.3's portability note
/// requires it: a FIDO2 authenticator returns an opaque credential handle,
/// not a raw public key, so the identifier a later proof names and the key
/// a signature verifies against cannot always be the same bytes.
///
/// `strength` is the device's own report of which of the two acceptable
/// strengths this credential holds -- recorded by the host and shown to
/// the person arming it, never trusted as proof (CLAUDE.md's own
/// invariant paragraph). Carried as the wire's own `String`, not
/// `SensoriumHost.HostScreenCredentialStrength`: `SensoriumCore` does not
/// depend on `SensoriumHost`. `SensoriumFrameCodec.decode` still validates
/// it is one of the two spellings that type's `rawValue`s use --
/// `"hardwareBound"` or `"softwarePresence"` -- refusing anything else as
/// malformed rather than recording a value nobody actually reported.
public struct PresenceCredentialRegistration: Equatable, Sendable {
    public let credentialID: Data
    public let publicKey: Data
    /// Selects the verification routine a later proof is checked with --
    /// never a mechanism of consent (docs/host-screen-design.md §6.3).
    public let credentialFormat: String
    public let strength: String

    public init(credentialID: Data, publicKey: Data, credentialFormat: String, strength: String) {
        self.credentialID = credentialID
        self.publicKey = publicKey
        self.credentialFormat = credentialFormat
        self.strength = strength
    }
}

/// What a `hostScreenRequest` offers as proof of presence: exactly one of
/// two shapes, never a mixture and never neither. Both are references to
/// something the host already minted or already registered --
/// `credentialID` names a credential registered during pairing, and the
/// signature is over the challenge *this* offer issued; the ticket is one
/// the host minted for an earlier session of its own choosing. Neither case
/// carries a tier, a strength, or a display description: a viewer-reported
/// credential strength is unenforceable, so this type has no field for one
/// to occupy in the first place.
public enum HostScreenPresenceProof: Equatable, Sendable {
    case signed(credentialID: Data, credentialFormat: String, signature: Data)
    case resumeTicket(Data)
}

public enum CanvasPointerButton: String, Equatable, Sendable, Codable {
    case left
    case right
    case middle
}

public struct CanvasModifierFlags: OptionSet, Equatable, Sendable, Codable {
    public let rawValue: UInt8

    public init(rawValue: UInt8) {
        self.rawValue = rawValue
    }

    public static let shift = CanvasModifierFlags(rawValue: 1 << 0)
    public static let control = CanvasModifierFlags(rawValue: 1 << 1)
    public static let option = CanvasModifierFlags(rawValue: 1 << 2)
    public static let command = CanvasModifierFlags(rawValue: 1 << 3)

    public static let all: CanvasModifierFlags = [.shift, .control, .option, .command]
}

/// A trackpad's phase for one continuous scroll gesture, when the input
/// device reports one. A plain scroll-wheel mouse produces neither this nor
/// `CanvasScrollMomentumPhase`, so a `.scrolled` event carrying `nil` for both
/// is exactly what pixel scrolling has always looked like on the wire.
public enum CanvasScrollPhase: UInt8, Equatable, Sendable, Codable {
    case began, changed, ended, cancelled, mayBegin
}

/// The phase of the deceleration animation macOS runs after a trackpad flick
/// is released. Absent while a finger is still on the trackpad and for any
/// device that never reports momentum at all.
public enum CanvasScrollMomentumPhase: UInt8, Equatable, Sendable, Codable {
    case begin, `continue`, end
}

public enum SensoriumInputEvent: Equatable, Sendable {
    case pointerMoved(x: Double, y: Double)
    /// Relative motion for a captured pointer: `deltaX`/`deltaY` are raw,
    /// unaccelerated device movement rather than a canvas coordinate. Used
    /// only while the client has hidden its cursor and entered captured mode
    /// -- see `pointerCaptureChanged`.
    case pointerMovedRelative(deltaX: Double, deltaY: Double)
    case pointerButton(button: CanvasPointerButton, isDown: Bool, x: Double, y: Double)
    case scrolled(
        deltaX: Double,
        deltaY: Double,
        x: Double,
        y: Double,
        phase: CanvasScrollPhase?,
        momentumPhase: CanvasScrollMomentumPhase?
    )
    case key(keyCode: UInt16, isDown: Bool, modifiers: CanvasModifierFlags)
    /// Releases every button and modifier the host still believes is held.
    case releaseAllInput
    /// The client has entered or left captured-pointer mode for this canvas.
    /// `isCaptured == true` means the client is about to start sending
    /// `pointerMovedRelative` instead of `pointerMoved`; `false` means it has
    /// gone back to absolute motion and the host's last-known absolute
    /// position is trustworthy again.
    case pointerCaptureChanged(isCaptured: Bool)
}

public enum SensoriumFrameCodec {
    public static let maximumFrameLength = 64 * 1024

    private struct WireMessage: Codable {
        let type: String
        let protocolVersion: UInt16?
        let deviceName: String?
        let logicalWidth: Int?
        let logicalHeight: Int?
        let scale: Int?
        let surfaceID: UInt32?
        let displayID: UInt32?
        let reason: String?
        let publicKey: Data?
        let signature: Data?
        let tlsCertificateHash: Data?
        let code: String?
        let input: WireInput?
        let clientTimeNanoseconds: Int64?
        let hostTimeNanoseconds: Int64?
        let drawablePixelWidth: Double?
        let drawablePixelHeight: Double?
        let hasViewerFocus: Bool?
        let telemetry: [WireTelemetrySurface]?
        // Every optional below is omitted on encode when absent. Each
        // message's fields are its own and are never reused across message
        // types, so one message's flag cannot be read out of another's
        // field.
        var maximumScale: Double? = nil
        var hostName: String? = nil
        /// The five fields below are `hostScreenList`/`hostScreenRequest`/
        /// `hostScreenReady`'s own. `reason`, `logicalWidth`, `logicalHeight`,
        /// and `signature` above are reused as-is for `hostScreenRefused`
        /// and `hostScreenReady`/`hostScreenRequest` respectively.
        var hostScreenDisplays: [WireHostScreenDisplayEntry]? = nil
        var challenge: Data? = nil
        var hostScreenToken: Data? = nil
        var credentialID: Data? = nil
        var credentialFormat: String? = nil
        var backingScale: Double? = nil
        var resumeTicket: Data? = nil
        /// `streamScalePreference`'s own pair: which of `StreamScalePreference`'s
        /// two cases this is ("automatic" or "fixed"), and the chosen scale
        /// when it is "fixed" -- `nil` for "automatic", which has nothing to
        /// carry.
        var streamScalePreferenceKind: String? = nil
        var streamScalePreferenceValue: Double? = nil
        /// `displayCount`'s own value, 1 or 2 -- validated on decode, never
        /// merely clamped, so a value outside that range cannot reach a
        /// caller at all rather than being silently brought into range.
        var displayCount: Int? = nil
        /// `pairRequest`'s own optional presence-credential registration.
        /// `credentialID` and `credentialFormat` above are reused as-is.
        /// `presenceCredentialPublicKey` is its own field: `publicKey`
        /// above already carries the device's own pairing key on this exact
        /// message, and the two must never collide.
        var presenceCredentialPublicKey: Data? = nil
        var presenceCredentialStrength: String? = nil
        var clipboardSharingEnabled: Bool? = nil
        /// `input`'s own round-trip tag, and `inputApplied`'s echo of it.
        var inputSequence: UInt64? = nil
        /// `viewerTelemetry`'s whole payload, carried as the value type
        /// itself rather than a wire mirror: every field on it is already
        /// optional and its names are the wire's names, so there is nothing
        /// for a mirror to translate.
        var viewerTelemetry: ViewerTelemetrySample? = nil
        /// The host-screen display-mode messages' own pair: the list
        /// `hostScreenModeList` offers, and the one mode identifier every
        /// one of those messages names -- the mode requested, the mode now
        /// current, whichever message it rides on.
        var hostScreenModes: [WireHostScreenModeEntry]? = nil
        var hostScreenModeID: String? = nil
    }

    private struct WireHostScreenModeEntry: Codable {
        /// Optional on the wire, never in the value it decodes to: `value`
        /// refuses a missing or empty one as malformed rather than
        /// inventing a name a viewer could never echo back, the same
        /// discipline `WireHostScreenDisplayEntry.displayIdentity` follows.
        let modeID: String?
        let width: Int
        let height: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let refreshRate: Double
        let isHiDPI: Bool

        init(_ entry: HostScreenModeEntry) {
            modeID = entry.modeID
            width = entry.width
            height = entry.height
            pixelWidth = entry.pixelWidth
            pixelHeight = entry.pixelHeight
            refreshRate = entry.refreshRate
            isHiDPI = entry.isHiDPI
        }

        var value: HostScreenModeEntry {
            get throws {
                guard let modeID, !modeID.isEmpty else {
                    throw SensoriumProtocolError.malformedMessage
                }
                return HostScreenModeEntry(
                    modeID: modeID,
                    width: width,
                    height: height,
                    pixelWidth: pixelWidth,
                    pixelHeight: pixelHeight,
                    refreshRate: refreshRate,
                    isHiDPI: isHiDPI
                )
            }
        }
    }

    private struct WireHostScreenDisplayEntry: Codable {
        let opaqueToken: Data
        let label: String
        let logicalWidth: Int
        let logicalHeight: Int
        let backingScale: Double
        let isBuiltin: Bool
        /// Optional on the wire, never in the value it decodes to --
        /// `value` refuses a missing or empty one as malformed rather than
        /// falling back to some invented default, the same discipline
        /// every other required field on this entry already gets.
        let displayIdentity: String?

        init(_ entry: HostScreenListEntry) {
            opaqueToken = entry.opaqueToken
            label = entry.label
            logicalWidth = entry.logicalWidth
            logicalHeight = entry.logicalHeight
            backingScale = entry.backingScale
            isBuiltin = entry.isBuiltin
            displayIdentity = entry.displayIdentity
        }

        var value: HostScreenListEntry {
            get throws {
                guard let displayIdentity, !displayIdentity.isEmpty else {
                    throw SensoriumProtocolError.malformedMessage
                }
                return HostScreenListEntry(
                    opaqueToken: opaqueToken,
                    label: label,
                    logicalWidth: logicalWidth,
                    logicalHeight: logicalHeight,
                    backingScale: backingScale,
                    isBuiltin: isBuiltin,
                    displayIdentity: displayIdentity
                )
            }
        }
    }

    private struct WireStageSample: Codable {
        let p50Nanoseconds: Int64
        let p95Nanoseconds: Int64

        init(_ sample: StageLatencySample) {
            p50Nanoseconds = sample.p50Nanoseconds
            p95Nanoseconds = sample.p95Nanoseconds
        }

        var value: StageLatencySample {
            StageLatencySample(p50Nanoseconds: p50Nanoseconds, p95Nanoseconds: p95Nanoseconds)
        }
    }

    private struct WireTelemetrySurface: Codable {
        let surfaceID: UInt32
        let capture: WireStageSample?
        let encode: WireStageSample?
        let send: WireStageSample?
        let framesPerSecond: Double?
        let encoderInputDropped: Int
        let globalAdmissionDropped: Int
        let sendQueueDropped: Int
        /// `nil` when the host measured nothing, never a zero the viewer
        /// could mistake for a real resolution.
        let appliedStreamScale: Double?
        let sustainableScaleCeiling: Double?
        /// See `SurfaceTelemetrySample.clampedFromUserChoice`.
        let clampedFromUserChoice: Double?
        /// See `SurfaceTelemetrySample.hostRequestedStreamScale`.
        let hostRequestedStreamScale: Double?
        /// See `SurfaceTelemetrySample.appliedFramesPerSecond`,
        /// `qualityScale` and `fidelityLimitReason`. Omitted entirely when
        /// absent, like every optional above them, so a host that holds
        /// nothing back pays nothing for the fields that would say so.
        let appliedFramesPerSecond: Int?
        let qualityScale: Double?
        let fidelityLimitReason: String?

        init(_ sample: SurfaceTelemetrySample) {
            surfaceID = sample.surfaceID
            capture = sample.capture.map(WireStageSample.init)
            encode = sample.encode.map(WireStageSample.init)
            send = sample.send.map(WireStageSample.init)
            framesPerSecond = sample.framesPerSecond
            encoderInputDropped = sample.encoderInputDropped
            globalAdmissionDropped = sample.globalAdmissionDropped
            sendQueueDropped = sample.sendQueueDropped
            appliedStreamScale = sample.appliedStreamScale
            sustainableScaleCeiling = sample.sustainableScaleCeiling
            clampedFromUserChoice = sample.clampedFromUserChoice
            hostRequestedStreamScale = sample.hostRequestedStreamScale
            appliedFramesPerSecond = sample.appliedFramesPerSecond
            qualityScale = sample.qualityScale
            fidelityLimitReason = sample.fidelityLimitReason
        }

        var value: SurfaceTelemetrySample {
            SurfaceTelemetrySample(
                surfaceID: surfaceID,
                capture: capture?.value,
                encode: encode?.value,
                send: send?.value,
                framesPerSecond: framesPerSecond,
                encoderInputDropped: encoderInputDropped,
                globalAdmissionDropped: globalAdmissionDropped,
                sendQueueDropped: sendQueueDropped,
                appliedStreamScale: appliedStreamScale,
                sustainableScaleCeiling: sustainableScaleCeiling,
                clampedFromUserChoice: clampedFromUserChoice,
                hostRequestedStreamScale: hostRequestedStreamScale,
                appliedFramesPerSecond: appliedFramesPerSecond,
                qualityScale: qualityScale,
                fidelityLimitReason: fidelityLimitReason
            )
        }
    }

    private struct WireInput: Codable {
        let kind: String
        let x: Double?
        let y: Double?
        let deltaX: Double?
        let deltaY: Double?
        let button: CanvasPointerButton?
        let isDown: Bool?
        let keyCode: UInt16?
        let modifiers: UInt8?
        let scrollPhase: UInt8?
        let scrollMomentumPhase: UInt8?
        let isCaptured: Bool?

        init(
            kind: String,
            x: Double? = nil,
            y: Double? = nil,
            deltaX: Double? = nil,
            deltaY: Double? = nil,
            button: CanvasPointerButton? = nil,
            isDown: Bool? = nil,
            keyCode: UInt16? = nil,
            modifiers: UInt8? = nil,
            scrollPhase: UInt8? = nil,
            scrollMomentumPhase: UInt8? = nil,
            isCaptured: Bool? = nil
        ) {
            self.kind = kind
            self.x = x
            self.y = y
            self.deltaX = deltaX
            self.deltaY = deltaY
            self.button = button
            self.isDown = isDown
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.scrollPhase = scrollPhase
            self.scrollMomentumPhase = scrollMomentumPhase
            self.isCaptured = isCaptured
        }
    }

    private static func wireInput(for event: SensoriumInputEvent) -> WireInput {
        switch event {
        case let .pointerMoved(x, y):
            WireInput(kind: "pointerMoved", x: x, y: y)
        case let .pointerMovedRelative(deltaX, deltaY):
            WireInput(kind: "pointerMovedRelative", deltaX: deltaX, deltaY: deltaY)
        case let .pointerButton(button, isDown, x, y):
            WireInput(kind: "pointerButton", x: x, y: y, button: button, isDown: isDown)
        case let .scrolled(deltaX, deltaY, x, y, phase, momentumPhase):
            WireInput(
                kind: "scrolled",
                x: x,
                y: y,
                deltaX: deltaX,
                deltaY: deltaY,
                scrollPhase: phase?.rawValue,
                scrollMomentumPhase: momentumPhase?.rawValue
            )
        case let .key(keyCode, isDown, modifiers):
            WireInput(kind: "key", isDown: isDown, keyCode: keyCode, modifiers: modifiers.rawValue)
        case .releaseAllInput:
            WireInput(kind: "releaseAllInput")
        case let .pointerCaptureChanged(isCaptured):
            WireInput(kind: "pointerCaptureChanged", isCaptured: isCaptured)
        }
    }

    private static func inputEvent(from wire: WireInput) throws -> SensoriumInputEvent {
        func finiteLocation() throws -> (Double, Double) {
            guard let x = wire.x, let y = wire.y, x.isFinite, y.isFinite else {
                throw SensoriumProtocolError.malformedMessage
            }
            return (x, y)
        }

        switch wire.kind {
        case "pointerMoved":
            let (x, y) = try finiteLocation()
            return .pointerMoved(x: x, y: y)
        case "pointerMovedRelative":
            guard let deltaX = wire.deltaX, let deltaY = wire.deltaY, deltaX.isFinite, deltaY.isFinite else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .pointerMovedRelative(deltaX: deltaX, deltaY: deltaY)
        case "pointerButton":
            let (x, y) = try finiteLocation()
            guard let button = wire.button, let isDown = wire.isDown else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .pointerButton(button: button, isDown: isDown, x: x, y: y)
        case "scrolled":
            let (x, y) = try finiteLocation()
            guard let deltaX = wire.deltaX,
                  let deltaY = wire.deltaY,
                  deltaX.isFinite,
                  deltaY.isFinite else {
                throw SensoriumProtocolError.malformedMessage
            }
            // An unrecognised phase value (from a newer peer) is dropped
            // rather than rejected: the phase only refines how the host's
            // injected scroll feels, and failing the whole event over it
            // would be worse than the plain pixel scroll this falls back to.
            return .scrolled(
                deltaX: deltaX,
                deltaY: deltaY,
                x: x,
                y: y,
                phase: wire.scrollPhase.flatMap(CanvasScrollPhase.init(rawValue:)),
                momentumPhase: wire.scrollMomentumPhase.flatMap(CanvasScrollMomentumPhase.init(rawValue:))
            )
        case "pointerCaptureChanged":
            guard let isCaptured = wire.isCaptured else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .pointerCaptureChanged(isCaptured: isCaptured)
        case "key":
            guard let keyCode = wire.keyCode,
                  let isDown = wire.isDown,
                  let modifiers = wire.modifiers,
                  modifiers & ~CanvasModifierFlags.all.rawValue == 0 else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .key(keyCode: keyCode, isDown: isDown, modifiers: CanvasModifierFlags(rawValue: modifiers))
        case "releaseAllInput":
            return .releaseAllInput
        default:
            throw SensoriumProtocolError.malformedMessage
        }
    }

    public static func encode(_ message: SensoriumMessage) throws -> Data {
        let wire: WireMessage
        switch message {
        case let .hello(protocolVersion, deviceName):
            wire = WireMessage(type: "hello", protocolVersion: protocolVersion, deviceName: deviceName, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil)
        case let .authenticatedHello(protocolVersion, deviceName, publicKey, signature):
            wire = WireMessage(type: "authenticatedHello", protocolVersion: protocolVersion, deviceName: deviceName, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: publicKey, signature: signature, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil)
        case let .canvasRequest(logicalWidth, logicalHeight, scale, surfaceID):
            wire = WireMessage(type: "canvasRequest", protocolVersion: nil, deviceName: nil, logicalWidth: logicalWidth, logicalHeight: logicalHeight, scale: scale, surfaceID: surfaceID, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil)
        case let .canvasReady(displayID, logicalWidth, logicalHeight, hostSignature, surfaceID, hostName):
            wire = WireMessage(type: "canvasReady", protocolVersion: nil, deviceName: nil, logicalWidth: logicalWidth, logicalHeight: logicalHeight, scale: nil, surfaceID: surfaceID, displayID: displayID, reason: nil, publicKey: nil, signature: hostSignature, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, hostName: hostName)
        case let .canvasRefused(reason, surfaceID):
            wire = WireMessage(type: "canvasRefused", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: surfaceID, displayID: nil, reason: reason, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil)
        case let .input(event, surfaceID, sequence):
            wire = WireMessage(type: "input", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: surfaceID, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: wireInput(for: event), clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, inputSequence: sequence)
        case let .inputApplied(sequence):
            wire = WireMessage(type: "inputApplied", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, inputSequence: sequence)
        case let .goodbye(reason):
            wire = WireMessage(type: "goodbye", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: reason, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil)
        case let .pairIntent(deviceName):
            wire = WireMessage(type: "pairIntent", protocolVersion: nil, deviceName: deviceName, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil)
        case let .clipboardSharing(enabled):
            wire = WireMessage(type: "clipboardSharing", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, clipboardSharingEnabled: enabled)
        case let .pairRequest(deviceName, publicKey, code, presenceCredential, signature):
            wire = WireMessage(type: "pairRequest", protocolVersion: nil, deviceName: deviceName, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: publicKey, signature: signature, tlsCertificateHash: nil, code: code, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, credentialID: presenceCredential?.credentialID, credentialFormat: presenceCredential?.credentialFormat, presenceCredentialPublicKey: presenceCredential?.publicKey, presenceCredentialStrength: presenceCredential?.strength)
        case let .pairApproved(hostPublicKey, tlsCertificateHash, signature):
            wire = WireMessage(type: "pairApproved", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: hostPublicKey, signature: signature, tlsCertificateHash: tlsCertificateHash, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil)
        case let .pairRejected(reason):
            wire = WireMessage(type: "pairRejected", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: reason, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil)
        case let .timeSyncRequest(clientTimeNanoseconds):
            wire = WireMessage(type: "timeSyncRequest", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: clientTimeNanoseconds, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil)
        case let .timeSyncReply(clientTimeNanoseconds, hostTimeNanoseconds):
            wire = WireMessage(type: "timeSyncReply", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: clientTimeNanoseconds, hostTimeNanoseconds: hostTimeNanoseconds, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil)
        case let .viewerDrawableSize(pixelWidth, pixelHeight, surfaceID, maximumScale):
            wire = WireMessage(type: "viewerDrawableSize", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: surfaceID, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: pixelWidth, drawablePixelHeight: pixelHeight, hasViewerFocus: nil, telemetry: nil, maximumScale: maximumScale)
        case let .viewerFocus(surfaceID, hasViewerFocus):
            wire = WireMessage(type: "viewerFocus", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: surfaceID, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: hasViewerFocus, telemetry: nil)
        case let .telemetry(surfaces):
            wire = WireMessage(type: "telemetry", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: surfaces.map(WireTelemetrySurface.init))
        case let .viewerTelemetry(sample):
            wire = WireMessage(type: "viewerTelemetry", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, viewerTelemetry: sample)
        case let .hostScreenList(displays, challenge):
            wire = WireMessage(type: "hostScreenList", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, hostScreenDisplays: displays.map(WireHostScreenDisplayEntry.init), challenge: challenge)
        case let .hostScreenRequest(token, presence):
            var wireCredentialID: Data?
            var wireCredentialFormat: String?
            var wireSignature: Data?
            var wireResumeTicket: Data?
            switch presence {
            case let .signed(credentialID, credentialFormat, signature):
                wireCredentialID = credentialID
                wireCredentialFormat = credentialFormat
                wireSignature = signature
            case let .resumeTicket(ticket):
                wireResumeTicket = ticket
            }
            wire = WireMessage(type: "hostScreenRequest", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: wireSignature, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, hostScreenToken: token, credentialID: wireCredentialID, credentialFormat: wireCredentialFormat, resumeTicket: wireResumeTicket)
        case let .hostScreenReady(geometry, resumeTicket):
            wire = WireMessage(type: "hostScreenReady", protocolVersion: nil, deviceName: nil, logicalWidth: geometry.logicalWidth, logicalHeight: geometry.logicalHeight, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, backingScale: geometry.backingScale, resumeTicket: resumeTicket)
        case let .hostScreenRefused(reason):
            wire = WireMessage(type: "hostScreenRefused", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: reason, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil)
        case let .hostScreenModeList(modes, currentModeID):
            wire = WireMessage(type: "hostScreenModeList", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, hostScreenModes: modes.map(WireHostScreenModeEntry.init), hostScreenModeID: currentModeID)
        case let .hostScreenModeRequest(modeID):
            wire = WireMessage(type: "hostScreenModeRequest", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, hostScreenModeID: modeID)
        case let .hostScreenModeApplied(geometry, currentModeID):
            wire = WireMessage(type: "hostScreenModeApplied", protocolVersion: nil, deviceName: nil, logicalWidth: geometry.logicalWidth, logicalHeight: geometry.logicalHeight, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, backingScale: geometry.backingScale, hostScreenModeID: currentModeID)
        case let .hostScreenModeRefused(reason):
            wire = WireMessage(type: "hostScreenModeRefused", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: reason, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil)
        case let .streamScalePreference(preference, surfaceID):
            let kind: String
            let value: Double?
            switch preference {
            case .automatic:
                kind = "automatic"
                value = nil
            case let .fixed(scale):
                kind = "fixed"
                value = scale
            }
            wire = WireMessage(type: "streamScalePreference", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: surfaceID, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, streamScalePreferenceKind: kind, streamScalePreferenceValue: value)
        case let .displayCount(count):
            wire = WireMessage(type: "displayCount", protocolVersion: nil, deviceName: nil, logicalWidth: nil, logicalHeight: nil, scale: nil, surfaceID: nil, displayID: nil, reason: nil, publicKey: nil, signature: nil, tlsCertificateHash: nil, code: nil, input: nil, clientTimeNanoseconds: nil, hostTimeNanoseconds: nil, drawablePixelWidth: nil, drawablePixelHeight: nil, hasViewerFocus: nil, telemetry: nil, displayCount: count)
        case .unrecognized:
            // Decode-only sentinel: sending it would fabricate a wire type
            // nobody agreed on.
            throw SensoriumProtocolError.unsupportedMessage
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(wire)
        let frameLength = 4 + payload.count
        guard frameLength <= maximumFrameLength else {
            throw SensoriumProtocolError.frameTooLarge
        }

        var frame = Data()
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }

    public static func decode(_ frame: Data) throws -> SensoriumMessage {
        guard frame.count >= 4 else {
            throw SensoriumProtocolError.frameTooShort
        }
        let payloadLength = frame.prefix(4).withUnsafeBytes { bytes in
            UInt32(bigEndian: bytes.loadUnaligned(as: UInt32.self))
        }
        guard payloadLength <= maximumFrameLength - 4 else {
            throw SensoriumProtocolError.frameTooLarge
        }
        guard Int(payloadLength) == frame.count - 4 else {
            throw SensoriumProtocolError.frameLengthMismatch
        }

        let payload = frame.dropFirst(4)
        let wire = try JSONDecoder().decode(WireMessage.self, from: payload)
        switch wire.type {
        case "hello":
            guard let protocolVersion = wire.protocolVersion, let deviceName = wire.deviceName else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .hello(protocolVersion: protocolVersion, deviceName: deviceName)
        case "authenticatedHello":
            guard let protocolVersion = wire.protocolVersion,
                  let deviceName = wire.deviceName,
                  let publicKey = wire.publicKey,
                  let signature = wire.signature else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .authenticatedHello(protocolVersion: protocolVersion, deviceName: deviceName, publicKey: publicKey, signature: signature)
        case "canvasRequest":
            guard let logicalWidth = wire.logicalWidth, let logicalHeight = wire.logicalHeight, let scale = wire.scale else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .canvasRequest(logicalWidth: logicalWidth, logicalHeight: logicalHeight, scale: scale, surfaceID: wire.surfaceID)
        case "canvasReady":
            guard let displayID = wire.displayID, let logicalWidth = wire.logicalWidth, let logicalHeight = wire.logicalHeight else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .canvasReady(displayID: displayID, logicalWidth: logicalWidth, logicalHeight: logicalHeight, hostSignature: wire.signature, surfaceID: wire.surfaceID, hostName: wire.hostName)
        case "canvasRefused":
            // `surfaceID` is deliberately not required: a refusal of the
            // request that omitted it is a refusal of canvas 0, the same rule
            // every other surface-tagged message on this wire follows.
            guard let reason = wire.reason else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .canvasRefused(reason: reason, surfaceID: wire.surfaceID)
        case "input":
            guard let input = wire.input else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .input(try inputEvent(from: input), surfaceID: wire.surfaceID, sequence: wire.inputSequence)
        case "inputApplied":
            guard let sequence = wire.inputSequence else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .inputApplied(sequence: sequence)
        case "pairIntent":
            guard let deviceName = wire.deviceName, !deviceName.isEmpty else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .pairIntent(deviceName: deviceName)
        case "clipboardSharing":
            guard let enabled = wire.clipboardSharingEnabled else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .clipboardSharing(enabled: enabled)
        case "pairRequest":
            guard let deviceName = wire.deviceName, let publicKey = wire.publicKey, let code = wire.code else {
                throw SensoriumProtocolError.malformedMessage
            }
            let presenceCredential: PresenceCredentialRegistration?
            switch (wire.credentialID, wire.presenceCredentialPublicKey, wire.credentialFormat, wire.presenceCredentialStrength) {
            case (nil, nil, nil, nil):
                presenceCredential = nil
            case let (.some(credentialID), .some(credentialPublicKey), .some(credentialFormat), .some(strength)):
                // Validated against the two spellings
                // `HostScreenCredentialStrength`'s own `rawValue`s use --
                // this codec cannot import that type (`SensoriumCore` does
                // not depend on `SensoriumHost`), so the check is spelled
                // out here instead of shared. A device that reported
                // neither acceptable strength never sends this field pair
                // at all (CLAUDE.md's own invariant); an unrecognised
                // string here is a malformed message, not a third,
                // silently-accepted strength.
                guard strength == "hardwareBound" || strength == "softwarePresence" else {
                    throw SensoriumProtocolError.malformedMessage
                }
                presenceCredential = PresenceCredentialRegistration(
                    credentialID: credentialID,
                    publicKey: credentialPublicKey,
                    credentialFormat: credentialFormat,
                    strength: strength
                )
            default:
                // A partial registration -- some of the four fields present,
                // not all -- is exactly as unrepresentable as a
                // hostScreenRequest naming neither or both proof shapes:
                // never partially trusted.
                throw SensoriumProtocolError.malformedMessage
            }
            return .pairRequest(
                deviceName: deviceName,
                publicKey: publicKey,
                code: code,
                presenceCredential: presenceCredential,
                signature: wire.signature
            )
        case "pairApproved":
            guard let hostPublicKey = wire.publicKey else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .pairApproved(
                hostPublicKey: hostPublicKey,
                tlsCertificateHash: wire.tlsCertificateHash,
                signature: wire.signature
            )
        case "pairRejected":
            guard let reason = wire.reason else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .pairRejected(reason: reason)
        case "timeSyncRequest":
            guard let clientTimeNanoseconds = wire.clientTimeNanoseconds else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .timeSyncRequest(clientTimeNanoseconds: clientTimeNanoseconds)
        case "timeSyncReply":
            guard let clientTimeNanoseconds = wire.clientTimeNanoseconds,
                  let hostTimeNanoseconds = wire.hostTimeNanoseconds else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .timeSyncReply(
                clientTimeNanoseconds: clientTimeNanoseconds,
                hostTimeNanoseconds: hostTimeNanoseconds
            )
        case "viewerDrawableSize":
            // Arrives over the network from an authenticated client and is
            // still not trusted: it feeds the encoder's dimensions.
            guard let pixelWidth = wire.drawablePixelWidth,
                  let pixelHeight = wire.drawablePixelHeight,
                  StreamScalePolicy.isPlausibleDrawableDimension(pixelWidth),
                  StreamScalePolicy.isPlausibleDrawableDimension(pixelHeight),
                  // Absent is a valid answer -- no cap -- but a present one is
                  // held to the same standard as the dimensions above.
                  wire.maximumScale.map(StreamScalePolicy.isPlausibleMaximumScale) ?? true else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .viewerDrawableSize(
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                surfaceID: wire.surfaceID,
                maximumScale: wire.maximumScale
            )
        case "viewerFocus":
            // `surfaceID` is validated where every other routing key is, in
            // `HostSessionController`, against the same {nil, 0, 1} rule.
            guard let hasViewerFocus = wire.hasViewerFocus else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .viewerFocus(surfaceID: wire.surfaceID, hasViewerFocus: hasViewerFocus)
        case "telemetry":
            guard let telemetry = wire.telemetry else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .telemetry(surfaces: telemetry.map { $0.value })
        case "viewerTelemetry":
            // The surface a reading belongs to lives inside the reading, not
            // beside it: a stage timing separated from the surface it was
            // measured on is not a reading at all.
            guard let viewerTelemetry = wire.viewerTelemetry else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .viewerTelemetry(viewerTelemetry)
        case "goodbye":
            guard let reason = wire.reason else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .goodbye(reason: reason)
        case "hostScreenList":
            guard let displays = wire.hostScreenDisplays, let challenge = wire.challenge else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .hostScreenList(displays: try displays.map { try $0.value }, challenge: challenge)
        case "hostScreenRequest":
            guard let token = wire.hostScreenToken else {
                throw SensoriumProtocolError.malformedMessage
            }
            let presence: HostScreenPresenceProof
            switch (wire.resumeTicket, wire.credentialID, wire.credentialFormat, wire.signature) {
            case let (.some(ticket), nil, nil, nil):
                presence = .resumeTicket(ticket)
            case let (nil, .some(credentialID), .some(credentialFormat), .some(signature)):
                presence = .signed(credentialID: credentialID, credentialFormat: credentialFormat, signature: signature)
            default:
                // Neither a complete signed proof nor a complete ticket --
                // including a mixture of both, or a partial one -- is
                // admitted as "whichever half looks valid". A request that
                // cannot be read as exactly one of its two allowed shapes
                // is malformed, never partially trusted.
                throw SensoriumProtocolError.malformedMessage
            }
            return .hostScreenRequest(token: token, presence: presence)
        case "hostScreenReady":
            guard let logicalWidth = wire.logicalWidth,
                  let logicalHeight = wire.logicalHeight,
                  let backingScale = wire.backingScale,
                  let resumeTicket = wire.resumeTicket else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .hostScreenReady(
                geometry: SessionSurfaceGeometry(
                    logicalWidth: logicalWidth, logicalHeight: logicalHeight, backingScale: backingScale
                ),
                resumeTicket: resumeTicket
            )
        case "hostScreenRefused":
            guard let reason = wire.reason else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .hostScreenRefused(reason: reason)
        case "hostScreenModeList":
            guard let modes = wire.hostScreenModes, let currentModeID = wire.hostScreenModeID else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .hostScreenModeList(modes: try modes.map { try $0.value }, currentModeID: currentModeID)
        case "hostScreenModeRequest":
            guard let modeID = wire.hostScreenModeID else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .hostScreenModeRequest(modeID: modeID)
        case "hostScreenModeApplied":
            guard let logicalWidth = wire.logicalWidth,
                  let logicalHeight = wire.logicalHeight,
                  let backingScale = wire.backingScale,
                  let currentModeID = wire.hostScreenModeID else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .hostScreenModeApplied(
                geometry: SessionSurfaceGeometry(
                    logicalWidth: logicalWidth, logicalHeight: logicalHeight, backingScale: backingScale
                ),
                currentModeID: currentModeID
            )
        case "hostScreenModeRefused":
            guard let reason = wire.reason else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .hostScreenModeRefused(reason: reason)
        case "streamScalePreference":
            guard let kind = wire.streamScalePreferenceKind else {
                throw SensoriumProtocolError.malformedMessage
            }
            let preference: StreamScalePreference
            switch kind {
            case "automatic":
                preference = .automatic
            case "fixed":
                guard let value = wire.streamScalePreferenceValue, value.isFinite else {
                    throw SensoriumProtocolError.malformedMessage
                }
                preference = .fixed(value)
            default:
                // A kind this build does not recognise on a message type it
                // does recognise: read as malformed, never as `.unrecognized`
                // -- the same rule `hostScreenRequest`'s presence-proof shape
                // already follows.
                throw SensoriumProtocolError.malformedMessage
            }
            return .streamScalePreference(preference, surfaceID: wire.surfaceID)
        case "displayCount":
            // Validated here, not merely clamped: a value outside 1...2
            // (the `CanvasSurfaceID` slot count -- `SensoriumCore` does not
            // depend on `SensoriumHost` and cannot name that type directly)
            // is refused outright, so nothing on the wire can ever exceed
            // the two-slot maximum by the time a caller sees it.
            guard let count = wire.displayCount, (1...2).contains(count) else {
                throw SensoriumProtocolError.malformedMessage
            }
            return .displayCount(count)
        default:
            // A message kind this build doesn't know, from a peer running a
            // different protocol revision. The length prefix already let the
            // framing above skip its bytes cleanly; returning it lets the
            // session loop keep going instead of dying on a message it just
            // hasn't learned about yet.
            return .unrecognized(type: wire.type)
        }
    }

    /// Binds the host's identity to the exact canvas it created for this client,
    /// including which surface it is: `surfaceID` decides where a window routes
    /// its input, so it must be inside the signature like every other field a
    /// tampering peer must not move. `nil` encodes as the literal `"none"`,
    /// which a real `UInt32` can never stringify to, so an absent surfaceID and
    /// a present one can never collide on the same transcript bytes.
    public static func canvasReadyTranscript(
        displayID: UInt32,
        logicalWidth: Int,
        logicalHeight: Int,
        clientPublicKey: Data,
        surfaceID: UInt32?
    ) -> Data {
        var transcript = Data("sensorium-canvas-ready-v1|".utf8)
        transcript.append(Data(String(displayID).utf8))
        transcript.append(0)
        transcript.append(Data(String(logicalWidth).utf8))
        transcript.append(0)
        transcript.append(Data(String(logicalHeight).utf8))
        transcript.append(0)
        transcript.append(clientPublicKey.base64EncodedData())
        transcript.append(0)
        transcript.append(Data((surfaceID.map(String.init) ?? "none").utf8))
        return transcript
    }

    public static func authenticatedHelloTranscript(
        protocolVersion: UInt16,
        deviceName: String,
        publicKey: Data
    ) -> Data {
        var transcript = Data("sensorium-authenticated-hello-v1|".utf8)
        transcript.append(Data(String(protocolVersion).utf8))
        transcript.append(0)
        transcript.append(Data(deviceName.utf8))
        transcript.append(0)
        transcript.append(publicKey.base64EncodedData())
        return transcript
    }

    /// What a `pairRequest`'s `signature` covers: everything the host would
    /// write from that request, so a proof made for one request cannot be
    /// lifted onto another asking for something else. Built the same way
    /// `pairApprovalTranscript` is -- a versioned prefix and NUL-separated
    /// fields -- and a credential that is absent is spelled out as a fixed
    /// marker rather than simply omitted, so "no credential" and a
    /// credential whose fields happen to be empty are different transcripts.
    public static func pairRequestTranscript(
        deviceName: String,
        clientPublicKey: Data,
        code: String,
        presenceCredential: PresenceCredentialRegistration?
    ) -> Data {
        var transcript = Data("sensorium-pair-request-v1|".utf8)
        transcript.append(Data(deviceName.utf8))
        transcript.append(0)
        transcript.append(clientPublicKey.base64EncodedData())
        transcript.append(0)
        transcript.append(Data(code.utf8))
        transcript.append(0)
        guard let presenceCredential else {
            transcript.append(Data("none".utf8))
            return transcript
        }
        transcript.append(presenceCredential.credentialID.base64EncodedData())
        transcript.append(0)
        transcript.append(presenceCredential.publicKey.base64EncodedData())
        transcript.append(0)
        transcript.append(Data(presenceCredential.credentialFormat.utf8))
        transcript.append(0)
        transcript.append(Data(presenceCredential.strength.utf8))
        return transcript
    }

    public static func pairApprovalTranscript(
        deviceName: String,
        clientPublicKey: Data,
        tlsCertificateHash: Data?
    ) -> Data {
        var transcript = Data("sensorium-pair-approved-v1|".utf8)
        transcript.append(Data(deviceName.utf8))
        transcript.append(0)
        transcript.append(clientPublicKey.base64EncodedData())
        transcript.append(0)
        transcript.append(tlsCertificateHash?.base64EncodedData() ?? Data("none".utf8))
        return transcript
    }
}

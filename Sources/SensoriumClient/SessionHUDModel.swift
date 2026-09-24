import Foundation
import SensoriumCore

/// Everything one surface's HUD is allowed to say, gathered from the places
/// that actually know it. There is no field here the viewer does not hold: a
/// number the host never sent arrives as `nil` and is rendered as unavailable,
/// never as a default that reads like a measurement.
public struct SessionHUDSnapshot: Equatable, Sendable {
    public let surfaceID: UInt32
    /// The host's own reading and whether it is still current
    /// (`SessionTelemetryTracker`).
    public let availability: SurfaceTelemetryAvailability
    /// This machine's own receive/decode/present/end-to-end percentiles.
    public let clientMetrics: SessionMetrics
    public let stream: ClientStreamReading
    /// The scale this viewer's geometry last asked the host for. Compared
    /// against the host's applied scale, this is the difference the whole
    /// panel exists to show.
    public let requestedStreamScale: Double?
    /// The pixel width/height this viewer's own geometry derived
    /// `requestedStreamScale` from, read from
    /// `ClientViewportController.requestedDrawablePixelWidth`/`Height`. `nil`
    /// before any drawable size has been sent. Kept only for the sub-line
    /// that names both machines' numbers when the host's own echoed request
    /// disagrees with this one -- nothing else on the panel reads it.
    public let requestedDrawablePixelWidth: Double?
    public let requestedDrawablePixelHeight: Double?
    /// This canvas's own choice -- `.automatic` or a `.fixed` scale -- read
    /// from `ClientViewportController.currentStreamScalePreference`.
    public let streamScalePreference: StreamScalePreference
    /// Which decoder VideoToolbox selected, `nil` before a decode session
    /// exists.
    public let decoder: DecoderHardwareAccelerationStatus?
    /// Whether this canvas has hidden the local cursor and switched to
    /// captured relative motion -- the mode that is otherwise invisible from
    /// the window. See `CanvasSurfaceView.togglePointerCapture()`.
    public let isPointerCaptured: Bool
    /// The real gap between a frame falling due on screen and the GPU actually
    /// signalling it there -- `MetalFramePresenter.completionLatency`, p50.
    /// Measured from the due time, so the hold below is not counted twice.
    /// `nil` before the first frame has completed a real draw.
    /// "PRESENT" is this figure; the decode-to-schedule gap is shown
    /// separately, as "SCHEDULE," because it answers a different question.
    public let presentCompletionP50Nanoseconds: Int64?
    /// How far past its capture time this viewer is holding each frame so that
    /// frames arriving in groups still reach the screen evenly spaced --
    /// `PresentationPacer.holdNanoseconds`. Zero before the first frame has
    /// been held at all, which the panel shows as not yet measured.
    public let presentationHoldNanoseconds: Int64?
    /// `TelemetryAttentionThreshold`'s verdict on the whole reading: drops,
    /// staleness, or an end-to-end p50 past its threshold. Not a row of its
    /// own -- the panel marks itself, so a user who has it open sees the
    /// session turn bad without reading every number.
    public let isAttentionWorthy: Bool
    /// The machine this surface is streaming from, as every other viewer surface
    /// names it -- `nil` only for the moment before anything has said who it
    /// is, when the panel falls back to "the host".
    public let hostName: String?
    /// This host's address and port exactly as dialled, e.g.
    /// `mini.tail1234.ts.net:7777` -- `SavedHost.host`/`.port`, threaded
    /// through unchanged. `nil` only for the moment before a session has one.
    public let hostAddress: String?
    /// The last several ticks of this surface's end-to-end p50, in
    /// milliseconds, oldest first -- the panel's own "END-TO-END" figure over
    /// time.
    public let endToEndLatencyTrend: SessionHUDTrend
    /// The last several ticks of `stream.bitsPerSecond`, oldest first -- the
    /// panel's own "VIDEO IN" figure over time.
    public let videoInBitrateTrend: SessionHUDTrend
    /// The last several ticks of the host's own encoded frame rate, oldest
    /// first -- the panel's own "FPS" figure over time.
    public let fpsTrend: SessionHUDTrend
    /// Packets this viewer gave up before the decoder saw them, for the life
    /// of this window. The host's own dropped count says nothing about these:
    /// they are frames the host sent and this machine never showed.
    public let viewerDroppedBeforeDecode: Int
    /// Decoded frames this viewer gave up before the screen was drawn.
    public let viewerDroppedBeforePresent: Int
    /// Whether either figure above grew since the previous tick. A total that
    /// stopped growing is history; one still growing is the session skipping
    /// frames right now, which is the only version worth marking.
    public let viewerDropsGrew: Bool

    public init(
        surfaceID: UInt32,
        availability: SurfaceTelemetryAvailability,
        clientMetrics: SessionMetrics,
        stream: ClientStreamReading,
        requestedStreamScale: Double?,
        requestedDrawablePixelWidth: Double? = nil,
        requestedDrawablePixelHeight: Double? = nil,
        streamScalePreference: StreamScalePreference,
        decoder: DecoderHardwareAccelerationStatus?,
        isAttentionWorthy: Bool = false,
        isPointerCaptured: Bool = false,
        presentCompletionP50Nanoseconds: Int64? = nil,
        presentationHoldNanoseconds: Int64? = nil,
        hostName: String? = nil,
        hostAddress: String? = nil,
        endToEndLatencyTrend: SessionHUDTrend = SessionHUDTrend(),
        videoInBitrateTrend: SessionHUDTrend = SessionHUDTrend(),
        fpsTrend: SessionHUDTrend = SessionHUDTrend(),
        viewerDroppedBeforeDecode: Int = 0,
        viewerDroppedBeforePresent: Int = 0,
        viewerDropsGrew: Bool = false
    ) {
        self.surfaceID = surfaceID
        self.availability = availability
        self.clientMetrics = clientMetrics
        self.stream = stream
        self.requestedStreamScale = requestedStreamScale
        self.requestedDrawablePixelWidth = requestedDrawablePixelWidth
        self.requestedDrawablePixelHeight = requestedDrawablePixelHeight
        self.streamScalePreference = streamScalePreference
        self.decoder = decoder
        self.isAttentionWorthy = isAttentionWorthy
        self.isPointerCaptured = isPointerCaptured
        self.presentCompletionP50Nanoseconds = presentCompletionP50Nanoseconds
        self.presentationHoldNanoseconds = presentationHoldNanoseconds
        self.hostName = hostName
        self.hostAddress = hostAddress
        self.endToEndLatencyTrend = endToEndLatencyTrend
        self.videoInBitrateTrend = videoInBitrateTrend
        self.fpsTrend = fpsTrend
        self.viewerDroppedBeforeDecode = viewerDroppedBeforeDecode
        self.viewerDroppedBeforePresent = viewerDroppedBeforePresent
        self.viewerDropsGrew = viewerDropsGrew
    }
}

/// The last several ticks of one series, oldest first, for a sparkline beside
/// its live value. Bounded so a session running for hours never grows this
/// past what one sparkline can draw.
public struct SessionHUDTrend: Equatable, Sendable {
    public static let capacity = 60

    public private(set) var samples: [Double]

    public init(samples: [Double] = []) {
        self.samples = Array(samples.suffix(Self.capacity))
    }

    /// Drops the oldest sample once `capacity` is exceeded.
    public mutating func append(_ value: Double) {
        samples.append(value)
        if samples.count > Self.capacity {
            samples.removeFirst(samples.count - Self.capacity)
        }
    }
}

/// Maps one trend's samples onto a sparkline's own rect, oldest sample at
/// the left, min-max scaled so a series fills the height it is given
/// regardless of its own units. Pure, so the mapping is verifiable without a
/// window.
public enum SessionHUDSparklineLayout {
    /// Fewer than two samples has no line to draw -- a single point is not a
    /// trend, and this returns no points rather than one.
    public static func points(for samples: [Double], in rect: CGRect) -> [CGPoint] {
        guard samples.count >= 2 else { return [] }
        let minValue = samples.min() ?? 0
        let maxValue = samples.max() ?? 0
        let range = maxValue - minValue
        let stepX = rect.width / CGFloat(samples.count - 1)
        return samples.enumerated().map { index, sample in
            // A flat series (`range == 0`) has nothing to scale against; it
            // draws as a flat line at mid-height rather than dividing by zero.
            let fraction: CGFloat = range == 0 ? 0.5 : CGFloat((sample - minValue) / range)
            return CGPoint(
                x: rect.minX + CGFloat(index) * stepX,
                y: rect.minY + fraction * rect.height
            )
        }
    }
}

/// One line of the panel: a mono label, its value, and optionally the one
/// sentence that explains a value the user would otherwise misread.
public struct SessionHUDRow: Equatable, Sendable {
    public let label: String
    public let value: String
    /// `nil` for an ordinary reading. A tone is spent only where it changes
    /// what the user should do.
    public let tone: ViewerStatusTone?
    /// Whether this value is a last-known reading rather than a current one.
    /// Deliberately not a `tone`: a HUD is scanned for numbers, and a dead
    /// one drawn like a live one misleads its reader, but a dead one should
    /// recede rather than compete with the colour that means "look at this".
    public let isStale: Bool
    public let note: String?
    /// This row's own trend, oldest sample first, for the sparkline beside
    /// its value. `nil` for a row with no history to show, and distinct from
    /// an empty array: the view treats fewer than two samples the same way
    /// either way, but `nil` is what an ordinary row without a trend at all
    /// carries.
    public let trend: [Double]?

    public init(
        label: String,
        value: String,
        tone: ViewerStatusTone? = nil,
        isStale: Bool = false,
        note: String? = nil,
        trend: [Double]? = nil
    ) {
        self.label = label
        self.value = value
        self.tone = tone
        self.isStale = isStale
        self.note = note
        self.trend = trend
    }
}

/// A titled group of rows. `note` is the group-wide caveat -- staleness, so
/// far -- kept at the group rather than repeated on every row it applies to.
public struct SessionHUDSection: Equatable, Sendable {
    public let title: String
    public let note: String?
    public let rows: [SessionHUDRow]

    public init(title: String, note: String? = nil, rows: [SessionHUDRow]) {
        self.title = title
        self.note = note
        self.rows = rows
    }
}

/// How the sections sit on the panel. Two sections of parallel data with
/// short values -- the two latency blocks -- are half the height and easier to
/// compare side by side, and which of the two machines is slow is the question
/// a person opens this panel to answer. The pairing is decided here rather
/// than by the view so it is verifiable without a window.
public enum SessionHUDBlock: Equatable, Sendable {
    case section(SessionHUDSection)
    /// The shared eyebrow, then the two columns under it. A column is under
    /// half the panel wide, which is not enough for an eyebrow at this
    /// system's `widest` tracking to say both what the numbers are and which
    /// machine they came from -- so the block says the first once and each
    /// column says the second.
    case columns(title: String, SessionHUDSection, SessionHUDSection)

    public var sections: [SessionHUDSection] {
        switch self {
        case let .section(section): return [section]
        case let .columns(_, left, right): return [left, right]
        }
    }

    public var title: String? {
        switch self {
        case .section: return nil
        case let .columns(title, _, _): return title
        }
    }
}

/// Turns what the viewer holds into the panel's rows. Pure: no window, no
/// clock, no AppKit -- so every word the HUD shows, and every case where it
/// admits it does not know, is verifiable without a window server.
public enum SessionHUDPanel {
    public static let unavailable = "unavailable"
    /// An old host that never sends an applied scale at all -- distinct from
    /// the resolution itself being unavailable, which is what the shared
    /// `unavailable` word would otherwise read as here.
    private static let notReported = "not reported"
    private static let notYetMeasured = "not yet"
    /// A reading a host never sent, on a row whose own word for absence would
    /// otherwise be a claim: "not reported" reads as a fact about the host,
    /// and there is nothing here to say about a host that has never heard of
    /// the field at all.
    private static let nothingToReport = "\u{2014}"

    /// The sections in reading order, without the layout. Used by anything
    /// that can only show a list.
    public static func sections(
        telemetry: SessionHUDSnapshot,
        session: ViewerSessionStatus?
    ) -> [SessionHUDSection] {
        blocks(telemetry: telemetry, session: session).flatMap(\.sections)
    }

    public static func blocks(
        telemetry: SessionHUDSnapshot,
        session: ViewerSessionStatus?
    ) -> [SessionHUDBlock] {
        let sample = hostSample(telemetry.availability)
        var isStale: Bool
        if case .stale = telemetry.availability { isStale = true } else { isStale = false }
        // A session that is down is the second reason the host's numbers are
        // not current, and it is known a full staleness window before
        // telemetry expires. Without it the panel reads `READINGS live` in
        // green beside a window saying the connection is lost -- the panel
        // contradicting the app around it.
        let isSessionDown = session.map { $0.phase == .reconnecting || $0.phase == .lost } ?? false
        isStale = isStale || isSessionDown
        // Stated once, in the section that states the session, and carried
        // onto the numbers it applies to: three copies wrap to nothing
        // legible in a half-width column.
        return [
            .section(sessionSection(
                telemetry.availability,
                session: session,
                isSessionDown: isSessionDown,
                isPointerCaptured: telemetry.isPointerCaptured,
                hostName: telemetry.hostName,
                hostAddress: telemetry.hostAddress
            )),
            .section(resolutionSection(telemetry, sample: sample, isStale: isStale, isSessionDown: isSessionDown)),
            .columns(
                title: "LATENCY",
                SessionHUDSection(title: "THIS MACHINE", rows: [
                    stageRow("RECEIVE", telemetry.clientMetrics.samples(for: .receive).p50, isStale: isSessionDown),
                    stageRow("DECODE", telemetry.clientMetrics.samples(for: .decode).p50, isStale: isSessionDown),
                    // Decode finishing to the frame reaching the screen,
                    // the hold included -- never screen latency itself.
                    stageRow("UPDATES", telemetry.clientMetrics.samples(for: .present).p50, isStale: isSessionDown),
                    // What "PRESENT" means: the GPU's own completion signal,
                    // not the instant `present(_:)` returned -- see
                    // `MetalFramePresenter.completionLatency`.
                    stageRow("PRESENT", telemetry.presentCompletionP50Nanoseconds, isStale: isSessionDown),
                    // Latency this machine added on purpose, named as such and
                    // placed before the figure it is part of. A hold of zero
                    // is a session that has held nothing yet, not a session
                    // that measured no hold.
                    stageRow(
                        "HOLD",
                        telemetry.presentationHoldNanoseconds.flatMap { $0 > 0 ? $0 : nil },
                        isStale: isSessionDown,
                        note: "Added on this machine to steady the motion."
                    ),
                    stageRow(
                        "END-TO-END",
                        telemetry.clientMetrics.samples(for: .endToEnd).p50,
                        isStale: isSessionDown,
                        trend: telemetry.endToEndLatencyTrend.samples
                    ),
                    // Send to `inputApplied` reply, entirely local to the viewer --
                    // see `SessionMetricStage.inputRoundTrip`.
                    stageRow("INPUT RTT", telemetry.clientMetrics.samples(for: .inputRoundTrip).p50, isStale: isSessionDown)
                ]),
                SessionHUDSection(title: telemetry.hostName?.uppercased() ?? "HOST", rows: [
                    stageRow("CAPTURE", sample?.capture?.p50Nanoseconds, isStale: isStale),
                    stageRow("ENCODE", sample?.encode?.p50Nanoseconds, isStale: isStale),
                    stageRow("SEND", sample?.send?.p50Nanoseconds, isStale: isStale)
                ])
            ),
            .section(throughputSection(telemetry, sample: sample, isStale: isStale, isSessionDown: isSessionDown))
        ]
    }

    /// The machine to name in a sentence, falling back to the generic word only
    /// for the moment before anything has said who it is.
    private static func hostReference(_ hostName: String?) -> String {
        hostName ?? "the host"
    }

    /// Every sub-line sentence on the panel ends with a period; the session
    /// headline this row's note carries is authored elsewhere, so this adds
    /// the period.
    private static func withTerminalPeriod(_ text: String) -> String {
        let terminators: Set<Character> = [".", "!", "?", "\u{2026}"]
        guard let last = text.last, !terminators.contains(last) else { return text }
        return text + "."
    }

    /// One shape for both reasons a picture can be softer than what was
    /// asked for -- the host's own report of a clamped fixed choice, and the
    /// plain geometry comparison under `.automatic` -- so a reader never has
    /// to learn two sentences for the same fact.
    ///
    /// A stage is only named when there is evidence it is the reason: a
    /// learned `sustainableScaleCeiling` or the host's own report of a
    /// clamped fixed choice (`hasClampedUserChoice`). A `fidelityLimitReason`
    /// can arrive without either -- naming the stage anyway would blame it
    /// for a gap the host never measured, which is what left a viewer told
    /// its host's encoder could not keep up with a request the host had
    /// never been asked to try.
    ///
    /// With neither a ceiling nor a clamped choice, and a host that echoes
    /// what it derived, the actual gap is between two numbers rather than a
    /// stage: this machine's own drawable size derived one scale, and the
    /// host derived another from the same message. That is said in those
    /// words -- naming no stage -- whenever the echo disagrees with this
    /// machine's own ask and the drawable size it came from is known. A host
    /// that predates the echo, or one whose derivation agrees with this
    /// machine's own, still gets the older, vaguer sentence: there is
    /// nothing more specific to say.
    private static func heldBackSentence(
        applied: Double,
        appliedFramesPerSecond: Int?,
        requested: Double,
        askedBy: String,
        limitReason: String?,
        hasScaleCeiling: Bool,
        hasClampedUserChoice: Bool,
        hostName: String?,
        hostRequestedStreamScale: Double? = nil,
        requestedDrawablePixelWidth: Double? = nil,
        requestedDrawablePixelHeight: Double? = nil
    ) -> String {
        let rate = appliedFramesPerSecond.map { " at \($0) fps" } ?? ""
        let opening = "Held to \(scaleText(applied))\(rate). "
        guard hasScaleCeiling || hasClampedUserChoice else {
            if let hostRequestedStreamScale, hostRequestedStreamScale != requested,
               let width = requestedDrawablePixelWidth, let height = requestedDrawablePixelHeight {
                return opening + "This machine asked for \(scaleText(requested)) from "
                    + "\(Int(width))x\(Int(height)) px. \(hostReference(hostName)) derived "
                    + "\(scaleText(hostRequestedStreamScale))."
            }
            return opening + "\(askedBy) asked for \(scaleText(requested)), but "
                + "\(hostReference(hostName)) is streaming a different scale."
        }
        let clampedOpening = opening + "\(askedBy) asked for \(scaleText(requested)), "
        guard let clause = limitClause(limitReason, hostName: hostName) else {
            return clampedOpening + "which \(hostReference(hostName)) measured as unsustainable."
        }
        return clampedOpening + "\(clause)."
    }

    /// The end of the sentence: what could not keep up, and whose measurement
    /// says so. Each machine is named the way the rest of the panel names it:
    /// "this machine" for the one the panel is drawn on, the other by its own
    /// name. Neither machine can see the link on its own, which is why that
    /// reason names both. `nil` for a host that reports no reason, which
    /// leaves the sentence saying only that the host measured the request as
    /// unsustainable.
    private static func limitClause(_ reason: String?, hostName: String?) -> String? {
        switch reason {
        case FidelityLimitReason.encoder:
            return "which \(hostReference(hostName))'s encoder cannot keep up with"
        case FidelityLimitReason.link:
            return "which the link cannot carry, by what this machine and \(hostReference(hostName)) measured"
        case FidelityLimitReason.viewer:
            return "which this machine cannot keep up with"
        default:
            return nil
        }
    }

    /// The same reason as a row value. A token this build has never heard of
    /// is repeated as it arrived: the host plainly did report one, and
    /// showing nothing would be the viewer covering up that it is the older
    /// of the two.
    private static func limitText(_ reason: String?, hostName: String?) -> String {
        switch reason {
        case FidelityLimitReason.encoder: return "\(hostReference(hostName))'s encoder"
        case FidelityLimitReason.link: return "the link"
        case FidelityLimitReason.viewer: return "this machine"
        case let .some(other) where !other.isEmpty: return other
        default: return nothingToReport
        }
    }

    private static func sessionSection(
        _ availability: SurfaceTelemetryAvailability,
        session: ViewerSessionStatus?,
        isSessionDown: Bool,
        isPointerCaptured: Bool,
        hostName: String?,
        hostAddress: String?
    ) -> SessionHUDSection {
        let state: SessionHUDRow
        if let session {
            state = SessionHUDRow(
                label: "STATE",
                value: stateWord(session.phase),
                tone: session.tone,
                // The headline names the host, which is the other half of
                // "which machine am I looking at".
                note: withTerminalPeriod(session.headline)
            )
        } else {
            state = SessionHUDRow(label: "STATE", value: "unknown", tone: nil, note: nil)
        }

        let telemetryRow: SessionHUDRow
        switch availability {
        // Checked ahead of freshness: a reading that arrived a moment ago is
        // still the last one there will be, and "live" would be true only of
        // the reading, never of the session it describes.
        case _ where isSessionDown && !isUnavailable(availability):
            telemetryRow = SessionHUDRow(
                label: "READINGS",
                value: "stopped",
                tone: .warn,
                note: "The session is down, so nothing more is arriving. Every reading below is "
                    + "the last one measured."
            )
        case .fresh:
            telemetryRow = SessionHUDRow(label: "READINGS", value: "live", tone: .ok)
        case .stale:
            telemetryRow = SessionHUDRow(
                label: "READINGS",
                value: "stale",
                tone: .warn,
                note: "Nothing from \(hostReference(hostName)) for a few seconds. Every dimmed reading below is "
                    + "the last \(hostReference(hostName)) sent, not a current one."
            )
        case .unavailable:
            telemetryRow = SessionHUDRow(
                label: "READINGS",
                value: "none yet",
                tone: nil,
                note: "This host has sent no measurements. It may predate them."
            )
        }
        let addressRow = SessionHUDRow(label: "ADDRESS", value: hostAddress ?? unavailable)
        let pointerRow = SessionHUDRow(
            label: "POINTER",
            value: isPointerCaptured ? "captured" : "free",
            tone: isPointerCaptured ? .warn : nil,
            note: isPointerCaptured
                ? "\(ViewerKeyNames.escapeGesture) releases it back to this machine."
                : nil
        )
        return SessionHUDSection(title: "SESSION", rows: [state, addressRow, telemetryRow, pointerRow])
    }

    private static func resolutionSection(
        _ telemetry: SessionHUDSnapshot,
        sample: SurfaceTelemetrySample?,
        isStale: Bool,
        isSessionDown: Bool
    ) -> SessionHUDSection {
        let pixels: String
        if let width = telemetry.stream.pixelWidth, let height = telemetry.stream.pixelHeight {
            pixels = "\(width) \u{00D7} \(height)"
        } else {
            pixels = unavailable
        }

        let applied = sample?.appliedStreamScale
        let requested = telemetry.requestedStreamScale
        // The line the whole feature exists for. Only claimed when the
        // numbers involved are real: a missing applied scale is an old host,
        // not a host holding anything back.
        var heldBackNote: String?
        var appliedTone: ViewerStatusTone?
        // Not claimed from evidence the viewer no longer has: "the host is
        // holding you below what you asked for" is a statement about now, and
        // once telemetry has gone stale the last-known scale is all there is.
        // The dimmed value still shows what it was.
        if !isStale, let applied {
            // `clampedFromUserChoice` is authoritative -- the host itself
            // says a fixed choice was held back, with no guessing needed --
            // and is checked first because a fixed choice standing above
            // whatever the window's own geometry happens to derive is
            // otherwise indistinguishable from nothing having been clamped
            // at all.
            if let clampedFromUserChoice = sample?.clampedFromUserChoice, applied < clampedFromUserChoice {
                appliedTone = .warn
                heldBackNote = heldBackSentence(
                    applied: applied,
                    appliedFramesPerSecond: sample?.appliedFramesPerSecond,
                    requested: clampedFromUserChoice,
                    askedBy: "You",
                    limitReason: sample?.fidelityLimitReason,
                    hasScaleCeiling: sample?.sustainableScaleCeiling != nil,
                    hasClampedUserChoice: true,
                    hostName: telemetry.hostName
                )
            } else if let requested, applied < requested {
                appliedTone = .warn
                heldBackNote = heldBackSentence(
                    applied: applied,
                    appliedFramesPerSecond: sample?.appliedFramesPerSecond,
                    requested: requested,
                    askedBy: "Automatic",
                    limitReason: sample?.fidelityLimitReason,
                    hasScaleCeiling: sample?.sustainableScaleCeiling != nil,
                    hasClampedUserChoice: false,
                    hostName: telemetry.hostName,
                    hostRequestedStreamScale: sample?.hostRequestedStreamScale,
                    requestedDrawablePixelWidth: telemetry.requestedDrawablePixelWidth,
                    requestedDrawablePixelHeight: telemetry.requestedDrawablePixelHeight
                )
            }
        }

        // The explanation goes after both numbers, never between them: these
        // two rows exist to be read against each other, and a sentence in the
        // gap breaks the rhythm exactly where the eye is comparing.
        // Neither the frame rate nor the quality is a setting a person chose:
        // both are limits the host measured, and the row says so in words so
        // the number is never read as somebody's preference. The frame rate
        // has no "full" value the viewer knows -- the rungs are the host's --
        // so a reported reason is what marks it limited; the quality's own
        // full value is 1.0, so it marks itself.
        let isLimited = sample?.fidelityLimitReason != nil
        return SessionHUDSection(title: "FIDELITY", rows: [
            SessionHUDRow(label: "SIZE", value: pixels, isStale: isSessionDown),
            SessionHUDRow(
                label: "APPLIED",
                value: applied.map(scaleText) ?? notReported,
                tone: appliedTone,
                isStale: isStale
            ),
            SessionHUDRow(
                label: "REQUESTED",
                value: (sample?.hostRequestedStreamScale ?? requested).map(scaleText) ?? unavailable,
                note: heldBackNote
            ),
            SessionHUDRow(
                label: "CEILING",
                value: sample?.sustainableScaleCeiling.map(scaleText) ?? "not measured",
                isStale: isStale
            ),
            SessionHUDRow(
                label: "CHOICE",
                value: choiceText(telemetry.streamScalePreference)
            ),
            SessionHUDRow(
                label: "FRAME RATE",
                value: sample?.appliedFramesPerSecond
                    .map { isLimited ? "limited to \($0) fps" : "\($0) fps" } ?? nothingToReport,
                isStale: isStale
            ),
            SessionHUDRow(
                label: "QUALITY",
                value: sample?.qualityScale.map(qualityText) ?? nothingToReport,
                isStale: isStale
            ),
            SessionHUDRow(
                label: "LIMITED BY",
                value: limitText(sample?.fidelityLimitReason, hostName: telemetry.hostName),
                tone: !isStale && sample?.fidelityLimitReason != nil ? .warn : nil,
                isStale: isStale
            )
        ])
    }

    private static func choiceText(_ preference: StreamScalePreference) -> String {
        switch preference {
        case .automatic: return "Automatic"
        case let .fixed(scale): return scaleText(scale)
        }
    }

    private static func throughputSection(
        _ telemetry: SessionHUDSnapshot,
        sample: SurfaceTelemetrySample?,
        isStale: Bool,
        isSessionDown: Bool
    ) -> SessionHUDSection {
        let dropped = (sample?.encoderInputDropped ?? 0)
            + (sample?.globalAdmissionDropped ?? 0)
            + (sample?.sendQueueDropped ?? 0)
        return SessionHUDSection(title: "STREAM", rows: [
            SessionHUDRow(
                label: "VIDEO IN",
                value: telemetry.stream.bitsPerSecond.map(megabitsText) ?? unavailable,
                isStale: isSessionDown,
                note: "Measured on this machine.",
                trend: telemetry.videoInBitrateTrend.samples
            ),
            SessionHUDRow(
                label: "FPS",
                value: sample?.framesPerSecond.map { String(format: "%.0f", $0) } ?? unavailable,
                isStale: isStale,
                note: "Encoded on \(hostReference(telemetry.hostName)).",
                trend: telemetry.fpsTrend.samples
            ),
            SessionHUDRow(
                label: "DROPPED",
                value: sample == nil ? unavailable : "\(dropped)",
                // A drop count nobody is updating any more is not worth an
                // alarm colour; being visibly dead says more.
                tone: dropped > 0 && !isStale ? .warn : nil,
                isStale: isStale
            ),
            SessionHUDRow(
                label: "DROPPED HERE",
                value: "\(telemetry.viewerDroppedBeforeDecode) before decode, "
                    + "\(telemetry.viewerDroppedBeforePresent) before present",
                // Marked only while it is still growing. A total that stopped
                // growing describes a moment that has passed, and colouring it
                // would leave the panel amber for the rest of the session.
                tone: telemetry.viewerDropsGrew && !isSessionDown ? .warn : nil,
                isStale: isSessionDown,
                note: "Given up on this machine, not sent by \(hostReference(telemetry.hostName))."
            ),
            SessionHUDRow(
                label: "DECODER",
                value: decoderText(telemetry.decoder),
                tone: telemetry.decoder == .softwareFallback ? .warn : nil,
                note: telemetry.decoder == .softwareFallback
                    ? "No hardware decoder was available; this machine is decoding in software."
                    : nil
            )
        ])
    }

    private static func isUnavailable(_ availability: SurfaceTelemetryAvailability) -> Bool {
        if case .unavailable = availability { return true }
        return false
    }

    private static func hostSample(_ availability: SurfaceTelemetryAvailability) -> SurfaceTelemetrySample? {
        switch availability {
        case .unavailable: return nil
        case let .fresh(sample), let .stale(sample): return sample
        }
    }

    private static func stageRow(
        _ label: String,
        _ p50Nanoseconds: Int64?,
        isStale: Bool = false,
        note: String? = nil,
        trend: [Double]? = nil
    ) -> SessionHUDRow {
        SessionHUDRow(
            label: label,
            value: p50Nanoseconds.map { String(format: "%.1f ms", Double($0) / 1_000_000) } ?? notYetMeasured,
            isStale: isStale,
            note: note,
            trend: trend
        )
    }

    private static func stateWord(_ phase: ViewerSessionPhase) -> String {
        switch phase {
        case .connecting: return "connecting"
        case .live: return "live"
        case .reconnecting: return "reconnecting"
        case .lost: return "lost"
        case .ended: return "ended"
        }
    }

    private static func decoderText(_ status: DecoderHardwareAccelerationStatus?) -> String {
        switch status {
        case .hardwareAccelerated: return "hardware"
        case .softwareFallback: return "software"
        // VideoToolbox declined to say which decoder it picked. Distinct from
        // having no session at all, and neither is "software".
        case .unknown: return "not reported"
        case nil: return unavailable
        }
    }

    private static func qualityText(_ qualityScale: Double) -> String {
        let percentage = String(format: "%.0f%%", qualityScale * 100)
        return qualityScale < 1 ? "limited to \(percentage)" : percentage
    }

    private static func scaleText(_ scale: Double) -> String {
        String(format: "%.2fx", scale)
    }

    private static func megabitsText(_ bitsPerSecond: Double) -> String {
        String(format: "%.1f Mbit/s", bitsPerSecond / 1_000_000)
    }
}

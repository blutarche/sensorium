import Foundation

/// Timing for the host→viewer telemetry channel, shared by both ends so
/// there is one place that decides the cost/frequency trade-off.
public enum TelemetryPolicy {
    /// How often the host sends one `telemetry` control message. This rides
    /// the same wire as 60 fps video and shares the encoder's CPU, so it is
    /// deliberately far below either: one small JSON frame a second, not one
    /// per frame.
    public static let sendIntervalSeconds: Double = 1.0

    /// A surface is shown as stale once this long has passed since its last
    /// reading arrived. Three missed sends, not one, so an isolated slow
    /// control-stream write does not flash "stale" during a healthy session.
    public static let staleAfterSeconds: Double = sendIntervalSeconds * 3
}

/// One stage's p50/p95, already computed. `nil` at the call site (never a
/// zero) is how "no samples yet" is represented one layer up.
public struct StageLatencySample: Codable, Equatable, Sendable {
    public let p50Nanoseconds: Int64
    public let p95Nanoseconds: Int64

    public init(p50Nanoseconds: Int64, p95Nanoseconds: Int64) {
        self.p50Nanoseconds = p50Nanoseconds
        self.p95Nanoseconds = p95Nanoseconds
    }
}

/// The reasons `SurfaceTelemetrySample.fidelityLimitReason` can name. Stable
/// tokens rather than prose, like `CanvasRefusalReason`'s, so the viewer can
/// branch on one and say it in its own words instead of showing whatever
/// sentence the host happened to write. A token this list does not contain is
/// not an error: a viewer that meets one shows it as it arrived rather than
/// pretending the host reported nothing.
public enum FidelityLimitReason {
    /// The host's own encoder cannot produce what was asked for in time.
    public static let encoder = "encoder"
    /// The wire between the two machines cannot carry what the host is producing.
    public static let link = "link"
    /// The viewer cannot decode or present what is arriving.
    public static let viewer = "viewer"
}

/// One host-measured snapshot for one canvas: where the frame's time went
/// before it ever reached the wire, and what got dropped along the way.
/// Absence of a stage means no samples yet, never a fabricated zero.
public struct SurfaceTelemetrySample: Equatable, Sendable {
    public let surfaceID: UInt32
    public let capture: StageLatencySample?
    public let encode: StageLatencySample?
    public let send: StageLatencySample?
    /// Encoded frames per second since the previous snapshot. `nil` on the
    /// first snapshot a session ever sends, since there is no prior tick to
    /// measure a rate against.
    public let framesPerSecond: Double?
    /// Captured frames the encoder never saw because capture outran it.
    public let encoderInputDropped: Int
    /// Frames refused by the bound shared across every pipeline.
    public let globalAdmissionDropped: Int
    /// Encoded frames the transport hand-off dropped because the link could
    /// not keep up.
    public let sendQueueDropped: Int
    /// The stream scale this surface is actually being encoded at, which is
    /// not necessarily the one the viewer's geometry asked for: the host
    /// steps down from a scale it measures unsustainable, and
    /// `viewerDrawableSize` travels one way only. Without this the viewer can
    /// only infer its own resolution from decoded frame dimensions -- more
    /// than a second late, and indistinguishable from the user resizing the
    /// window. `nil` when the host reports no applied stream scale.
    public let appliedStreamScale: Double?
    /// The highest scale this surface has been measured to sustain, once
    /// anything has been measured unsustainable. `nil` means either an older
    /// host or a session that has learned no ceiling yet -- never a
    /// fabricated limit.
    public let sustainableScaleCeiling: Double?
    /// The scale a person explicitly chose (`StreamScalePreference.fixed`),
    /// when the fidelity controller's measured ceiling held `appliedStreamScale` below
    /// it -- see `StreamScaleResolution.clampedFromUserChoice`, which this
    /// carries onto the wire. `nil` whenever there is nothing to report: no
    /// fixed choice is in force, or the ceiling did not touch it.
    public let clampedFromUserChoice: Double?
    /// The scale the host itself derived from the viewer's last reported
    /// drawable size, before any measured ceiling narrowed it -- what the
    /// host holds as the request, so a viewer whose own derivation disagrees
    /// can say where the two numbers diverge instead of naming a stage that
    /// did nothing. `nil` for an older host or before any drawable size has
    /// arrived.
    public let hostRequestedStreamScale: Double?
    /// The frame rate this surface is actually being encoded at, as opposed
    /// to `framesPerSecond`, which is what it managed to produce. The two
    /// differ whenever the host has stepped the rate down: a surface holding
    /// 30 fps by choice and a surface missing 60 fps by half look identical
    /// without this. `nil` when the host reports no applied rate.
    public let appliedFramesPerSecond: Int?
    /// The multiplier this surface's encoder bitrate is currently running at,
    /// `1.0` when nothing has been given up. `nil` when the host reports
    /// nothing -- never a `1.0` standing in for "unknown", which would read
    /// as a host that had given nothing up.
    public let qualityScale: Double?
    /// Which part of the pipeline is holding this surface below what the
    /// viewer asked for, as a stable token rather than prose the viewer would
    /// have to parse. `nil` means nothing is being held back, which is why
    /// the viewer renders it as "no reason to show".
    public let fidelityLimitReason: String?

    public init(
        surfaceID: UInt32,
        capture: StageLatencySample?,
        encode: StageLatencySample?,
        send: StageLatencySample?,
        framesPerSecond: Double?,
        encoderInputDropped: Int,
        globalAdmissionDropped: Int,
        sendQueueDropped: Int,
        appliedStreamScale: Double? = nil,
        sustainableScaleCeiling: Double? = nil,
        clampedFromUserChoice: Double? = nil,
        hostRequestedStreamScale: Double? = nil,
        appliedFramesPerSecond: Int? = nil,
        qualityScale: Double? = nil,
        fidelityLimitReason: String? = nil
    ) {
        self.surfaceID = surfaceID
        self.capture = capture
        self.encode = encode
        self.send = send
        self.framesPerSecond = framesPerSecond
        self.encoderInputDropped = encoderInputDropped
        self.globalAdmissionDropped = globalAdmissionDropped
        self.sendQueueDropped = sendQueueDropped
        self.appliedStreamScale = appliedStreamScale
        self.sustainableScaleCeiling = sustainableScaleCeiling
        self.clampedFromUserChoice = clampedFromUserChoice
        self.hostRequestedStreamScale = hostRequestedStreamScale
        self.appliedFramesPerSecond = appliedFramesPerSecond
        self.qualityScale = qualityScale
        self.fidelityLimitReason = fidelityLimitReason
    }
}

/// What a viewer's draw callbacks did over the last interval, per second.
///
/// A viewer can decode frames and still show none of them, and from outside a
/// display that was never asked to draw looks the same as one that was asked
/// and could not. `drawsPerSecond` counts the callbacks; the rest count the
/// callbacks that had a decoded frame waiting and ended without showing it,
/// by what stopped them. Counts only: nothing here names a window, a screen
/// or a device.
public struct ViewerDrawReport: Codable, Equatable, Sendable {
    /// Draw callbacks, whether or not a frame was waiting.
    public let drawsPerSecond: Double
    /// The view had no drawable to put the frame on.
    public let noDrawablePerSecond: Double
    /// The GPU had no command buffer to give.
    public let noCommandBufferPerSecond: Double
    /// The drawable left no room to draw the frame into.
    public let emptyDestinationPerSecond: Double
    /// The frame could not be drawn at all, and was given up.
    public let renderFailurePerSecond: Double
    /// The longest interval between two consecutive draw callbacks in the
    /// report's window, counting the one from the last draw before it. Tells
    /// a display link that stopped firing from one that fired and was refused.
    public let longestDrawGapMilliseconds: Double?
    /// The longest time the viewer's main thread ran late for a heartbeat that
    /// should come every 50 ms, in the report's window. A large value with a
    /// large draw gap points at the main thread rather than at the display.
    public let longestMainThreadStallMilliseconds: Double?
    /// The share, 0 to 1, of the window's heartbeats at which the viewer's
    /// window was not visible, which is when the system pauses its drawing.
    public let hiddenFraction: Double?
    /// The refresh rate the viewer's view asked its display link for when the
    /// report was built.
    public let preferredFramesPerSecond: Int?

    public init(
        drawsPerSecond: Double,
        noDrawablePerSecond: Double,
        noCommandBufferPerSecond: Double,
        emptyDestinationPerSecond: Double,
        renderFailurePerSecond: Double,
        longestDrawGapMilliseconds: Double? = nil,
        longestMainThreadStallMilliseconds: Double? = nil,
        hiddenFraction: Double? = nil,
        preferredFramesPerSecond: Int? = nil
    ) {
        self.drawsPerSecond = drawsPerSecond
        self.noDrawablePerSecond = noDrawablePerSecond
        self.noCommandBufferPerSecond = noCommandBufferPerSecond
        self.emptyDestinationPerSecond = emptyDestinationPerSecond
        self.renderFailurePerSecond = renderFailurePerSecond
        self.longestDrawGapMilliseconds = longestDrawGapMilliseconds
        self.longestMainThreadStallMilliseconds = longestMainThreadStallMilliseconds
        self.hiddenFraction = hiddenFraction
        self.preferredFramesPerSecond = preferredFramesPerSecond
    }

    /// Draws that had a frame waiting and showed none, for any reason.
    public var notShownPerSecond: Double {
        noDrawablePerSecond + noCommandBufferPerSecond + emptyDestinationPerSecond + renderFailurePerSecond
    }
}

/// One viewer-measured snapshot for one surface: where the frame's time went
/// after it left the wire, and how much of it arrived. The mirror image of
/// `SurfaceTelemetrySample`, and the same discipline throughout -- a stage
/// with no samples yet is absent, never a fabricated zero, because a zero
/// here would read as a link with no latency at all.
///
/// Everything on it is a timing, a rate, or whether the decoder behind them
/// runs in hardware. Nothing names an address, a window, a file, or anything
/// the person at the viewer did.
public struct ViewerTelemetrySample: Codable, Equatable, Sendable {
    public let surfaceID: UInt32
    /// Host capture to this machine putting the frame on screen, which is
    /// the only number that describes the whole path. Measurable only once
    /// the two clocks have been synchronised.
    public let endToEnd: StageLatencySample?
    /// Host capture to this machine holding the encoded frame: the wire's
    /// own share of `endToEnd`.
    public let receive: StageLatencySample?
    /// Receipt to decoded frame, entirely this machine's own work -- including
    /// whatever time the packet spent waiting for a decoder already busy with
    /// an earlier one, which is most of what a viewer falling behind spends
    /// here.
    public let decode: StageLatencySample?
    /// Frames this machine actually put on screen per second, which is not
    /// what the host encoded: a viewer that cannot keep up presents fewer.
    public let presentedFramesPerSecond: Double?
    /// Frames this machine finished decoding per second. Read against
    /// `presentedFramesPerSecond` rather than against the host's own encoded
    /// rate: the gap between decoding a frame and putting it on screen is the
    /// viewer's own, and comparing what was presented here against what was
    /// encoded on the host confuses that with everything the wire did on the
    /// way.
    public let decodedFramesPerSecond: Double?
    /// Encoded video this machine received per second, counted here rather
    /// than taken from the host's send-side figure -- what left the host is
    /// not what arrived.
    public let receivedBitsPerSecond: Double?
    /// This viewer's own clock-sync round trip, for the host's menu-bar ping
    /// display only -- see `HostPingDisplay`. Session-wide, not per surface,
    /// so it repeats unchanged across whichever surfaces this tick reports;
    /// `nil` from a viewer that predates this field, or one that has not yet
    /// completed a clock sync. Never read by anything that steers the
    /// stream: unlike every other field above, an untrusted or wrong value
    /// here can only mislabel a number on the host's own screen.
    public let roundTripNanoseconds: Int64?
    /// Whether this surface's decoder runs in hardware, as the decoder itself
    /// reported once it was created. `nil` from a viewer that predates this
    /// field, before a decoder exists, or when the decoder did not say.
    ///
    /// This and the two stages below are a diagnosis for the host's log and
    /// nothing else: no fidelity decision reads them, so a wrong value can
    /// only mislabel a log line.
    public let decodesInHardware: Bool?
    /// The decoder's own share of `decode`: from the moment a packet is
    /// handed to the decoder to the moment the decoder hands the picture
    /// back. Over the frames decoded in the last completed measuring window
    /// (`TelemetryPolicy.sendIntervalSeconds`), not the session, so it
    /// describes the stream as it is now. `nil` from a viewer that predates
    /// this field or one that decoded nothing timed in that window.
    public let decoderOnly: StageLatencySample?
    /// The rest of `decode`: from receipt to the moment the packet is handed
    /// to the decoder, which is time spent waiting behind earlier packets.
    /// Same window and the same `nil` rule as `decoderOnly`.
    public let decodeQueueWait: StageLatencySample?
    /// Frames per second that were decoded and then replaced by a newer one
    /// within a display refresh and a quarter of becoming due. Two frames
    /// landing inside one refresh leave only the newer to show, so these are
    /// frames the viewer kept up with, not frames it fell behind on: added to
    /// `presentedFramesPerSecond` they say how much of what was decoded this
    /// machine handled in time. `nil` from a viewer that predates this field
    /// or has no earlier tick to measure a rate against; the host reads that
    /// as none.
    public let supersededOnTimeFramesPerSecond: Double?
    /// What this viewer's draw callbacks did, for the host's log alone: no
    /// fidelity decision reads it. `nil` from a viewer that predates it, on a
    /// surface's first tick, or from a window that counts no draws.
    public let drawReport: ViewerDrawReport?

    public init(
        surfaceID: UInt32,
        endToEnd: StageLatencySample?,
        receive: StageLatencySample?,
        decode: StageLatencySample?,
        presentedFramesPerSecond: Double?,
        decodedFramesPerSecond: Double?,
        receivedBitsPerSecond: Double?,
        roundTripNanoseconds: Int64? = nil,
        decodesInHardware: Bool? = nil,
        decoderOnly: StageLatencySample? = nil,
        decodeQueueWait: StageLatencySample? = nil,
        supersededOnTimeFramesPerSecond: Double? = nil,
        drawReport: ViewerDrawReport? = nil
    ) {
        self.surfaceID = surfaceID
        self.endToEnd = endToEnd
        self.receive = receive
        self.decode = decode
        self.presentedFramesPerSecond = presentedFramesPerSecond
        self.decodedFramesPerSecond = decodedFramesPerSecond
        self.receivedBitsPerSecond = receivedBitsPerSecond
        self.roundTripNanoseconds = roundTripNanoseconds
        self.decodesInHardware = decodesInHardware
        self.decoderOnly = decoderOnly
        self.decodeQueueWait = decodeQueueWait
        self.supersededOnTimeFramesPerSecond = supersededOnTimeFramesPerSecond
        self.drawReport = drawReport
    }
}

/// The latest `ViewerTelemetrySample` per surface, with the receipt time that
/// decides whether it is still worth reading.
///
/// A reading that stopped arriving must stop being an answer: a viewer whose
/// link has failed sends nothing at all, and the last good numbers it sent are
/// exactly the flattering ones. `latest(surfaceID:atSeconds:)` therefore
/// returns nothing past the staleness window rather than a last-known reading,
/// which is the opposite of what the viewer's own display does with the host's
/// numbers -- a person can see a reading is dimmed, and a caller deciding what
/// to encode cannot.
public struct ViewerTelemetryStore: Equatable, Sendable {
    private struct Slot: Equatable {
        var sample: ViewerTelemetrySample
        var receivedAtSeconds: Double
    }

    /// Fixed two slots, matching the `{0, 1}` surfaceID cap everywhere else.
    private var slots: [Slot?] = [nil, nil]
    private let staleAfterSeconds: Double

    public init(staleAfterSeconds: Double = TelemetryPolicy.staleAfterSeconds) {
        self.staleAfterSeconds = staleAfterSeconds
    }

    /// A sample naming a surface this session cannot have is dropped. Unlike a
    /// routing key, telemetry grants nothing and steers nothing on its own, so
    /// an out-of-range one is a measurement with nowhere to go rather than a
    /// message worth ending a session over.
    ///
    /// A sample carrying a number that cannot be one -- a rate that is not
    /// finite, or a rate or duration below zero -- is dropped whole rather
    /// than repaired. This is data from the far end of a wire, and every
    /// decision it will eventually steer is one an impossible number can
    /// steer wrongly; clamping a negative latency to zero would fabricate the
    /// most flattering reading there is, which is the one answer a caller must
    /// never be handed. Dropping it leaves the store in the state it already
    /// handles safely -- no reading, so nothing inferred. Zero itself is
    /// allowed: a viewer reporting that no frames arrived is reporting
    /// something true.
    ///
    /// Returns whether the sample was kept.
    @discardableResult
    public mutating func record(_ sample: ViewerTelemetrySample, atSeconds now: Double) -> Bool {
        guard let index = Self.index(for: sample.surfaceID), Self.isPlausible(sample) else {
            return false
        }
        slots[index] = Slot(sample: sample, receivedAtSeconds: now)
        return true
    }

    private static func isPlausible(_ sample: ViewerTelemetrySample) -> Bool {
        for rate in [
            sample.presentedFramesPerSecond,
            sample.decodedFramesPerSecond,
            sample.receivedBitsPerSecond,
            sample.supersededOnTimeFramesPerSecond
        ] {
            guard let rate else { continue }
            guard rate.isFinite, rate >= 0 else { return false }
        }
        if let report = sample.drawReport {
            for rate in [
                report.drawsPerSecond,
                report.noDrawablePerSecond,
                report.noCommandBufferPerSecond,
                report.emptyDestinationPerSecond,
                report.renderFailurePerSecond
            ] {
                guard rate.isFinite, rate >= 0 else { return false }
            }
            for measure in [
                report.longestDrawGapMilliseconds,
                report.longestMainThreadStallMilliseconds,
                report.hiddenFraction
            ] {
                guard let measure else { continue }
                guard measure.isFinite, measure >= 0 else { return false }
            }
        }
        for stage in [sample.endToEnd, sample.receive, sample.decode, sample.decoderOnly, sample.decodeQueueWait] {
            guard let stage else { continue }
            guard stage.p50Nanoseconds >= 0, stage.p95Nanoseconds >= 0 else { return false }
        }
        if let roundTripNanoseconds = sample.roundTripNanoseconds, roundTripNanoseconds < 0 {
            return false
        }
        return true
    }

    public func latest(surfaceID: UInt32, atSeconds now: Double) -> ViewerTelemetrySample? {
        guard let index = Self.index(for: surfaceID), let slot = slots[index] else {
            return nil
        }
        guard now - slot.receivedAtSeconds <= staleAfterSeconds else {
            return nil
        }
        return slot.sample
    }

    private static func index(for surfaceID: UInt32) -> Int? {
        surfaceID < 2 ? Int(surfaceID) : nil
    }
}

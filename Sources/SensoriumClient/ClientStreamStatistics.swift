import Foundation
import SensoriumCore

/// What one surface's stream looks like from this end of the wire.
/// Every field is optional because every field is a measurement: nothing
/// here is ever filled in with a plausible default.
public struct ClientStreamReading: Equatable, Sendable {
    /// The decoded frame's own dimensions, which is the resolution actually
    /// being presented -- not a size derived from a scale the host reported.
    public let pixelWidth: Int?
    public let pixelHeight: Int?
    /// `nil` until a full measuring window has elapsed. A rate computed over
    /// a fraction of a second would swing with one frame's arrival.
    public let bitsPerSecond: Double?
    /// How many frames this surface has decoded for the whole session. A
    /// running total rather than a rate: two of them and the gap between
    /// them are what a rate needs, and a total is also the only form that
    /// survives a caller reading it at an interval of its own choosing.
    public let decodedFrameCount: Int
    /// Packet handed to the decoder to picture handed back, over the frames
    /// decoded in the last completed measuring window. `nil` until a window
    /// has completed, or when that window decoded nothing it could time.
    public let decoderOnly: StageLatencySample?
    /// Receipt to the packet being handed to the decoder, over the same
    /// window and with the same `nil` rule as `decoderOnly`.
    public let decodeQueueWait: StageLatencySample?

    public init(
        pixelWidth: Int?,
        pixelHeight: Int?,
        bitsPerSecond: Double?,
        decodedFrameCount: Int = 0,
        decoderOnly: StageLatencySample? = nil,
        decodeQueueWait: StageLatencySample? = nil
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.bitsPerSecond = bitsPerSecond
        self.decodedFrameCount = decodedFrameCount
        self.decoderOnly = decoderOnly
        self.decodeQueueWait = decodeQueueWait
    }
}

/// Counts what this viewer actually received, per surface.
///
/// The host reports its own send-side throughput; nothing on the viewer
/// counted a byte. For a viewer the two are not the same number -- what left
/// the host is not what arrived here -- and the arriving one is the one a
/// person looking at this window wants.
///
/// `byteCount` is the encoded video the decoder was handed: payload plus any
/// codec configuration riding with a keyframe. Transport framing (a few dozen
/// bytes per frame) is excluded, because reproducing the framing arithmetic
/// here would duplicate constants the codec owns for a difference three
/// orders of magnitude below the number shown.
///
/// Not an actor: the decode callback and the receive loop both write to it
/// from off the main actor, and neither can afford to suspend.
public final class ClientStreamStatistics: @unchecked Sendable {
    private struct Slot {
        var pixelWidth: Int?
        var pixelHeight: Int?
        var bytesInWindow: Int = 0
        var decodedFrameCount: Int = 0
        var windowStartNanoseconds: Int64?
        var lastBitsPerSecond: Double?
        var decoderOnlyInWindow = LatencySamples()
        var decodeQueueWaitInWindow = LatencySamples()
        var lastDecoderOnly: StageLatencySample?
        var lastDecodeQueueWait: StageLatencySample?
    }

    private let lock = NSLock()
    /// Fixed two slots, matching the `{0, 1}` surfaceID cap.
    private var slots = [Slot(), Slot()]
    private let windowSeconds: Double

    /// Defaults to the telemetry cadence so the viewer's own rate and the
    /// host's reported numbers refresh together rather than at two tempos.
    public init(windowSeconds: Double = TelemetryPolicy.sendIntervalSeconds) {
        self.windowSeconds = windowSeconds
    }

    public func recordReceivedVideo(surfaceID: UInt32, byteCount: Int, atNanoseconds now: Int64) {
        guard let index = Self.index(for: surfaceID) else { return }
        lock.lock()
        defer { lock.unlock() }
        if slots[index].windowStartNanoseconds == nil {
            slots[index].windowStartNanoseconds = now
        }
        slots[index].bytesInWindow += byteCount
    }

    /// `timing` splits the frame's decode into the wait ahead of the decoder
    /// and the decoder itself, when it carries the moment between the two.
    public func recordDecodedFrame(
        surfaceID: UInt32,
        pixelWidth: Int,
        pixelHeight: Int,
        timing: FrameTiming? = nil
    ) {
        guard let index = Self.index(for: surfaceID), pixelWidth > 0, pixelHeight > 0 else { return }
        lock.lock()
        defer { lock.unlock() }
        slots[index].pixelWidth = pixelWidth
        slots[index].pixelHeight = pixelHeight
        slots[index].decodedFrameCount += 1
        if let timing, let submittedAt = timing.submittedAtNanoseconds {
            slots[index].decodeQueueWaitInWindow.record(nanoseconds: submittedAt - timing.receivedAtNanoseconds)
            slots[index].decoderOnlyInWindow.record(nanoseconds: timing.decodedAtNanoseconds - submittedAt)
        }
    }

    /// Rolls the measuring window when a full one has elapsed, and otherwise
    /// reports the last completed window's rate and decode split. Reading is
    /// what advances the window, so a caller that reads on the telemetry tick
    /// gets one rate per tick without a timer of its own.
    public func reading(surfaceID: UInt32, atNanoseconds now: Int64) -> ClientStreamReading {
        guard let index = Self.index(for: surfaceID) else {
            return ClientStreamReading(pixelWidth: nil, pixelHeight: nil, bitsPerSecond: nil)
        }
        lock.lock()
        defer { lock.unlock() }
        if let start = slots[index].windowStartNanoseconds {
            let elapsedSeconds = Double(now - start) / 1_000_000_000
            if elapsedSeconds >= windowSeconds {
                slots[index].lastBitsPerSecond = Double(slots[index].bytesInWindow) * 8 / elapsedSeconds
                slots[index].bytesInWindow = 0
                slots[index].lastDecoderOnly = Self.stage(slots[index].decoderOnlyInWindow)
                slots[index].lastDecodeQueueWait = Self.stage(slots[index].decodeQueueWaitInWindow)
                slots[index].decoderOnlyInWindow = LatencySamples()
                slots[index].decodeQueueWaitInWindow = LatencySamples()
                slots[index].windowStartNanoseconds = now
            }
        }
        return ClientStreamReading(
            pixelWidth: slots[index].pixelWidth,
            pixelHeight: slots[index].pixelHeight,
            bitsPerSecond: slots[index].lastBitsPerSecond,
            decodedFrameCount: slots[index].decodedFrameCount,
            decoderOnly: slots[index].lastDecoderOnly,
            decodeQueueWait: slots[index].lastDecodeQueueWait
        )
    }

    private static func stage(_ samples: LatencySamples) -> StageLatencySample? {
        guard let p50 = samples.p50, let p95 = samples.p95 else {
            return nil
        }
        return StageLatencySample(p50Nanoseconds: p50, p95Nanoseconds: p95)
    }

    private static func index(for surfaceID: UInt32) -> Int? {
        surfaceID < 2 ? Int(surfaceID) : nil
    }
}

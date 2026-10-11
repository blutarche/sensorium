import Foundation
import SensoriumCore

/// Whether a created decompression session ended up using a hardware
/// accelerated decoder. The platform picks the decoder silently, so this is
/// what makes the choice observable instead of assumed.
///
/// The viewer only ever *enables* hardware decode, never *requires* it: the
/// viewer may be the weaker of the two machines and can least afford to
/// refuse a connection it could otherwise show: slower software decode
/// beats no picture.
public enum DecoderHardwareAccelerationStatus: Equatable, Sendable {
    case hardwareAccelerated
    case softwareFallback
    /// The property could not be read back at all -- the decoder did not say
    /// which implementation it selected. This is distinct from
    /// `softwareFallback` on purpose: collapsing an unreadable result into
    /// "software" would assert something the code never established.
    case unknown

    /// `reportedHardwareAccelerated` is the read-back result: `true`/`false`
    /// if the property was read successfully, `nil` if it could not be read.
    public init(reportedHardwareAccelerated: Bool?) {
        switch reportedHardwareAccelerated {
        case true: self = .hardwareAccelerated
        case false: self = .softwareFallback
        case nil: self = .unknown
        }
    }

    /// The same answer as `ViewerTelemetrySample.decodesInHardware` carries
    /// it: `unknown` is unreported, never software.
    public var decodesInHardware: Bool? {
        switch self {
        case .hardwareAccelerated: return true
        case .softwareFallback: return false
        case .unknown: return nil
        }
    }

    /// Logged once per session creation, using the module's existing
    /// "Sensorium: ..." idiom (see `ViewerApplication`).
    var logLine: String {
        switch self {
        case .hardwareAccelerated:
            return "Sensorium: video decoder using hardware acceleration"
        case .softwareFallback:
            return "Sensorium: video decoder falling back to software decode -- no hardware decoder available"
        case .unknown:
            #if canImport(VideoToolbox)
            return "Sensorium: video decoder hardware acceleration status unknown -- VideoToolbox did not report which decoder it selected"
            #else
            return "Sensorium: video decoder hardware acceleration status unknown -- the decoder did not report which implementation it selected"
            #endif
        }
    }
}

/// What the viewer's decode path needs of a decoder, and nothing platform
/// specific beyond it. `VideoToolboxDecoder` is the macOS conformer; a
/// platform with another video decoder supplies its own without anything
/// above this protocol changing.
public protocol VideoDecoding: AnyObject, Sendable {
    /// Takes one encoded packet. Called only from `VideoDecodeQueue`'s serial
    /// queue, and throws the decode failure the session ends on.
    func decode(_ packet: EncodedVideoFramePacket) throws

    /// Gives up the decoder's state, so the next session starts from its own
    /// key frame rather than the previous one's parameter sets.
    func reset()

    /// Which decoder implementation is running, or `nil` before there is one.
    /// Shown on the session HUD.
    var hardwareAcceleration: DecoderHardwareAccelerationStatus? { get }
}

/// Builds a decoder for one window: the receipt ledger it reads arrival times
/// from, and the handler each decoded frame is delivered to.
public typealias VideoDecoderFactory = @Sendable (
    FrameReceiptLedger?,
    @escaping @Sendable (DecodedFrame) -> Void
) -> any VideoDecoding

/// The three pieces one window's video travels through, wired together:
/// packets are taken off the read path by `decodeQueue`, decoded by whichever
/// decoder the factory built, and handed to `coalescer` on their way to the
/// screen.
///
/// A type of its own so the wiring can be verified with a decoder a test
/// supplies: the only production owner is `ClientCanvasWindowController`,
/// which cannot be built in a verification runner.
public struct VideoDecodePipeline: Sendable {
    public let decoder: any VideoDecoding
    public let decodeQueue: VideoDecodeQueue
    public let coalescer: DecodedFrameCoalescer

    /// `now` stamps the moment each packet is handed to the decoder into
    /// `receipts`, so the decoder's output can tell its own time apart from
    /// the wait ahead of it. Injectable so a test can name that moment.
    public init(
        receipts: FrameReceiptLedger?,
        drops: ViewerFrameDropCounter?,
        makeDecoder: VideoDecoderFactory,
        onDecodedFrame: (@Sendable (DecodedFrame) -> Void)? = nil,
        now: @escaping @Sendable () -> Int64 = { MonotonicClock.nowNanoseconds() },
        present: @escaping DecodedFrameCoalescer.Present
    ) {
        let coalescer = DecodedFrameCoalescer(drops: drops, present: present)
        let decoder = makeDecoder(receipts) { frame in
            onDecodedFrame?(frame)
            coalescer.submit(frame)
        }
        let decodeQueue = VideoDecodeQueue(drops: drops) { packet in
            receipts?.recordSubmission(
                presentationTimeNanoseconds: Int64(bitPattern: packet.presentationTimeNanoseconds),
                submittedAtNanoseconds: now()
            )
            try decoder.decode(packet)
        }
        self.coalescer = coalescer
        self.decoder = decoder
        self.decodeQueue = decodeQueue
    }
}

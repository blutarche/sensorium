import Foundation
import SensoriumCore

public enum VideoCodec: Equatable, Sendable {
    case h264
    case hevc
}

/// Names an explicit encoder profile/level so `VideoToolboxEncoder` never lets
/// VideoToolbox pick a default.
public enum VideoEncoderProfileLevel: Equatable, Sendable {
    case baselineAutoLevel
    case mainAutoLevel
    case highAutoLevel
}

public struct VideoEncoderConfiguration: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let codec: VideoCodec
    /// How many frames ScreenCaptureKit keeps in its own pool. Three, not
    /// two: one is being encoded, one may be waiting behind it, and a still
    /// screen holds the third as the only copy of the picture it is showing
    /// until that picture has been sent again.
    public let maxQueueDepth: Int

    /// ScreenCaptureKit stream pixel dimensions: the resolution actually
    /// captured from the session canvas.
    public let captureWidth: Int
    public let captureHeight: Int

    /// VTCompressionSession destination pixel dimensions: the resolution
    /// actually encoded and sent. Kept separate from `captureWidth`/
    /// `captureHeight` so downscaling before encode is a deliberate choice.
    public let encodeWidth: Int
    public let encodeHeight: Int

    /// kVTCompressionPropertyKey_AverageBitRate, in bits per second.
    public let averageBitRate: Int
    /// kVTCompressionPropertyKey_DataRateLimits: caps output to at most
    /// `dataRateLimitBytes` bytes within any `dataRateLimitSeconds`-second
    /// window, so the encoder cannot run unconstrained.
    public let dataRateLimitBytes: Int
    public let dataRateLimitSeconds: Double
    /// kVTCompressionPropertyKey_MaxFrameDelayCount. 0 disables frame
    /// buffering, which interactive latency requires.
    public let maxFrameDelayCount: Int
    /// kVTCompressionPropertyKey_ProfileLevel.
    public let profileLevel: VideoEncoderProfileLevel
    /// When true, encoder creation requires a hardware-accelerated encoder
    /// and fails loudly rather than silently falling back to software.
    public let requiresHardwareAcceleration: Bool
    /// The fraction of the bitrate this resolution would otherwise get, so a
    /// link that cannot carry a sharp picture gets a softer one rather than a
    /// stalling one. Always inside `qualityScaleRange`; `averageBitRate` and
    /// `dataRateLimitBytes` already have it applied, so nothing downstream
    /// multiplies by it a second time.
    public let qualityScale: Double

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Int,
        codec: VideoCodec,
        maxQueueDepth: Int,
        captureWidth: Int,
        captureHeight: Int,
        encodeWidth: Int,
        encodeHeight: Int,
        averageBitRate: Int,
        dataRateLimitBytes: Int,
        dataRateLimitSeconds: Double,
        maxFrameDelayCount: Int,
        profileLevel: VideoEncoderProfileLevel,
        requiresHardwareAcceleration: Bool,
        qualityScale: Double = 1.0
    ) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.codec = codec
        self.maxQueueDepth = maxQueueDepth
        self.captureWidth = captureWidth
        self.captureHeight = captureHeight
        self.encodeWidth = encodeWidth
        self.encodeHeight = encodeHeight
        self.averageBitRate = averageBitRate
        self.dataRateLimitBytes = dataRateLimitBytes
        self.dataRateLimitSeconds = dataRateLimitSeconds
        self.maxFrameDelayCount = maxFrameDelayCount
        self.profileLevel = profileLevel
        self.requiresHardwareAcceleration = requiresHardwareAcceleration
        self.qualityScale = Self.clampedQualityScale(qualityScale)
    }

    /// The fraction of the canvas's native resolution this configuration
    /// actually encodes: `1.0` is the 1920x1200 logical size, `2.0` the real
    /// 3840x2400 pixels. Derived rather than stored so it can never disagree
    /// with the dimensions VideoToolbox is given.
    public var streamScale: Double {
        Double(encodeWidth) / Double(width)
    }

    /// Rebuilds at a different fraction of the canvas's native logical size,
    /// not of the current encode size, so repeated changes cannot compound.
    /// Both axes take the same factor, so aspect ratio is exact, and the
    /// bitrate and its burst ceiling follow the new pixel count. The frame
    /// rate and quality currently in force are carried over.
    public func scaled(toStreamScale scale: Double) -> Self {
        let scaledWidth = Int((Double(width) * scale).rounded())
        let scaledHeight = Int((Double(height) * scale).rounded())
        let bitRate = Self.averageBitRate(
            encodeWidth: scaledWidth,
            encodeHeight: scaledHeight,
            framesPerSecond: framesPerSecond,
            qualityScale: qualityScale
        )
        return Self(
            width: width,
            height: height,
            framesPerSecond: framesPerSecond,
            codec: codec,
            maxQueueDepth: maxQueueDepth,
            captureWidth: scaledWidth,
            captureHeight: scaledHeight,
            encodeWidth: scaledWidth,
            encodeHeight: scaledHeight,
            averageBitRate: bitRate,
            dataRateLimitBytes: Self.dataRateLimitBytes(averageBitRate: bitRate),
            dataRateLimitSeconds: dataRateLimitSeconds,
            maxFrameDelayCount: maxFrameDelayCount,
            profileLevel: profileLevel,
            requiresHardwareAcceleration: requiresHardwareAcceleration,
            qualityScale: qualityScale
        )
    }

    /// The same configuration at a different capture and encode frame rate.
    /// Bits per frame are untouched, so the per-second rate and its burst
    /// ceiling both move with the frame count.
    public func with(framesPerSecond newFramesPerSecond: Int) -> Self {
        let bitRate = Self.averageBitRate(
            encodeWidth: encodeWidth,
            encodeHeight: encodeHeight,
            framesPerSecond: newFramesPerSecond,
            qualityScale: qualityScale
        )
        return Self(
            width: width,
            height: height,
            framesPerSecond: newFramesPerSecond,
            codec: codec,
            maxQueueDepth: maxQueueDepth,
            captureWidth: captureWidth,
            captureHeight: captureHeight,
            encodeWidth: encodeWidth,
            encodeHeight: encodeHeight,
            averageBitRate: bitRate,
            dataRateLimitBytes: Self.dataRateLimitBytes(averageBitRate: bitRate),
            dataRateLimitSeconds: dataRateLimitSeconds,
            maxFrameDelayCount: maxFrameDelayCount,
            profileLevel: profileLevel,
            requiresHardwareAcceleration: requiresHardwareAcceleration,
            qualityScale: qualityScale
        )
    }

    /// The same resolution at a different fraction of its bitrate. The
    /// bitrate is re-derived from the encode dimensions rather than scaled
    /// from whatever this configuration currently carries, so stepping
    /// quality down and back up returns exactly the bitrate this resolution
    /// started with instead of compounding.
    public func with(qualityScale newQualityScale: Double) -> Self {
        let clamped = Self.clampedQualityScale(newQualityScale)
        let bitRate = Self.averageBitRate(
            encodeWidth: encodeWidth,
            encodeHeight: encodeHeight,
            framesPerSecond: framesPerSecond,
            qualityScale: clamped
        )
        return Self(
            width: width,
            height: height,
            framesPerSecond: framesPerSecond,
            codec: codec,
            maxQueueDepth: maxQueueDepth,
            captureWidth: captureWidth,
            captureHeight: captureHeight,
            encodeWidth: encodeWidth,
            encodeHeight: encodeHeight,
            averageBitRate: bitRate,
            dataRateLimitBytes: Self.dataRateLimitBytes(averageBitRate: bitRate),
            dataRateLimitSeconds: dataRateLimitSeconds,
            maxFrameDelayCount: maxFrameDelayCount,
            profileLevel: profileLevel,
            requiresHardwareAcceleration: requiresHardwareAcceleration,
            qualityScale: clamped
        )
    }

    /// The band a quality step may move within. The floor is the softest
    /// picture still worth streaming; below it the bitrate buys a stream
    /// nobody would rather be looking at than a lower resolution, which is
    /// the next lever down rather than this one.
    public static let qualityScaleRange: ClosedRange<Double> = 0.25...1.0

    /// A quality outside the band, or one that is not a real number, resolves
    /// to something an encoder can actually be given: a `NaN` multiplier would
    /// otherwise reach `Int(_:)` and trap.
    public static func clampedQualityScale(_ value: Double) -> Double {
        guard value.isFinite else { return qualityScaleRange.upperBound }
        return min(max(value, qualityScaleRange.lowerBound), qualityScaleRange.upperBound)
    }

    /// The frame rate the baseline below is quoted at: a configuration at
    /// this rate and full quality gets this resolution's full bitrate.
    public static let baselineFramesPerSecond = 60

    /// What one frame of this resolution is worth. Bits per pixel stays
    /// constant against the 1920x1200 / 12 Mbps at 60 fps baseline, so 4x the
    /// pixels (1920x1200 -> 3840x2400) gets 4x the bits.
    ///
    /// A frame-rate step holds this constant, which is why sending fewer
    /// frames lowers what the link must carry without softening any one
    /// frame; only `qualityScale` moves it.
    public static func bitsPerFrame(encodeWidth: Int, encodeHeight: Int, qualityScale: Double = 1.0) -> Double {
        let baselinePixels = 1920 * 1200
        let baselineBitRate = 12_000_000
        let pixels = encodeWidth * encodeHeight
        let fullQuality = Double(baselineBitRate) / Double(baselineFramesPerSecond) * Double(pixels) / Double(baselinePixels)
        return fullQuality * clampedQualityScale(qualityScale)
    }

    /// `kVTCompressionPropertyKey_Quality` for the one frame a still-screen
    /// refresh sends, which is encoded against a quality target rather than a
    /// bit rate.
    ///
    /// A bit rate is the wrong instrument for this frame, measured rather than
    /// assumed: VideoToolbox's average-bitrate control spends a fraction of a
    /// second's budget on any one frame no matter how large that budget is
    /// made, so raising the budget for a single frame bought roughly a fifth
    /// of the bits a screen of small text needs and left it soft. Quality mode
    /// asks for the picture instead of for a rate, and is only available on a
    /// session with no bit rate set at all -- which is why the refresh frame
    /// is encoded on a session of its own rather than on the stream's.
    public static let stillRefreshQuality = 0.95

    /// The softer attempts a frame over `stillRefreshCeilingBytes` earns, in
    /// the order they are tried. Quality mode has no upper bound on what a
    /// frame may cost, and content with no structure to predict -- a
    /// photograph, video paused mid-frame -- costs many times what a screen of
    /// text does at the same quality, so one step down is not always enough to
    /// bring such a picture inside a limit the wire enforces.
    public static let stillRefreshFallbackQualities: [Double] = [0.5, 0.3]

    /// The largest still-refresh frame this project's own wire format can
    /// carry: `EncodedVideoFrameCodec`'s payload cap, less the room a key
    /// frame's codec configuration takes out of that same cap.
    ///
    /// A refresh encoded above this is refused by `EncodedVideoFrameCodec.encode`
    /// at the moment of the write, which is far too late for anything to be
    /// done about it: the frame has already been reported as the picture that
    /// is going out.
    public static let stillRefreshTransportCeilingBytes =
        EncodedVideoFrameCodec.maximumPayloadLength - EncodedVideoFrameCodec.maximumCodecConfigurationLength

    /// What one refreshed still frame may cost: a second of this resolution
    /// at full motion, and never more than the transport accepts. Full
    /// quality, not the softened rate the moving screen was left at, since
    /// escaping that is what the refresh is for. Past roughly 6.3
    /// megapixels (4.59 MB at 3360x2100) the transport ceiling binds
    /// instead, so the smaller of the two is taken.
    public var stillRefreshCeilingBytes: Int {
        min(
            Self.averageBitRate(encodeWidth: encodeWidth, encodeHeight: encodeHeight) / 8,
            Self.stillRefreshTransportCeilingBytes
        )
    }

    /// The quality to encode this still frame at again, or `nil` when there is
    /// nothing left to try -- either because the frame already fits, or
    /// because every fallback has been spent.
    ///
    /// `attemptsMade` counts the encodes already done, so the first call after
    /// the opening attempt passes `1`.
    public static func stillRefreshRetryQuality(
        frameBytes: Int,
        ceilingBytes: Int,
        attemptsMade: Int
    ) -> Double? {
        guard frameBytes > ceilingBytes else { return nil }
        let index = attemptsMade - 1
        guard index >= 0, index < stillRefreshFallbackQualities.count else { return nil }
        return stillRefreshFallbackQualities[index]
    }

    /// `kVTCompressionPropertyKey_AverageBitRate`: what one frame of this
    /// resolution is worth, times how many of them each second carries.
    public static func averageBitRate(
        encodeWidth: Int,
        encodeHeight: Int,
        framesPerSecond: Int = baselineFramesPerSecond,
        qualityScale: Double = 1.0
    ) -> Int {
        let perFrame = bitsPerFrame(
            encodeWidth: encodeWidth,
            encodeHeight: encodeHeight,
            qualityScale: qualityScale
        )
        return Int((perFrame * Double(framesPerSecond)).rounded())
    }

    /// `kVTCompressionPropertyKey_DataRateLimits` byte budget, derived from
    /// `averageBitRate` so the burst ceiling scales with it rather than
    /// staying fixed at whatever a different resolution needed.
    ///
    /// Unlike `averageBitRate`, `DataRateLimits` is a hard per-window
    /// ceiling: VideoToolbox raises QP to stay under it rather than simply
    /// running over. Screen content legitimately bursts 10-20x a single
    /// frame's average share at a scene change (a resize, a window opening,
    /// scrolling), and this window is a full second wide. 10x matches the
    /// upper end of that measured burst ratio; at 1.5x a single burst frame
    /// was clipped, which is what makes the picture go soft the moment
    /// something moves.
    public static func dataRateLimitBytes(averageBitRate: Int) -> Int {
        Int((Double(averageBitRate) / 8.0 * 10.0).rounded())
    }

    /// The largest single dimension (width or height) this machine's hardware
    /// H.264 encoder accepts, measured directly rather than assumed:
    /// `VTCompressionSessionCreate`, given the same hardware-required
    /// encoder specification `VideoToolboxEncoder` uses, returns OSStatus
    /// -12903 the instant either dimension exceeds this -- confirmed
    /// independently on each axis (4096x4096 succeeds; 4224x2160 and
    /// 2160x5120 both fail). `fullHiDPI`'s 3840x2400 sits comfortably under
    /// it; a future encode resolution beyond roughly 4096 on either axis
    /// needs HEVC or tiling, not a larger H.264 request.
    public static let hardwareH264MaxDimension = 4096

    public static let remoteDefault = Self(
        width: 1920,
        height: 1200,
        framesPerSecond: 60,
        codec: .h264,
        maxQueueDepth: 3,
        captureWidth: 1920,
        captureHeight: 1200,
        encodeWidth: 1920,
        encodeHeight: 1200,
        averageBitRate: Self.averageBitRate(encodeWidth: 1920, encodeHeight: 1200),
        dataRateLimitBytes: Self.dataRateLimitBytes(averageBitRate: Self.averageBitRate(encodeWidth: 1920, encodeHeight: 1200)),
        dataRateLimitSeconds: 1.0,
        maxFrameDelayCount: 0,
        profileLevel: .mainAutoLevel,
        requiresHardwareAcceleration: true
    )

    /// Full HiDPI: captures and encodes the session canvas at its real
    /// 3840x2400 pixel resolution instead of the 1920x1200 logical size,
    /// so a Retina viewer is not upscaling a soft 1x stream. Opt-in behind
    /// `SENSORIUM_ENCODE_RESOLUTION=3840x2400`; see docs/testing.md.
    public static let fullHiDPI: VideoEncoderConfiguration = {
        let bitRate = Self.averageBitRate(encodeWidth: 3840, encodeHeight: 2400)
        return Self(
            width: 1920,
            height: 1200,
            framesPerSecond: 60,
            codec: .h264,
            maxQueueDepth: 3,
            captureWidth: 3840,
            captureHeight: 2400,
            encodeWidth: 3840,
            encodeHeight: 2400,
            averageBitRate: bitRate,
            dataRateLimitBytes: Self.dataRateLimitBytes(averageBitRate: bitRate),
            dataRateLimitSeconds: 1.0,
            maxFrameDelayCount: 0,
            profileLevel: .mainAutoLevel,
            requiresHardwareAcceleration: true
        )
    }()
}

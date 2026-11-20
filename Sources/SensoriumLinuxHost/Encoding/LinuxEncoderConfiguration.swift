#if os(Linux)
import Foundation
import SensoriumCore

/// The H.264 profile an encoder is asked for.
public enum LinuxEncoderProfile: Equatable, Sendable {
    /// Baseline with constraint_set1_flag set: no B-frames, no CABAC, no
    /// FMO, ASO or redundant slices. What every viewer decoder can take, and
    /// the one OpenH264's decoder releases a picture from at once.
    case constrainedBaseline
    case main
    case high

    /// The profile a viewer's `viewerDecoderPreference` asks for. A viewer
    /// that sent none gets constrained baseline too, which is also the macOS
    /// host's default.
    public init(viewerPreference: ViewerH264Profile?) {
        switch viewerPreference {
        case .constrainedBaseline, nil:
            self = .constrainedBaseline
        }
    }

    /// The `profile` option value libavcodec's H.264 encoders name it by.
    var libavName: String {
        switch self {
        case .constrainedBaseline: return "constrained_baseline"
        case .main: return "main"
        case .high: return "high"
        }
    }
}

/// Which libavcodec encoder runs.
public enum LinuxEncoderBackend: Equatable, Sendable {
    /// `h264_vaapi`: the GPU's encoder, through a VA-API render node.
    case vaapi
    /// `libopenh264`: software, the fallback when VA-API cannot encode.
    case openH264
}

public enum LinuxEncoderBackendPreference: Equatable, Sendable {
    /// VA-API when it opens, OpenH264 when it does not.
    case automatic
    case vaapi
    case openH264
}

/// What an encoder is built with. The Linux counterpart of the macOS host's
/// `VideoEncoderConfiguration`, with the same bit-rate rule so a stream costs
/// the same on either host.
public struct LinuxEncoderConfiguration: Equatable, Sendable {
    /// Encoded picture size. 4:2:0 video cannot be odd on either axis.
    public let width: Int
    public let height: Int
    public let framesPerSecond: Int
    public let profile: LinuxEncoderProfile
    /// The fraction of the bit rate this resolution would otherwise get.
    /// Inside `qualityScaleRange`.
    public let qualityScale: Double
    /// The longest the encoder goes without a key frame when nothing else
    /// asked for one. Counted in presentation time, not frames: capture is
    /// change-driven, and a quiet screen delivers far fewer frames than
    /// `framesPerSecond`.
    public let keyFrameIntervalSeconds: Double
    public let backendPreference: LinuxEncoderBackendPreference
    /// The DRM render node VA-API opens.
    public let renderNodePath: String

    public static let defaultRenderNodePath = "/dev/dri/renderD128"
    public static let standardKeyFrameIntervalSeconds: Double = 1
    public static let viewerRecoveryKeyFrameIntervalSeconds: Double = 10
    public static let qualityScaleRange: ClosedRange<Double> = 0.25...1.0
    public static let baselineFramesPerSecond = 60

    public init(
        width: Int,
        height: Int,
        framesPerSecond: Int = 60,
        profile: LinuxEncoderProfile = .constrainedBaseline,
        qualityScale: Double = 1.0,
        keyFrameIntervalSeconds: Double = standardKeyFrameIntervalSeconds,
        backendPreference: LinuxEncoderBackendPreference = .automatic,
        renderNodePath: String = defaultRenderNodePath
    ) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.profile = profile
        self.qualityScale = qualityScale.isFinite
            ? min(max(qualityScale, Self.qualityScaleRange.lowerBound), Self.qualityScaleRange.upperBound)
            : Self.qualityScaleRange.upperBound
        self.keyFrameIntervalSeconds = keyFrameIntervalSeconds
        self.backendPreference = backendPreference
        self.renderNodePath = renderNodePath
    }

    /// Bits per second for this resolution and rate: bits per pixel held
    /// constant against the macOS host's 1920x1200 at 60 fps and 12 Mbps
    /// baseline, scaled by `qualityScale`.
    public var averageBitRate: Int {
        let baselinePixels = 1920.0 * 1200.0
        let perFrame = 12_000_000.0 / Double(Self.baselineFramesPerSecond)
            * Double(width * height) / baselinePixels
        return Int((perFrame * qualityScale * Double(framesPerSecond)).rounded())
    }

    /// The most the encoder may spend in any one second, twice the average.
    /// Screen content bursts at a scene change, and the rate controller needs
    /// the room to put that burst in one key frame.
    public var peakBitRate: Int { averageBitRate * 2 }

    /// The key-frame interval counted in frames at this frame rate.
    public var maxKeyFrameIntervalFrames: Int {
        max(1, Int((Double(framesPerSecond) * keyFrameIntervalSeconds).rounded()))
    }

    var isEncodable: Bool {
        width >= 16 && height >= 16 && width % 2 == 0 && height % 2 == 0
            && framesPerSecond > 0 && keyFrameIntervalSeconds > 0
    }
}
#endif

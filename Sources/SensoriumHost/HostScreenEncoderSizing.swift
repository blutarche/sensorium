import SensoriumCore

/// The initial encoder configuration for a host-screen surface, derived
/// from the real target display's own geometry rather than the session
/// canvas's compiled-in 1920x1200 constant.
public enum HostScreenEncoderSizing {
    /// The configuration to actually use, and whether it was clamped down
    /// from the display's own uncapped size.
    public struct Result: Equatable {
        public let configuration: VideoEncoderConfiguration
        /// `true` when the display's own logical size exceeds
        /// `VideoEncoderConfiguration.hardwareH264MaxDimension` on either
        /// axis. A real 5K or 6K display's logical width can exceed what
        /// the hardware H.264 encoder accepts; leaving that uncapped would
        /// not degrade gracefully, it would fail encoder creation outright
        /// the moment someone tried host-screen mode on such a display.
        public let wasClamped: Bool
    }

    /// The largest stream scale this display may ever be encoded at.
    ///
    /// Two hard ceilings, whichever is lower. The display's own backing
    /// scale, because above it there are no further pixels in existence to
    /// encode and the picture would only cost more to send. And
    /// `VideoEncoderConfiguration.hardwareH264MaxDimension`, because a
    /// request past it does not degrade -- it fails encoder creation
    /// outright.
    ///
    /// May be below `StreamScalePolicy.minimumScale`, and deliberately is
    /// not floored at it: a display whose logical width already exceeds the
    /// encoder's limit is streamed below its own logical size, exactly as
    /// `resolve` above already sizes its opening configuration.
    public static func maximumStreamScale(for geometry: SessionSurfaceGeometry) -> Double {
        let maxDimension = Double(VideoEncoderConfiguration.hardwareH264MaxDimension)
        let width = Double(geometry.logicalWidth)
        let height = Double(geometry.logicalHeight)
        let encoderCeiling = Swift.min(
            width > 0 ? maxDimension / width : .infinity,
            height > 0 ? maxDimension / height : .infinity
        )
        let pixelCeiling = geometry.backingScale > 0 ? geometry.backingScale : 1.0
        return Swift.min(pixelCeiling, encoderCeiling)
    }

    /// - Parameter geometry: the target display's own `SessionSurfaceGeometry`,
    ///   exactly as `HostSessionController` resolved and returned it in
    ///   `hostScreenReady` -- never re-derived here.
    public static func resolve(for geometry: SessionSurfaceGeometry) -> Result {
        let maxDimension = Double(VideoEncoderConfiguration.hardwareH264MaxDimension)
        let width = Double(geometry.logicalWidth)
        let height = Double(geometry.logicalHeight)
        // Both axes take the same factor, matching
        // `VideoEncoderConfiguration.scaled(toStreamScale:)`'s own reasoning:
        // the display's own aspect ratio must survive uncapped, never
        // squashed onto one axis to fit the hardware limit.
        let capScale = Swift.min(
            1.0,
            width > 0 ? maxDimension / width : 1.0,
            height > 0 ? maxDimension / height : 1.0
        )
        let encodeWidth = Int((width * capScale).rounded())
        let encodeHeight = Int((height * capScale).rounded())
        let framesPerSecond = VideoEncoderConfiguration.remoteDefault.framesPerSecond
        // Named rather than left to the default: the bitrate is bits per frame
        // times the frame rate, so the rate this configuration is actually
        // built at is the rate it has to be budgeted at.
        let bitRate = VideoEncoderConfiguration.averageBitRate(
            encodeWidth: encodeWidth,
            encodeHeight: encodeHeight,
            framesPerSecond: framesPerSecond
        )
        let configuration = VideoEncoderConfiguration(
            width: geometry.logicalWidth,
            height: geometry.logicalHeight,
            framesPerSecond: framesPerSecond,
            codec: .h264,
            maxQueueDepth: VideoEncoderConfiguration.remoteDefault.maxQueueDepth,
            captureWidth: encodeWidth,
            captureHeight: encodeHeight,
            encodeWidth: encodeWidth,
            encodeHeight: encodeHeight,
            averageBitRate: bitRate,
            dataRateLimitBytes: VideoEncoderConfiguration.dataRateLimitBytes(averageBitRate: bitRate),
            dataRateLimitSeconds: VideoEncoderConfiguration.remoteDefault.dataRateLimitSeconds,
            maxFrameDelayCount: VideoEncoderConfiguration.remoteDefault.maxFrameDelayCount,
            profileLevel: VideoEncoderConfiguration.remoteDefault.profileLevel,
            requiresHardwareAcceleration: true
        )
        return Result(configuration: configuration, wasClamped: capScale < 1.0)
    }
}

import Foundation

/// One point on the fidelity ladder: everything the host needs to configure a
/// surface's picture, with the stream scale expressed as a number of steps
/// below whatever scale the viewer's geometry asked for rather than as an
/// absolute value, so a level stays meaningful when the viewer resizes.
public struct StreamFidelityLevel: Equatable, Sendable {
    public let framesPerSecond: Int
    /// Multiplies the bitrate the encoder would otherwise choose for these
    /// dimensions. `1.0` is the full rate; lower is a softer picture at the
    /// same resolution and frame rate.
    public let qualityScale: Double
    /// How many `StreamScalePolicy.quantum` steps below the requested scale
    /// this level streams at. `0` is the requested scale itself.
    public let scaleStepsBelowRequested: Int

    public init(framesPerSecond: Int, qualityScale: Double, scaleStepsBelowRequested: Int) {
        self.framesPerSecond = framesPerSecond
        self.qualityScale = qualityScale
        self.scaleStepsBelowRequested = scaleStepsBelowRequested
    }

    /// The absolute scale to stream at, never below
    /// `StreamScalePolicy.minimumScale`.
    public func streamScale(requestedScale: Double) -> Double {
        guard scaleStepsBelowRequested > 0 else {
            return requestedScale
        }
        let stepped = requestedScale - Double(scaleStepsBelowRequested) * StreamScalePolicy.quantum
        return Swift.max(StreamScalePolicy.minimumScale, stepped)
    }
}

/// The levers a surface's picture is lowered on, and the order they are spent
/// in: the frame rate down to 30 fps, then resolution, then quality and the
/// last of the frame rate. Ground comes back in the reverse order.
///
/// The frame rate leads because it keeps the picture sharp. On a remote
/// workstation the person at the viewer is mostly reading, and text that
/// stays legible matters more than motion above 30 fps. Fewer frames also
/// answer every stage that can fall behind: the encoder has longer for each
/// one, the link carries fewer, and the viewer decodes fewer.
///
/// Resolution is spent only once 30 fps is still behind. It is not stepped:
/// `StreamFidelityController` predicts what each scale would cost at the
/// frame rate in force from the cost it just measured, and names the largest
/// one that fits.
///
/// Quality and the frame rate below 30 fps move only once the scale has
/// reached `StreamScalePolicy.minimumScale` and something is still behind.
/// Quality goes first, because a picture below 30 fps is worse to look at
/// than a softer one.
public enum StreamFidelityLadder {
    /// Frame rates a surface may be held to, fastest first.
    public static let frameRates: [Int] = [60, 45, 30, 20]
    /// Bitrate multipliers, sharpest first.
    public static let qualityScales: [Double] = [1.0, 0.75, 0.5]

    /// The index of the full frame rate and the full quality: what a surface
    /// streams while nothing is behind.
    public static let fullFrameRateIndex = 0
    public static let fullQualityIndex = 0

    /// The slowest frame rate reached before resolution is spent. A picture
    /// below this is slow enough to be unpleasant to watch, so the rest of
    /// the frame rate is the last thing given up, after resolution and
    /// quality.
    public static let gentleFrameRateFloorIndex = 2

    public static var slowestFrameRateIndex: Int { frameRates.count - 1 }
    public static var softestQualityIndex: Int { qualityScales.count - 1 }

    /// A frame rate index outside the list is clamped rather than refused: a
    /// caller holding a stale index still has to be given something it can
    /// stream.
    public static func frameRate(at index: Int) -> Int {
        frameRates[Swift.min(Swift.max(index, 0), slowestFrameRateIndex)]
    }

    public static func qualityScale(at index: Int) -> Double {
        qualityScales[Swift.min(Swift.max(index, 0), softestQualityIndex)]
    }

    /// How many `StreamScalePolicy.quantum` steps separate `requestedScale`
    /// from the minimum scale. A viewer already asking for the minimum has
    /// none, and a surface at 30 fps goes straight on to quality.
    public static func scaleStepCount(requestedScale: Double) -> Int {
        guard requestedScale.isFinite else {
            return 0
        }
        let steps = (requestedScale - StreamScalePolicy.minimumScale) / StreamScalePolicy.quantum
        return Swift.max(0, Int(steps.rounded()))
    }

    public static func level(
        scaleStepsBelowRequested: Int,
        frameRateIndex: Int,
        qualityIndex: Int
    ) -> StreamFidelityLevel {
        StreamFidelityLevel(
            framesPerSecond: frameRate(at: frameRateIndex),
            qualityScale: qualityScale(at: qualityIndex),
            scaleStepsBelowRequested: Swift.max(0, scaleStepsBelowRequested)
        )
    }
}

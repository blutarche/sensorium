import Foundation

/// Where the moving block of the capture test pattern sits at a given time.
///
/// Pure triangle-wave arithmetic, so a benchmark run has deterministic
/// motion.
public struct TestPatternPhase: Equatable, Sendable {
    private let rangeX: Double
    private let rangeY: Double
    private let speed: Double

    public init(
        canvasWidth: Double,
        canvasHeight: Double,
        blockWidth: Double,
        blockHeight: Double,
        speedPointsPerSecond: Double
    ) {
        rangeX = max(0, canvasWidth - blockWidth)
        rangeY = max(0, canvasHeight - blockHeight)
        speed = max(0, speedPointsPerSecond)
    }

    public func position(atSeconds seconds: Double) -> (x: Double, y: Double) {
        (bounce(travel: speed * seconds, within: rangeX),
         bounce(travel: speed * seconds, within: rangeY))
    }

    /// Reflects unbounded travel into [0, range] as a triangle wave.
    private func bounce(travel: Double, within range: Double) -> Double {
        guard range > 0 else { return 0 }
        let period = 2 * range
        let phase = travel.truncatingRemainder(dividingBy: period)
        return phase <= range ? phase : period - phase
    }
}

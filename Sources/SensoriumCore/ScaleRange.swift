import Foundation

/// The bounds a stream scale must fall within, and the step size scales
/// quantize to. General on purpose: the session canvas has one
/// (`StreamScalePolicy.sessionCanvasRange`), a captured physical display in
/// host-screen mode has another -- its own native resolution, its own
/// reasonable HiDPI ceiling. Neither owns this type; both ask it for the
/// same three operations.
public struct ScaleRange: Equatable, Sendable {
    public let minimum: Double
    public let maximum: Double
    public let quantum: Double

    public init(minimum: Double, maximum: Double, quantum: Double) {
        self.minimum = minimum
        self.maximum = maximum
        self.quantum = quantum
    }

    /// Every valid step between `minimum` and `maximum`, `quantum` apart --
    /// what a resolution picker offers.
    public var steps: [Double] {
        stride(from: minimum, through: maximum, by: quantum).map { $0 }
    }

    /// `true` when `scale` is already within `minimum...maximum`. Does not
    /// check quantization; a value can be in range without being on a step.
    public func contains(_ scale: Double) -> Bool {
        scale >= minimum && scale <= maximum
    }

    /// Rounds to the nearest step rather than down: half a step of extra
    /// resolution is cheaper than a visibly soft picture.
    public func quantized(_ scale: Double) -> Double {
        (scale / quantum).rounded() * quantum
    }

    /// `scale` brought inside `minimum...maximum` and onto a real step:
    /// clamped, then quantized. What an out-of-range or off-quantum value
    /// is normalized to rather than refused outright.
    public func normalized(_ scale: Double) -> Double {
        quantized(Swift.min(Swift.max(scale, minimum), maximum))
    }
}

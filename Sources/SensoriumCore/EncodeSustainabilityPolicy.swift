import Foundation

/// What an encode-stage measurement has to clear before it means anything:
/// the frame period the encoder is trying to hit, and how many samples a
/// verdict needs behind it.
///
/// Measured on an Apple-silicon Mac mini, 1920x1200 static content over a
/// 10s window: 1.0x costs 10.3ms p50 encode, comfortably under a
/// 16.7ms/frame budget at 60fps, while 2.0x costs 33.4ms p50 and drops
/// 28.5% of frames. `StreamScalePolicy`
/// derives a scale purely from the viewer's drawable size and has no notion of
/// either number. `StreamFidelityPressure` is what reads them, and this is
/// where the two thresholds it reads against live.
public enum EncodeSustainabilityPolicy {
    /// One frame period at `framesPerSecond`: the time the encoder has for a
    /// frame before it is holding the stream up rather than keeping pace.
    public static func frameBudgetNanoseconds(framesPerSecond: Int) -> Int64 {
        Int64(1_000_000_000 / Swift.max(1, framesPerSecond))
    }

    /// How many encode-only samples a surface's checkpoint must hold before
    /// its p50 is trusted at all. Capture is change-driven, so a quiet screen
    /// can deliver only a handful of frames between two ticks -- and the first
    /// of those, right after a rebuild, is the encoder's opening IDR: the
    /// largest and slowest frame it will ever produce, and no measure of what
    /// the applied fidelity costs in steady state. Below this count there is
    /// not yet a real sample of ongoing cost, only warm-up.
    public static let minimumSampleCount = 5

    /// Whether a checkpoint holding `sampleCount` samples has enough to back
    /// a verdict at all, independent of what the samples say.
    public static func hasEnoughSamples(_ sampleCount: Int) -> Bool {
        sampleCount >= minimumSampleCount
    }
}

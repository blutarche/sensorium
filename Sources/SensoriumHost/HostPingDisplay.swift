import Foundation

/// Turns the viewer's own reported clock-sync round trip -- untrusted input
/// from the far end of the wire -- into the one word the operator reads next
/// to the menu-bar icon while a session is live. Display-only, and nothing
/// downstream of it may become anything else: no security, gating or session
/// decision may ever read this value. See `ViewerTelemetrySample.roundTripNanoseconds`,
/// the wire field this is built from.
public struct HostPingDisplay: Sendable {
    /// A reported round trip outside this range (in milliseconds) is not a
    /// measurement this machine trusts -- negative or non-finite is a wire
    /// that lied, and one this large is more likely a stalled clock than a
    /// real trip -- so it is dropped rather than shown.
    public static let plausibleMillisecondsRange = 0.0...10_000.0

    /// How long a sample stays current once no fresher one has arrived. Three
    /// seconds is three missed ticks at the one-per-second cadence every
    /// sample arrives on: long enough that one slow tick does not blank the
    /// number, short enough that a session that has actually gone quiet stops
    /// claiming a ping it no longer has.
    public static let staleAfterSeconds: Double = 3

    /// The last five accepted samples, oldest first -- enough to smooth one
    /// noisy tick without lagging behind a link that has genuinely changed.
    private static let smoothingWindow = 5

    private var samples: [Int64] = []
    private var lastSampleAtSeconds: Double?

    public init() {}

    /// One tick's reading. `roundTripNanoseconds` is `nil` when this tick
    /// carried no fresh sample -- an old-format viewer, or a session that has
    /// not yet completed a clock sync -- and is dropped rather than treated
    /// as a zero. A value outside `plausibleMillisecondsRange` is dropped the
    /// same way: display-only or not, a number this obviously wrong is never
    /// shown as if it were real.
    public mutating func record(roundTripNanoseconds: Int64?, atSeconds now: Double) {
        guard let roundTripNanoseconds,
              Self.isPlausible(milliseconds: Double(roundTripNanoseconds) / 1_000_000) else {
            return
        }
        // A gap long enough to have already gone stale is a fresh start, not
        // a continuation: blending this sample against ones from before a
        // silence would still be describing a link that is not the one this
        // sample is actually reporting on.
        if let lastSampleAtSeconds, now - lastSampleAtSeconds > Self.staleAfterSeconds {
            samples.removeAll()
        }
        samples.append(roundTripNanoseconds)
        if samples.count > Self.smoothingWindow {
            samples.removeFirst(samples.count - Self.smoothingWindow)
        }
        lastSampleAtSeconds = now
    }

    /// The median of the last few accepted samples, or `nil` once
    /// `staleAfterSeconds` has passed with nothing fresh -- no number is the
    /// honest answer for a session that has stopped reporting, never the
    /// last flattering one. What `HostOperatorStatusStore.recordPing` stores;
    /// `title(atSeconds:)` below is this, formatted.
    public func currentRoundTripNanoseconds(atSeconds now: Double) -> Int64? {
        guard let lastSampleAtSeconds, now - lastSampleAtSeconds <= Self.staleAfterSeconds, !samples.isEmpty else {
            return nil
        }
        return medianNanoseconds()
    }

    /// The menu bar's own words for the current reading -- `currentRoundTripNanoseconds(atSeconds:)`,
    /// formatted.
    public func title(atSeconds now: Double) -> String? {
        guard let nanoseconds = currentRoundTripNanoseconds(atSeconds: now) else {
            return nil
        }
        return Self.title(forMilliseconds: Double(nanoseconds) / 1_000_000)
    }

    private func medianNanoseconds() -> Int64 {
        let sorted = samples.sorted()
        let middle = sorted.count / 2
        guard sorted.count.isMultiple(of: 2) else {
            return sorted[middle]
        }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }

    public static func isPlausible(milliseconds: Double) -> Bool {
        milliseconds.isFinite && plausibleMillisecondsRange.contains(milliseconds)
    }

    /// Rounded to the nearest millisecond, `<1ms` below a whole one and
    /// `>999ms` above what three digits hold, so the title never grows past
    /// four characters and the menu bar never jitters width. `nil` for
    /// anything `isPlausible(milliseconds:)` would already have dropped.
    public static func title(forMilliseconds milliseconds: Double) -> String? {
        guard isPlausible(milliseconds: milliseconds) else {
            return nil
        }
        if milliseconds < 1 {
            return "<1ms"
        }
        let rounded = Int(milliseconds.rounded())
        return rounded > 999 ? ">999ms" : "\(rounded)ms"
    }
}

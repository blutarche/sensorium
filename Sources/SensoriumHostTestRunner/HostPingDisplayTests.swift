import Foundation
import SensoriumHost

/// `HostPingDisplay`'s own formatting, smoothing and staleness -- pure and
/// AppKit-free, so every edge is a direct assertion rather than a `Mirror`
/// read of a menu-bar item.
func runHostPingDisplayTests() async {
    do {
        // Formatting edges, in milliseconds directly: below one, an ordinary
        // value, and above what three digits hold.
        expect(HostPingDisplay.title(forMilliseconds: 0.4) == "<1ms", "under a millisecond reads as less than one")
        expect(HostPingDisplay.title(forMilliseconds: 8.6) == "9ms", "an ordinary value rounds to the nearest millisecond")
        expect(HostPingDisplay.title(forMilliseconds: 1_500) == ">999ms", "anything past three digits is capped rather than grown")
        expect(HostPingDisplay.title(forMilliseconds: .nan) == nil, "a value that is not a number is dropped")
        expect(HostPingDisplay.title(forMilliseconds: -1) == nil, "a negative value is dropped")
        expect(HostPingDisplay.title(forMilliseconds: .infinity) == nil, "an infinite value is dropped")
        expect(HostPingDisplay.title(forMilliseconds: 999.4) == "999ms", "just under the cap still reads as itself")
        expect(HostPingDisplay.title(forMilliseconds: 999.5) == ">999ms", "rounding into four digits is capped, not shown as 1000ms")

        print("PASS: HostPingDisplay's formatting rounds to the nearest millisecond, floors below one, caps above 999, and drops anything that is not a real duration")
    }

    do {
        // The median of the last five samples smooths one noisy tick without
        // lagging behind a link that has actually changed.
        var display = HostPingDisplay()
        for (index, milliseconds) in [8.0, 9.0, 40.0, 8.0, 8.0].enumerated() {
            display.record(roundTripNanoseconds: Int64(milliseconds * 1_000_000), atSeconds: Double(index))
        }
        expect(
            display.title(atSeconds: 4) == "8ms",
            "one spike among five samples is outvoted by the median, got \(display.title(atSeconds: 4) ?? "nil")"
        )

        // A partial window (fewer than five samples so far) still reports a
        // median of whatever has arrived.
        var partial = HostPingDisplay()
        partial.record(roundTripNanoseconds: 6_000_000, atSeconds: 0)
        partial.record(roundTripNanoseconds: 10_000_000, atSeconds: 1)
        expect(
            partial.title(atSeconds: 1) == "8ms",
            "two samples median to their average, got \(partial.title(atSeconds: 1) ?? "nil")"
        )

        print("PASS: HostPingDisplay reports the median of up to its last five samples")
    }

    do {
        // No sample for three seconds shows no number, never the last one.
        var display = HostPingDisplay()
        display.record(roundTripNanoseconds: 8_000_000, atSeconds: 0)
        expect(display.title(atSeconds: 3) == "8ms", "a reading inside the staleness window is still current")
        expect(display.title(atSeconds: 3.01) == nil, "a reading past the staleness window is gone, not a stale number")

        // A fresh sample clears the staleness clock again.
        display.record(roundTripNanoseconds: 12_000_000, atSeconds: 3.01)
        expect(display.title(atSeconds: 6.0) == "12ms", "a fresh sample resets how long the reading stays current")

        print("PASS: HostPingDisplay shows no number once three seconds have passed with nothing fresh")
    }

    do {
        // Untrusted input: a viewer's reported round trip outside the
        // plausible range is dropped rather than shown, and never disturbs a
        // reading already in force.
        var display = HostPingDisplay()
        display.record(roundTripNanoseconds: 8_000_000, atSeconds: 0)
        display.record(roundTripNanoseconds: -1, atSeconds: 1)
        display.record(roundTripNanoseconds: 20_000_000_000, atSeconds: 1)
        display.record(roundTripNanoseconds: nil, atSeconds: 1)
        expect(
            display.title(atSeconds: 1) == "8ms",
            "an implausible or absent sample is dropped and leaves the existing reading exactly as it was"
        )

        print("PASS: HostPingDisplay drops an implausible or absent round trip rather than showing or losing the last good one")
    }
}

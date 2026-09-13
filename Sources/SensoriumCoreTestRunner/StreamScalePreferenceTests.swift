import Foundation
import SensoriumCore

func testStreamScalePreferenceComposesWithTheSustainabilityCeiling() {
    // Automatic behaves exactly as today
    // No ceiling: the geometry-derived scale passes through unchanged.
    expect(
        StreamScalePreference.automatic.resolve(geometryScale: 1.75, sustainabilityCeiling: nil)
            == StreamScaleResolution(scale: 1.75, clampedFromUserChoice: nil),
        "automatic with no learned ceiling streams exactly what geometry derived"
    )
    // A ceiling below what geometry derived still wins -- but never
    // reported as a user choice being overridden, since there was no
    // explicit choice.
    expect(
        StreamScalePreference.automatic.resolve(geometryScale: 2.0, sustainabilityCeiling: 1.5)
            == StreamScaleResolution(scale: 1.5, clampedFromUserChoice: nil),
        "automatic still yields to a learned ceiling, exactly as before this type existed"
    )
    // A ceiling above what geometry derived changes nothing.
    expect(
        StreamScalePreference.automatic.resolve(geometryScale: 1.25, sustainabilityCeiling: 1.75)
            == StreamScaleResolution(scale: 1.25, clampedFromUserChoice: nil),
        "automatic is untouched by a ceiling it does not exceed"
    )

    // A chosen scale is honoured
    expect(
        StreamScalePreference.fixed(1.5).resolve(geometryScale: 1.0, sustainabilityCeiling: nil)
            == StreamScaleResolution(scale: 1.5, clampedFromUserChoice: nil),
        "a fixed choice is honoured exactly, ignoring what geometry alone would have derived"
    )
    expect(
        StreamScalePreference.fixed(1.5).resolve(geometryScale: 1.0, sustainabilityCeiling: 1.75)
            == StreamScaleResolution(scale: 1.5, clampedFromUserChoice: nil),
        "a fixed choice below the ceiling is honoured exactly, and not reported as clamped"
    )
    expect(
        StreamScalePreference.fixed(1.5).resolve(geometryScale: 1.0, sustainabilityCeiling: 1.5)
            == StreamScaleResolution(scale: 1.5, clampedFromUserChoice: nil),
        "a fixed choice exactly at the ceiling is honoured, not clamped -- the boundary favours the person"
    )

    // A chosen scale above a learned ceiling clamps and reports it
    let overCeiling = StreamScalePreference.fixed(2.0).resolve(geometryScale: 1.0, sustainabilityCeiling: 1.75)
    expect(
        overCeiling == StreamScaleResolution(scale: 1.75, clampedFromUserChoice: 2.0),
        "a choice the ceiling contradicts is clamped to the ceiling, and the resolution names both what streams and what the person actually asked for"
    )

    // An out-of-range or off-quantum choice is snapped
    // Snapped rather than rejected: see the reasoning on
    // StreamScalePreference.normalized. Verified through both `normalized`
    // directly and through `resolve`, since resolve must apply the same
    // normalization rather than passing a raw, unvalidated value through.
    expect(
        StreamScalePreference.fixed(1.3).normalized == .fixed(1.25),
        "an off-quantum choice snaps to the nearest quantum step"
    )
    expect(
        StreamScalePreference.fixed(1.4).normalized == .fixed(1.5),
        "rounding to the nearest quantum rounds up when that is nearer, not always down"
    )
    expect(
        StreamScalePreference.fixed(5.0).normalized == .fixed(StreamScalePolicy.maximumScale),
        "a choice above the maximum snaps down to it rather than being refused"
    )
    expect(
        StreamScalePreference.fixed(0.1).normalized == .fixed(StreamScalePolicy.minimumScale),
        "a choice below the minimum snaps up to it rather than being refused"
    )
    expect(
        StreamScalePreference.automatic.normalized == .automatic,
        "automatic has nothing to snap and is returned unchanged"
    )
    expect(
        StreamScalePreference.fixed(1.3).resolve(geometryScale: 1.0, sustainabilityCeiling: nil)
            == StreamScaleResolution(scale: 1.25, clampedFromUserChoice: nil),
        "resolve normalizes an off-quantum choice before honouring it, not after -- the snapped value is what streams"
    )

    // The offerable list stays consistent with the underlying bounds
    expect(
        StreamScalePreference.offerableScales == StreamScalePolicy.steps,
        "the offerable list is StreamScalePolicy's own steps, not a second list that could drift from it"
    )
    let recomputedSteps = stride(
        from: StreamScalePolicy.minimumScale,
        through: StreamScalePolicy.maximumScale,
        by: StreamScalePolicy.quantum
    ).map { $0 }
    expect(
        StreamScalePreference.offerableScales == recomputedSteps,
        "the offerable list is exactly what minimum, maximum, and quantum derive today -- proof it is computed, not hand-copied"
    )
    expect(
        StreamScalePreference.offerableScales.first == StreamScalePolicy.minimumScale
            && StreamScalePreference.offerableScales.last == StreamScalePolicy.maximumScale,
        "the offerable list spans exactly the policy's own bounds"
    )
    expect(
        StreamScalePreference.offerableScales.allSatisfy { StreamScalePolicy.quantize($0) == $0 },
        "every offerable scale is already a valid quantum step"
    )
}

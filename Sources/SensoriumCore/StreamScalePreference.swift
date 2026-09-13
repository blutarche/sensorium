import Foundation

/// The scale actually chosen, after any clamp `StreamScalePreference.resolve`
/// applied.
public struct StreamScaleResolution: Equatable, Sendable {
    /// The scale to actually stream at.
    public let scale: Double
    /// The scale a person explicitly asked for, when a learned
    /// sustainability ceiling clamped `scale` down from it -- what the
    /// window reports instead of silently overriding the choice. `nil` for
    /// `.automatic` (there is no explicit ask to contradict: the ceiling
    /// clamp on a geometry-derived scale already has its own, separate
    /// report) and for a `.fixed` choice the ceiling did not touch.
    public let clampedFromUserChoice: Double?

    public init(scale: Double, clampedFromUserChoice: Double?) {
        self.scale = scale
        self.clampedFromUserChoice = clampedFromUserChoice
    }
}

/// What a person wants the stream scale to be, independent of what the
/// viewer's window geometry or this machine's own measured limits allow. A
/// sibling to `StreamScalePolicy` rather than an addition to it:
/// `StreamScalePolicy` derives a scale purely from geometry and has no
/// notion of a person overriding that, while this type is entirely about
/// that override -- its two states, how a chosen value is kept valid, and
/// how it composes with the fidelity controller's measured ceiling. It reuses
/// `StreamScalePolicy`'s bounds and quantum rather than defining its own, so
/// the two can never drift apart.
public enum StreamScalePreference: Equatable, Sendable {
    /// The scale follows the viewer's drawable size, as
    /// `StreamScalePolicy.scale` derives it.
    case automatic
    /// A specific scale a person asked to stream at, regardless of window
    /// size. Not necessarily itself a valid, quantized, in-range value --
    /// see `normalized`.
    case fixed(Double)

    /// Every scale a person can choose from: `StreamScalePolicy`'s own
    /// quantized steps between its minimum and maximum. Derived, not a
    /// second hardcoded list, so it can never drift out of step with the
    /// bounds enforced everywhere else a scale is validated.
    public static var offerableScales: [Double] { StreamScalePolicy.steps }

    /// This preference with a `.fixed` value brought onto a real, offerable
    /// step: clamped into `StreamScalePolicy.minimumScale...maximumScale`
    /// and rounded to the nearest quantum. Snapped rather than rejected --
    /// the same choice `StreamScalePolicy.scale` already makes for an
    /// out-of-range or off-quantum geometry-derived request, for the same
    /// reason: a nearby valid value almost always exists and is a better
    /// answer than an outright failure, whether the input came from a value
    /// written under a different quantum, or one assembled by hand.
    /// `.automatic` is returned unchanged -- there is nothing to snap.
    public var normalized: StreamScalePreference {
        switch self {
        case .automatic:
            return .automatic
        case .fixed(let scale):
            return .fixed(StreamScalePolicy.sessionCanvasRange.normalized(scale))
        }
    }

    /// Resolves this preference against what the viewer's geometry would
    /// derive on its own (`geometryScale`, `.automatic`'s answer) and the
    /// highest scale this session has actually been measured to sustain
    /// (`sustainabilityCeiling`, `nil` until something has measured
    /// unsustainable).
    ///
    /// The ceiling always wins: a person choosing 2.00x on a link that has
    /// repeatedly proven it cannot carry 2.00x gets the ceiling, not a
    /// picture the encoder cannot actually hold, and `clampedFromUserChoice`
    /// reports that it happened rather than silently overriding the choice.
    /// A `.fixed` choice the ceiling does not contradict is honoured
    /// exactly, at the value itself -- no further geometry-driven
    /// second-guessing once a person has stated a preference.
    public func resolve(
        geometryScale: Double,
        sustainabilityCeiling: Double?
    ) -> StreamScaleResolution {
        switch normalized {
        case .automatic:
            let scale = Swift.min(geometryScale, sustainabilityCeiling ?? .infinity)
            return StreamScaleResolution(scale: scale, clampedFromUserChoice: nil)
        case .fixed(let requested):
            guard let sustainabilityCeiling, requested > sustainabilityCeiling else {
                return StreamScaleResolution(scale: requested, clampedFromUserChoice: nil)
            }
            return StreamScaleResolution(scale: sustainabilityCeiling, clampedFromUserChoice: requested)
        }
    }
}

/// Local persistence only (`SavedHost`) -- distinct from `SensoriumFrameCodec`,
/// the wire's own encoding for the `streamScalePreference` control message.
/// The two formats are free to diverge; this one only ever has to read back
/// what this same build wrote.
extension StreamScalePreference: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case scale
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .kind) {
        case "automatic":
            self = .automatic
        case "fixed":
            self = .fixed(try container.decode(Double.self, forKey: .scale))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "unrecognized StreamScalePreference kind"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .automatic:
            try container.encode("automatic", forKey: .kind)
        case let .fixed(scale):
            try container.encode("fixed", forKey: .kind)
            try container.encode(scale, forKey: .scale)
        }
    }
}

import Foundation

/// A scripted schedule of pointer motion for an unattended latency run:
/// alternating stretches where a synthetic pointer moves and where it rests.
///
/// The spec is comma-separated phases, each `move:<seconds>` or
/// `still:<seconds>`, for example `move:20,still:40,move:20`. Times count from
/// the moment the run is ready, which the caller decides.
public struct BenchmarkPointerPlan: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case move
        case still
    }

    public struct Phase: Equatable, Sendable {
        public let kind: Kind
        public let seconds: Double
    }

    public let phases: [Phase]

    /// `nil` unless every phase is a known kind with a finite, positive
    /// length and the spec has no empty entries.
    public init?(parsing specification: String) {
        var parsed: [Phase] = []
        for entry in specification.split(separator: ",", omittingEmptySubsequences: false) {
            let parts = entry.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let kind = Kind(rawValue: String(parts[0])),
                  let seconds = Double(parts[1]),
                  seconds.isFinite, seconds > 0 else {
                return nil
            }
            parsed.append(Phase(kind: kind, seconds: seconds))
        }
        guard !parsed.isEmpty else { return nil }
        phases = parsed
    }

    public var totalSeconds: Double {
        phases.reduce(0) { $0 + $1.seconds }
    }

    /// The spec in the form `init(parsing:)` reads, with whole seconds shown
    /// without a fraction.
    public var specification: String {
        phases.map { phase in
            let seconds = phase.seconds == phase.seconds.rounded()
                ? String(Int(phase.seconds))
                : String(phase.seconds)
            return "\(phase.kind.rawValue):\(seconds)"
        }.joined(separator: ",")
    }

    /// The phase running `seconds` after the start; `nil` before the start
    /// and once the plan has ended.
    public func phase(atSeconds seconds: Double) -> Kind? {
        guard seconds >= 0 else { return nil }
        var phaseStart = 0.0
        for phase in phases {
            if seconds < phaseStart + phase.seconds {
                return phase.kind
            }
            phaseStart += phase.seconds
        }
        return nil
    }

    public func isMoving(atSeconds seconds: Double) -> Bool {
        phase(atSeconds: seconds) == .move
    }

    /// Where the pointer is `seconds` into the run: a slow ellipse around the
    /// middle of a `width` by `height` canvas, always inside it.
    public static func pointerPosition(atSeconds seconds: Double, width: Double, height: Double) -> (x: Double, y: Double) {
        let angle = 2 * Double.pi * seconds / ellipsePeriodSeconds
        return (
            x: width / 2 + width * ellipseRadiusFraction * cos(angle),
            y: height / 2 + height * ellipseRadiusFraction * sin(angle)
        )
    }

    private static let ellipsePeriodSeconds = 8.0
    private static let ellipseRadiusFraction = 0.3
}

/// The longest stretch between two consecutive presented frames, which is how
/// long the picture stood still: overall, and counting only stretches that
/// touch a moving phase.
public struct PresentGapTracker: Sendable {
    public private(set) var longestGapNanoseconds: Int64?
    public private(set) var longestMovingGapNanoseconds: Int64?
    private var previous: (atNanoseconds: Int64, moving: Bool)?

    public init() {}

    /// A gap counts as moving when either frame that bounds it was presented
    /// during motion, so a freeze that starts while the pointer moves is not
    /// credited to the still phase that follows it.
    public mutating func notePresented(atNanoseconds: Int64, moving: Bool) {
        defer { previous = (atNanoseconds, moving) }
        guard let previous else { return }
        let gap = atNanoseconds - previous.atNanoseconds
        longestGapNanoseconds = max(longestGapNanoseconds ?? gap, gap)
        if moving || previous.moving {
            longestMovingGapNanoseconds = max(longestMovingGapNanoseconds ?? gap, gap)
        }
    }
}

/// The single machine-readable line a benchmark run prints when it ends.
public enum BenchmarkReport {
    public static let prefix = "bench-viewer "

    /// Each `SessionMetrics.traceLines()` entry as an object, keyed by its
    /// `stage`. A line that is not a JSON object naming a stage is skipped.
    public static func traceObjects(from lines: [String]) -> [String: Any] {
        var objects: [String: Any] = [:]
        for line in lines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let stage = object["stage"] as? String else {
                continue
            }
            objects[stage] = object
        }
        return objects
    }

    /// `fields` as one line of JSON with sorted keys, after `prefix`. Values
    /// must be JSON-encodable; an unencodable set of fields yields a line
    /// carrying only an error.
    public static func line(_ fields: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(fields),
              let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes]),
              let json = String(data: data, encoding: .utf8) else {
            return prefix + #"{"error":"report fields were not encodable"}"#
        }
        return prefix + json
    }
}

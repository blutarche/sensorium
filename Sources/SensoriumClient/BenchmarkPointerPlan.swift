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

    /// The index in `phases` of the phase running `seconds` after the start.
    public func phaseIndex(atSeconds seconds: Double) -> Int? {
        guard seconds >= 0 else { return nil }
        var phaseStart = 0.0
        for (index, phase) in phases.enumerated() {
            if seconds < phaseStart + phase.seconds {
                return index
            }
            phaseStart += phase.seconds
        }
        return nil
    }

    /// The index and start time of each move phase that directly follows a
    /// still phase.
    func moveStartsFollowingStill() -> [(phase: Int, startSeconds: Double)] {
        var starts: [(phase: Int, startSeconds: Double)] = []
        var phaseStart = 0.0
        for (index, phase) in phases.enumerated() {
            if phase.kind == .move, index > 0, phases[index - 1].kind == .still {
                starts.append((index, phaseStart))
            }
            phaseStart += phase.seconds
        }
        return starts
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

/// How long the picture stood still between consecutive presented frames:
/// the longest stretch overall, the longest within a single move phase, and
/// how long motion took to show a frame after a move phase began.
public struct PresentGapTracker: Sendable {
    public private(set) var longestGapNanoseconds: Int64?
    public private(set) var longestMovingGapNanoseconds: Int64?
    /// The largest wait, across move phases that follow a still phase, from
    /// the phase's start to the first frame presented at or after it.
    public private(set) var firstFrameAfterMoveStartNanoseconds: Int64?
    private let plan: BenchmarkPointerPlan?
    private var previous: (atNanoseconds: Int64, movePhase: Int?)?
    private var awaitingFirstFrame: [(phase: Int, startSeconds: Double)]

    /// `plan` places each frame in a phase; without one only the overall
    /// longest gap is known.
    public init(plan: BenchmarkPointerPlan?) {
        self.plan = plan
        awaitingFirstFrame = plan?.moveStartsFollowingStill() ?? []
    }

    /// `secondsIntoPlan` is when the frame was presented, counted from the
    /// plan's start; `nil` if the plan has not started. A gap counts as moving
    /// only when both frames that bound it fall in the same move phase, so a
    /// still phase is never credited as a freeze during motion.
    public mutating func notePresented(atNanoseconds: Int64, secondsIntoPlan: Double?) {
        let movePhase = secondsIntoPlan.flatMap { seconds in
            plan?.phaseIndex(atSeconds: seconds).flatMap { plan?.phases[$0].kind == .move ? $0 : nil }
        }
        defer { previous = (atNanoseconds, movePhase) }
        if let secondsIntoPlan {
            while let next = awaitingFirstFrame.first, secondsIntoPlan >= next.startSeconds {
                let wait = Int64(((secondsIntoPlan - next.startSeconds) * 1_000_000_000).rounded())
                firstFrameAfterMoveStartNanoseconds = max(firstFrameAfterMoveStartNanoseconds ?? wait, wait)
                awaitingFirstFrame.removeFirst()
            }
        }
        guard let previous else { return }
        let gap = atNanoseconds - previous.atNanoseconds
        longestGapNanoseconds = max(longestGapNanoseconds ?? gap, gap)
        if let movePhase, movePhase == previous.movePhase {
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

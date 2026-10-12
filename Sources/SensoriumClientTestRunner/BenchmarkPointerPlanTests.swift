import Foundation
import SensoriumClient

func testBenchmarkPointerPlanTests() {
    do {
        let plan = BenchmarkPointerPlan(parsing: "move:20,still:40,move:20")
        expect(plan?.phases.count == 3, "a three-phase spec parses into three phases")
        expect(plan?.totalSeconds == 80, "the phases add up to the plan's length")
        expect(plan?.specification == "move:20,still:40,move:20", "the spec reads back as it was given")
        print("PASS: a pointer plan parses its phases in order")
    }

    do {
        for bad in ["", "move", "move:", "move:0", "move:-3", "jump:5", "move:5,", ",move:5", "move:5;still:5", "move:abc", "move:nan", "move:inf"] {
            expect(BenchmarkPointerPlan(parsing: bad) == nil, "\"\(bad)\" is not a pointer plan")
        }
        expect(BenchmarkPointerPlan(parsing: "move:1.5")?.totalSeconds == 1.5, "a phase may last a fraction of a second")
        print("PASS: a malformed pointer plan is refused")
    }

    do {
        let plan = BenchmarkPointerPlan(parsing: "move:2,still:3,move:1")!
        expect(plan.phase(atSeconds: -0.1) == nil, "nothing runs before the plan starts")
        expect(plan.phase(atSeconds: 0) == .move, "the first phase starts at zero")
        expect(plan.phase(atSeconds: 1.99) == .move, "the first phase lasts its seconds")
        expect(plan.phase(atSeconds: 2) == .still, "the next phase starts where the last ended")
        expect(plan.phase(atSeconds: 4.99) == .still, "a still phase holds until it ends")
        expect(plan.phase(atSeconds: 5) == .move, "the last phase follows")
        expect(plan.phase(atSeconds: 6) == nil, "nothing runs after the plan ends")
        expect(plan.isMoving(atSeconds: 5.5) && !plan.isMoving(atSeconds: 3) && !plan.isMoving(atSeconds: 7), "moving is true only inside a move phase")
        print("PASS: the plan names the phase at each moment")
    }

    do {
        let width = 1920.0
        let height = 1200.0
        var previous: (x: Double, y: Double)?
        var largestStep = 0.0
        for tick in 0...(60 * 20) {
            let point = BenchmarkPointerPlan.pointerPosition(atSeconds: Double(tick) / 60, width: width, height: height)
            expect((0...width).contains(point.x) && (0...height).contains(point.y), "the pointer stays inside the canvas, got \(point)")
            if let previous {
                largestStep = max(largestStep, hypot(point.x - previous.x, point.y - previous.y))
            }
            previous = point
        }
        expect(largestStep > 0, "the pointer moves")
        expect(largestStep < 40, "one 60 Hz step is a small move, got \(largestStep) points")
        print("PASS: the pointer path is smooth and inside the canvas")
    }

    do {
        var tracker = PresentGapTracker()
        expect(tracker.longestGapNanoseconds == nil, "no gap is known before two frames")
        tracker.notePresented(atNanoseconds: 1_000, moving: false)
        expect(tracker.longestGapNanoseconds == nil, "one frame has no gap")
        tracker.notePresented(atNanoseconds: 1_500, moving: false)
        tracker.notePresented(atNanoseconds: 3_500, moving: false)
        tracker.notePresented(atNanoseconds: 3_800, moving: false)
        expect(tracker.longestGapNanoseconds == 2_000, "the longest gap is reported")
        expect(tracker.longestMovingGapNanoseconds == nil, "a gap with no motion is not a moving gap")
        tracker.notePresented(atNanoseconds: 4_000, moving: true)
        tracker.notePresented(atNanoseconds: 4_700, moving: true)
        tracker.notePresented(atNanoseconds: 4_900, moving: true)
        expect(tracker.longestMovingGapNanoseconds == 700, "the longest gap during motion is reported on its own")
        expect(tracker.longestGapNanoseconds == 2_000, "a shorter moving gap leaves the overall longest alone")
        tracker.notePresented(atNanoseconds: 9_900, moving: false)
        expect(tracker.longestMovingGapNanoseconds == 5_000, "a freeze that begins during motion counts as a moving gap")
        print("PASS: the gap tracker reports the longest freeze, overall and during motion")
    }

    do {
        let traces = BenchmarkReport.traceObjects(from: [
            #"{"stage":"decode","count":3,"p50Nanoseconds":10,"p95Nanoseconds":20}"#,
            #"{"stage":"present","count":2,"p50Nanoseconds":5,"p95Nanoseconds":6}"#,
            "not json"
        ])
        expect(traces.keys.sorted() == ["decode", "present"], "each trace line becomes an object under its stage")
        expect((traces["decode"] as? [String: Any])?["count"] as? Int == 3, "a trace keeps its fields")

        let line = BenchmarkReport.line(["b": 1, "a": ["z": true]])
        expect(line == #"bench-viewer {"a":{"z":true},"b":1}"#, "the report is one prefixed line of sorted-key JSON, got \(line)")
        expect(!line.contains("\n"), "the report is a single line")
        print("PASS: the benchmark report is one prefixed JSON line")
    }
}

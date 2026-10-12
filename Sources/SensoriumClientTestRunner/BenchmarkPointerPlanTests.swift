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
        var tracker = PresentGapTracker(plan: BenchmarkPointerPlan(parsing: "move:2,still:6,move:2"))
        expect(tracker.longestGapNanoseconds == nil, "no gap is known before two frames")
        tracker.notePresented(atNanoseconds: 1_000_000_000, secondsIntoPlan: 0)
        expect(tracker.longestGapNanoseconds == nil, "one frame has no gap")
        tracker.notePresented(atNanoseconds: 1_500_000_000, secondsIntoPlan: 0.5)
        expect(tracker.longestGapNanoseconds == 500_000_000, "the longest gap is reported")
        expect(tracker.longestMovingGapNanoseconds == 500_000_000, "a gap inside one move phase is a moving gap")
        tracker.notePresented(atNanoseconds: 1_900_000_000, secondsIntoPlan: 0.9)
        expect(tracker.longestMovingGapNanoseconds == 500_000_000, "a shorter moving gap leaves the longest alone")
        tracker.notePresented(atNanoseconds: 3_000_000_000, secondsIntoPlan: 2.0)
        expect(tracker.longestGapNanoseconds == 1_100_000_000, "a gap into the still phase is the longest overall")
        expect(tracker.longestMovingGapNanoseconds == 500_000_000, "a gap that ends in the still phase is not a moving gap")
        tracker.notePresented(atNanoseconds: 9_000_000_000, secondsIntoPlan: 8.0)
        expect(tracker.longestGapNanoseconds == 6_000_000_000, "the still phase's own gap is the longest overall")
        expect(tracker.longestMovingGapNanoseconds == 500_000_000, "a gap across a whole still phase is not a moving gap")
        expect(tracker.firstFrameAfterMoveStartNanoseconds == 0, "a frame at the start of motion resumed at once")
        tracker.notePresented(atNanoseconds: 9_200_000_000, secondsIntoPlan: 8.2)
        expect(tracker.longestMovingGapNanoseconds == 500_000_000, "a short gap in the second move phase changes nothing")
        print("PASS: the gap tracker reports freezes overall and only within a single move phase")
    }

    do {
        var tracker = PresentGapTracker(plan: BenchmarkPointerPlan(parsing: "move:2,still:6,move:2"))
        tracker.notePresented(atNanoseconds: 0, secondsIntoPlan: 0)
        tracker.notePresented(atNanoseconds: 1_900_000_000, secondsIntoPlan: 1.9)
        expect(tracker.firstFrameAfterMoveStartNanoseconds == nil, "a plan's first move phase follows no still phase")
        tracker.notePresented(atNanoseconds: 3_000_000_000, secondsIntoPlan: 3.0)
        expect(tracker.firstFrameAfterMoveStartNanoseconds == nil, "no move phase after a still phase has begun yet")
        tracker.notePresented(atNanoseconds: 8_700_000_000, secondsIntoPlan: 8.7)
        expect(tracker.firstFrameAfterMoveStartNanoseconds == 700_000_000, "the wait from the move phase's start to its first frame is reported")
        tracker.notePresented(atNanoseconds: 8_800_000_000, secondsIntoPlan: 8.8)
        expect(tracker.firstFrameAfterMoveStartNanoseconds == 700_000_000, "later frames of the phase do not change it")

        var noPlan = PresentGapTracker(plan: nil)
        noPlan.notePresented(atNanoseconds: 0, secondsIntoPlan: nil)
        noPlan.notePresented(atNanoseconds: 5, secondsIntoPlan: nil)
        expect(noPlan.longestGapNanoseconds == 5 && noPlan.longestMovingGapNanoseconds == nil && noPlan.firstFrameAfterMoveStartNanoseconds == nil, "without a plan only the overall gap is known")
        print("PASS: the tracker times the first frame after motion resumes")
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

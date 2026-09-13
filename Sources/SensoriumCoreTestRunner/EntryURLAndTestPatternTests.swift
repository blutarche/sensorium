import Foundation
import SensoriumCore

func testSensoriumEntryURLAcceptsOnlyCanonicalEnterURL() {
    guard let entry = SensoriumEntryURL(string: "sensorium://enter/mini.tailnet.example") else {
        print("FAIL: canonical Sensorium entry URL was rejected")
        Foundation.exit(1)
    }
    expect(entry.host == "mini.tailnet.example", "entry URL extracts the requested host")
    expect(entry.url.absoluteString == "sensorium://enter/mini.tailnet.example", "entry URL has one canonical representation")

    let rejected = [
        "https://enter/mini.tailnet.example",
        "sensorium://connect/mini.tailnet.example",
        "sensorium://enter/",
        "sensorium://enter/mini.tailnet.example/extra",
        "sensorium://enter/mini.tailnet.example?port=7777",
        "sensorium://enter/user@mini.tailnet.example",
        "sensorium://enter:7777/mini.tailnet.example"
    ]
    for malformed in rejected {
        expect(SensoriumEntryURL(string: malformed) == nil, "entry URL rejects \(malformed)")
    }
}

func testTestPatternPhaseBouncesInsideTheCanvasAndNeverLeavesIt() {
    let canvas = TestPatternPhase(
        canvasWidth: 1920,
        canvasHeight: 1200,
        blockWidth: 240,
        blockHeight: 240,
        speedPointsPerSecond: 600
    )

    let start = canvas.position(atSeconds: 0)
    expect(start.x == 0 && start.y == 0, "the pattern starts at the origin")

    // 600 pt/s for half a second is 300 points on each axis, still inbounds.
    let mid = canvas.position(atSeconds: 0.5)
    expect(mid.x == 300 && mid.y == 300, "the pattern moves linearly before its first bounce")

    // The x range is 1920-240 = 1680: at t=2.8s raw travel is 1680, exactly the
    // wall, and at t=3.0 the block is on its way back.
    expect(canvas.position(atSeconds: 2.8).x == 1680, "the block reaches the right wall exactly")
    expect(canvas.position(atSeconds: 3.0).x == 1560, "after the wall the block travels back")

    // Never outside the canvas, whatever the time — including long times where
    // naive modulo arithmetic would drift.
    for tick in 0..<2_000 {
        let position = canvas.position(atSeconds: Double(tick) * 0.137)
        expect(
            position.x >= 0 && position.x <= 1680 && position.y >= 0 && position.y <= 960,
            "the pattern stays inside the canvas at t=\(Double(tick) * 0.137)"
        )
    }

    // A degenerate canvas (block as big as the canvas) parks the block instead
    // of dividing by zero.
    let degenerate = TestPatternPhase(
        canvasWidth: 240,
        canvasHeight: 240,
        blockWidth: 240,
        blockHeight: 240,
        speedPointsPerSecond: 600
    )
    let parked = degenerate.position(atSeconds: 5)
    expect(parked.x == 0 && parked.y == 0, "a block with no room to move stays parked")
}


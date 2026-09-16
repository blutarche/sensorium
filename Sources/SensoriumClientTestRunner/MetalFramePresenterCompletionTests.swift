import AppKit
import Network
import SensoriumClient
import SensoriumCore
import CoreVideo
import Foundation
import MetalKit
import VideoToolbox

/// Regression + evidence for the "present" measurement fix: `present(_:)`
/// only ever scheduled a redraw and returned; nothing in this app measured
/// how long the GPU actually took to get a frame on screen. Real Metal
/// device and MTKView, offscreen -- no window, no display permission, no
/// live session -- driven directly rather than through AppKit's display
/// link, which this test does not have without a real window.
@MainActor
func testMetalFramePresenterMeasuresRealCompletionNotJustScheduling() async {
    guard MTLCreateSystemDefaultDevice() != nil else {
        // No GPU in this environment at all -- nothing to measure, and
        // nothing to fail: the rest of this file already treats "no Metal
        // device" as unavailable rather than broken (`MetalFramePresenterError.deviceUnavailable`).
        print("PASS: no Metal device available in this environment; completion-latency instrumentation not exercised")
        return
    }
    let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 40))
    guard let presenter = try? MetalFramePresenter(view: view) else {
        print("FAIL: could not construct MetalFramePresenter against a real Metal device")
        Foundation.exit(1)
    }

    expect(presenter.completionLatency.count == 0, "nothing presented yet, nothing measured yet")

    // Several cycles, not one: the first draw of a presenter pays for
    // building its render pipeline, which is not per-frame present latency.
    // Anyone re-running this with `cycles = 1` and seeing a large number has
    // rediscovered that cost, not a regression -- it is why this loop
    // exists. Presented and drawn sequentially, each waited out before
    // the next, so `draw(in:)` -- invoked directly, since there is no window
    // here for AppKit's real display link to drive it through -- always has
    // a fresh `latestFrame` to draw rather than racing itself.
    let cycles = 10
    for _ in 0..<cycles {
        presenter.present(DecodedFrame(pixelBuffer: makeTestPixelBuffer()))
        let before = presenter.completionLatency.count
        presenter.draw(in: view)
        for _ in 0..<50 where presenter.completionLatency.count == before {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    guard presenter.completionLatency.count == cycles,
          let p50 = presenter.completionLatency.p50,
          let p95 = presenter.completionLatency.p95 else {
        print(
            "FAIL: draw(in:) either produced no drawable in this offscreen environment (not a defect in"
                + " the fix itself) or a completion handler never fired for at least one cycle:"
                + " \(presenter.completionLatency.count) of \(cycles) cycles measured"
        )
        Foundation.exit(1)
    }
    expect(p50 >= 0 && p95 >= p50, "completion latency samples are never negative, and p95 never undercuts p50")
    // Not asserted against a ceiling: this measures this build machine's own
    // GPU, not the x86_64 laptop the user actually runs the viewer on, and
    // the whole point of this fix is that nothing has ever known this
    // number before -- there is no prior baseline here to compare against.
    // The first cycle's one-time pipeline build is still in this sample
    // set (p95, not excluded), same as it would be in a real session's
    // first frame; p50 is the steadier read of the ones after it.
    print(
        "PASS: MetalFramePresenter measures GPU-completion latency, not scheduling time:"
            + " p50 \(Double(p50) / 1_000_000)ms, p95 \(Double(p95) / 1_000_000)ms over \(cycles) cycles"
    )
}


/// Frames the host captured a frame apart must reach the screen a frame apart.
/// Two arriving off the network together used to land in one draw cycle, where
/// the newer overwrote the older and the refresh after it repeated a picture:
/// even capture turned into uneven motion. Real Metal device and MTKView,
/// offscreen, with `draw(in:)` driven by this test rather than by a display
/// link it has no window for.
@MainActor
func testMetalFramePresenterDrawsBurstedFramesOnSuccessiveRefreshes() async {
    guard MTLCreateSystemDefaultDevice() != nil else {
        print("PASS: no Metal device available in this environment; presentation pacing not exercised")
        return
    }
    let view = MTKView(frame: NSRect(x: 0, y: 0, width: 64, height: 40))
    guard let presenter = try? MetalFramePresenter(view: view) else {
        print("FAIL: could not construct MetalFramePresenter against a real Metal device")
        Foundation.exit(1)
    }
    let recorder = PresentedFrameRecorder()
    presenter.onFramePresented = { timing, presentedAtNanoseconds in
        recorder.record(capturedAt: timing.hostCapturedAtNanoseconds, presentedAt: presentedAtNanoseconds)
    }

    // One draw before anything arrives: a presenter with no frame draws
    // nothing and reports nothing.
    presenter.draw(in: view)
    expect(recorder.presented.isEmpty, "an empty presenter draws nothing")

    let hostCapture = MonotonicClock.nowNanoseconds()
    let frameInterval: Int64 = 16_666_667
    presenter.present(makePacedDecodedFrame(capturedAtNanoseconds: hostCapture))
    presenter.present(makePacedDecodedFrame(capturedAtNanoseconds: hostCapture + frameInterval))

    // Stands in for the display link: the screen asks for a picture on every
    // refresh whether or not one is due.
    let deadline = MonotonicClock.nowNanoseconds() + 2_000_000_000
    while recorder.presented.count < 2, MonotonicClock.nowNanoseconds() < deadline {
        presenter.draw(in: view)
        try? await Task.sleep(for: .milliseconds(2))
    }

    let presented = recorder.presented
    guard presented.count == 2 else {
        print(
            "FAIL: two frames captured a frame apart reached the screen as \(presented.count) presentations:"
                + " \(presented.map(\.capturedAt))"
        )
        Foundation.exit(1)
    }
    expect(
        presented[0].capturedAt == hostCapture && presented[1].capturedAt == hostCapture + frameInterval,
        "both are drawn, oldest first, got \(presented.map(\.capturedAt))"
    )
    let gap = presented[1].presentedAt - presented[0].presentedAt
    expect(
        gap >= 12_000_000,
        "and the second waits out the gap the host captured them with rather than following the first at once,"
            + " got \(Double(gap) / 1_000_000)ms"
    )

    // Nothing new is due, so the picture already on screen is left alone.
    let drawnSoFar = recorder.presented.count
    presenter.draw(in: view)
    presenter.draw(in: view)
    expect(
        recorder.presented.count == drawnSoFar,
        "a refresh with no new frame due redraws nothing, got \(recorder.presented.count - drawnSoFar) extra"
    )
    print("PASS: MetalFramePresenter paces bursted frames onto successive refreshes")
}

/// Collects what the presenter says it drew. A class, not a captured local:
/// the callback outlives the call that set it.
@MainActor
final class PresentedFrameRecorder {
    private(set) var presented: [(capturedAt: Int64, presentedAt: Int64)] = []

    func record(capturedAt: Int64, presentedAt: Int64) {
        presented.append((capturedAt: capturedAt, presentedAt: presentedAt))
    }
}

private func makePacedDecodedFrame(capturedAtNanoseconds: Int64) -> DecodedFrame {
    DecodedFrame(
        pixelBuffer: makeTestPixelBuffer(),
        timing: FrameTiming(
            hostCapturedAtNanoseconds: capturedAtNanoseconds,
            receivedAtNanoseconds: capturedAtNanoseconds,
            decodedAtNanoseconds: capturedAtNanoseconds
        )
    )
}

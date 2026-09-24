import Foundation
import SensoriumClient

/// Everything the Linux session window decides from what the compositor tells
/// it -- how big its buffer is, what the screen's refresh interval is, and
/// when the window has been closed -- lives in `WaylandSurfaceState`, which
/// holds no Wayland object and can therefore be driven here without a
/// compositor.
func testWaylandSurfaceStateTests() {
    var state = WaylandSurfaceState(defaultLogicalWidth: 1280, defaultLogicalHeight: 800)

    expect(state.logicalWidth == 1280 && state.logicalHeight == 800, "a surface starts at the size it asked for")
    expect(
        state.drawablePixelWidth == 1280 && state.drawablePixelHeight == 800,
        "at scale 1 the buffer is the logical size, got \(state.drawablePixelWidth)x\(state.drawablePixelHeight)"
    )
    expect(state.scale == 1, "a surface starts at scale 1 until the compositor says otherwise")
    expect(
        state.refreshIntervalNanoseconds == 16_666_667,
        "until an output reports its mode, the refresh interval is the 60Hz default, got \(state.refreshIntervalNanoseconds)"
    )
    expect(!state.isClosed, "a surface that was never closed is not closed")

    expect(state.configure(logicalWidth: 1000, logicalHeight: 600), "a configure naming a new size changes the surface")
    expect(
        state.drawablePixelWidth == 1000 && state.drawablePixelHeight == 600,
        "a configured surface draws at the size it was configured to, got \(state.drawablePixelWidth)x\(state.drawablePixelHeight)"
    )
    expect(
        !state.configure(logicalWidth: 1000, logicalHeight: 600),
        "a configure repeating the size already in force changes nothing"
    )

    // Zero means the compositor is leaving the choice to the client, not that
    // it wants a surface with no area.
    expect(!state.configure(logicalWidth: 0, logicalHeight: 0), "a configure of 0x0 leaves the client's own size in place")
    expect(
        state.logicalWidth == 1000 && state.logicalHeight == 600,
        "a configure of 0x0 keeps the last real size, got \(state.logicalWidth)x\(state.logicalHeight)"
    )

    expect(state.setFractionalScale(numerator120: 180), "a scale of 180/120 changes the surface")
    expect(state.scale == 1.5, "120ths are the unit fractional scale is sent in, got \(state.scale)")
    expect(
        state.drawablePixelWidth == 1500 && state.drawablePixelHeight == 900,
        "a scaled surface draws in real pixels, got \(state.drawablePixelWidth)x\(state.drawablePixelHeight)"
    )
    expect(!state.setFractionalScale(numerator120: 180), "a scale repeating the one already in force changes nothing")

    // The protocol rounds a toplevel's buffer size halfway away from zero.
    expect(state.configure(logicalWidth: 1001, logicalHeight: 601), "an odd size is still a new size")
    expect(
        state.drawablePixelWidth == 1502 && state.drawablePixelHeight == 902,
        "a buffer size lands on a whole pixel, rounded halfway away from zero, got \(state.drawablePixelWidth)x\(state.drawablePixelHeight)"
    )

    expect(state.setOutputRefresh(milliHertz: 60000), "an output reporting 60Hz is a change from the assumed default")
    expect(
        state.refreshIntervalNanoseconds == 16_666_667,
        "60000 mHz is one frame every 16666667ns, got \(state.refreshIntervalNanoseconds)"
    )
    expect(state.setOutputRefresh(milliHertz: 143856), "an output reporting 143.856Hz changes the interval")
    expect(
        state.refreshIntervalNanoseconds == 6_951_396,
        "143856 mHz is one frame every 6951396ns, got \(state.refreshIntervalNanoseconds)"
    )
    expect(!state.setOutputRefresh(milliHertz: 0), "an output that reports no refresh rate at all is ignored")
    expect(
        state.refreshIntervalNanoseconds == 6_951_396,
        "an ignored refresh report leaves the last real one standing, got \(state.refreshIntervalNanoseconds)"
    )

    expect(state.close(), "a close from the compositor changes the surface")
    expect(state.isClosed, "a surface the compositor closed is closed")
    expect(!state.close(), "a second close changes nothing")

    var overflowState = WaylandSurfaceState(defaultLogicalWidth: 1280, defaultLogicalHeight: 800)
    expect(
        !overflowState.setFractionalScale(numerator120: 300_000_000),
        "a scale far past any sane ceiling is rejected rather than adopted"
    )
    expect(overflowState.scale == 1, "a rejected scale leaves the previous scale in place, got \(overflowState.scale)")

    expect(
        overflowState.configure(logicalWidth: Int(Int32.max), logicalHeight: Int(Int32.max)),
        "a configure naming an enormous logical size still changes the surface"
    )
    expect(overflowState.setFractionalScale(numerator120: 16 * 120), "the largest sane scale is accepted")
    expect(
        overflowState.drawablePixelWidth == Int(Int32.max) && overflowState.drawablePixelHeight == Int(Int32.max),
        "a drawable size that would overflow Int32 is clamped to Int32.max, got " +
            "\(overflowState.drawablePixelWidth)x\(overflowState.drawablePixelHeight)"
    )

    print("PASS: WaylandSurfaceState derives buffer size, scale, refresh interval and closure from scripted compositor events")
}

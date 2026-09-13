import Foundation
import SensoriumCore

/// Round-trip coverage for `CaptureIntent.hostScreen` and
/// `SessionSurfaceGeometry`.
func testHostScreenTypes() {
    // SessionSurfaceGeometry round-trips
    let geometry = SessionSurfaceGeometry(logicalWidth: 3008, logicalHeight: 1692, backingScale: 1.5)
    let encoded = try! JSONEncoder().encode(geometry)
    let decoded = try! JSONDecoder().decode(SessionSurfaceGeometry.self, from: encoded)
    expect(decoded == geometry, "SessionSurfaceGeometry round-trips through JSON with every field intact")

    // Regression guard: the session canvas is unchanged
    // `SessionSurfaceGeometry.sessionCanvasDefault` restates
    // `VirtualCanvasConfiguration.remoteDefault` (Sources/SensoriumHost) in
    // this type's terms; Core cannot depend on Host to compare them
    // directly, so this compares against that type's own literals instead.
    expect(
        SessionSurfaceGeometry.sessionCanvasDefault
            == SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1200, backingScale: 2.0),
        "the session canvas's geometry in the new type is exactly VirtualCanvasConfiguration.remoteDefault's own numbers -- .hostScreen existing bought no change for canvas sessions"
    )
    expect(
        StreamScalePolicy.sessionCanvasRange == ScaleRange(minimum: 1.0, maximum: 2.0, quantum: 0.25),
        "the session canvas's scale range is (1.0, 2.0, 0.25)"
    )

    // CaptureIntent.hostScreen carries and distinguishes its token
    let tokenA = Data([0x01, 0x02])
    let tokenB = Data([0x03, 0x04])
    expect(
        CaptureIntent.hostScreen(token: tokenA) == CaptureIntent.hostScreen(token: tokenA),
        "the same token is the same capture intent"
    )
    expect(
        CaptureIntent.hostScreen(token: tokenA) != CaptureIntent.hostScreen(token: tokenB),
        "a different token is a different capture intent, not interchangeable with any other display's"
    )
    expect(
        CaptureIntent.hostScreen(token: tokenA) != CaptureIntent.sessionCanvas,
        "host screen is never mistaken for the session canvas"
    )
}

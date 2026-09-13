import SensoriumHost

/// The viewer draws its own local arrow over the canvas (see
/// `CanvasCursorVisibilityPolicy` in `SensoriumClient`) for both a session
/// canvas and a host screen, so a cursor ScreenCaptureKit bakes into either
/// stream would only draw a second, laggy cursor behind it.
func runCaptureCursorPolicyTests() async {
    expect(
        CaptureCursorPolicy.showsCursor(for: .sessionCanvas) == false,
        "session-canvas capture excludes the host's cursor so the viewer's local arrow is the only pointer drawn"
    )
    expect(
        CaptureCursorPolicy.showsCursor(for: .hostScreen) == false,
        "host-screen capture excludes the host's cursor so the viewer's local arrow is the only pointer drawn"
    )

    print("PASS: capture cursor visibility excludes the host's own cursor for every capture target, since the viewer always draws its own local arrow")
}

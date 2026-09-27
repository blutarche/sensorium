import Foundation
import SensoriumClient

/// A double for `GtkSessionControlsWindow`, which cannot be built in this
/// runner: it opens a real GTK4 window, and no compositor runs here. This
/// carries no widgets, only a count of its own calls, so the create-once,
/// reuse-after policy is checked without one.
@MainActor
private final class FakeSessionControlsWindow: SessionControlsWindowPresenting {
    private(set) var presentCount = 0
    private(set) var closeCount = 0

    func present(model: SessionControlsWindowModel) {
        presentCount += 1
    }

    func update(model: SessionControlsWindowModel) {}

    func close() {
        closeCount += 1
    }
}

/// `SessionControlsWindowOpening.openOrReuse` is what both
/// `openSessionControls()` and the strip's own gear button call: it must
/// build the window once, and every later request must present that same
/// window again rather than building a second one.
@MainActor
func testSessionControlsWindowOpeningTests() {
    let model = SessionControlsWindowModel()
    var buildCount = 0
    let window = FakeSessionControlsWindow()

    let first = SessionControlsWindowOpening.openOrReuse(existing: nil, model: model) {
        buildCount += 1
        return window
    }
    expect(buildCount == 1, "the first request builds the window")
    expect((first as? FakeSessionControlsWindow) === window, "the first request answers the window it just built")
    expect(window.presentCount == 1, "the first request presents the window it built")

    let second = SessionControlsWindowOpening.openOrReuse(existing: first, model: model) {
        buildCount += 1
        return FakeSessionControlsWindow()
    }
    expect(buildCount == 1, "a second request never builds a second window")
    expect((second as? FakeSessionControlsWindow) === window, "a second request answers the same window again")
    expect(window.presentCount == 2, "a second request presents the same window again rather than a new one")

    print("PASS: the session controls window is built once and presented again on every later request")
}

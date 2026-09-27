import Foundation

/// What a session controls window can be asked to do, independent of the
/// toolkit that draws it -- `GtkSessionControlsWindow` conforms, and a test
/// double can stand in for it where no compositor exists to build one.
@MainActor
public protocol SessionControlsWindowPresenting: AnyObject {
    func present(model: SessionControlsWindowModel)
    func update(model: SessionControlsWindowModel)
    func close()
}

/// Opens the session controls window on its first request and presents the
/// same one again on every later request, rather than a second window
/// stacking on top of the first. Both `openSessionControls()` and the
/// strip's own gear button ask for this, and neither may create a second
/// window while the first is still open.
public enum SessionControlsWindowOpening {
    @MainActor
    public static func openOrReuse(
        existing: (any SessionControlsWindowPresenting)?,
        model: SessionControlsWindowModel,
        makeNew: () -> (any SessionControlsWindowPresenting)?
    ) -> (any SessionControlsWindowPresenting)? {
        guard let window = existing ?? makeNew() else { return nil }
        window.present(model: model)
        return window
    }
}

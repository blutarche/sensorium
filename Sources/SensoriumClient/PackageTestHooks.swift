#if canImport(AppKit)
import AppKit

/// Entry points for `SensoriumClientTestRunner` into views this module keeps
/// internal on purpose -- `ViewerSessionStatusOverlay` is drawing detail,
/// never part of this library's own public API. Kept `package`, never
/// `public`: invisible past this package's own compiled products, unlike
/// `@testable import`, which disables testability in a release build and
/// breaks this repository's own release runners. Nothing here is called from
/// production code.
package enum ViewerClientTestHooks {
    /// The title of the button a real `ViewerSessionStatusOverlay` wants the
    /// keyboard on after being shown each status in order, or `nil` when it
    /// wants none, which is what leaves the canvas holding the keyboard --
    /// `ClientCanvasWindowController.apply(status:)` asks exactly this.
    @MainActor
    package static func statusOverlayFocusTitle(after statuses: [ViewerSessionStatus]) -> String? {
        let overlay = ViewerSessionStatusOverlay()
        for status in statuses {
            overlay.apply(status)
        }
        return (overlay.preferredFocus as? NSButton)?.title
    }
}
#endif

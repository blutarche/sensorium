import AppKit
import Foundation

/// Entry points for `SensoriumHostTestRunner` into views this module keeps
/// internal. `package`, not `public`: invisible outside this package's
/// products, and unlike `@testable import` it still works in a release
/// build. Never called from production code.
package enum CanvasHostTestHooks {
    /// A workspace placement for tests, bypassing
    /// `CanvasWorkspacePlacement.resolve(ownedHandle:display:physicalDisplayIDs:)`'s
    /// live-display checks -- the test runner has no real virtual display or
    /// WindowServer registration to validate against. Production code always
    /// goes through `resolve`; this is the only other way to build one.
    package static func placementForTesting(displayID: UInt32, bounds: CGRect) -> CanvasWorkspacePlacement {
        CanvasWorkspacePlacement(displayID: displayID, bounds: bounds)
    }

    /// Drives a launcher named `hostName` through its own empty-catalog
    /// path -- `testAdoptCatalog([])`, since the catalog itself reads this
    /// machine's own disk. Returns the real subtext label, laid out, plus
    /// the empty state's own width to check its inset against.
    @MainActor
    package static func launcherEmptyStateSubtext(
        frame: NSRect,
        canvas: CanvasWorkspacePlacement,
        hostName: String
    ) -> (subtext: NSTextField, emptyStateWidth: CGFloat) {
        let view = CanvasLauncherView(frame: frame, canvas: canvas)
        view.hostName = hostName
        view.testAdoptCatalog([])
        let (emptyState, subtext) = emptyStateSubtext(of: view)
        return (subtext, emptyState.bounds.width)
    }

    /// The two launcher sentences that name the host, from one view named
    /// `hostName`: the empty-catalog subtext, and the status a failed launch
    /// leaves behind.
    @MainActor
    package static func launcherHostNameTexts(
        frame: NSRect,
        canvas: CanvasWorkspacePlacement,
        hostName: String
    ) -> (emptyStateSubtext: String, launchFailedStatus: String) {
        let view = CanvasLauncherView(frame: frame, canvas: canvas)
        view.hostName = hostName
        view.testAdoptCatalog([])
        let subtext = emptyStateSubtext(of: view).subtext.stringValue
        view.testReport(CanvasLaunchReport(application: "Safari", outcome: .launchFailed(message: "test")))
        guard let statusLabel = Mirror(reflecting: view).children.first(where: { $0.label == "statusLabel" })?.value as? NSTextField else {
            fatalError("CanvasLauncherView no longer has a statusLabel field")
        }
        return (subtext, statusLabel.stringValue)
    }

    @MainActor
    private static func emptyStateSubtext(of view: CanvasLauncherView) -> (emptyState: NSView, subtext: NSTextField) {
        guard
            let emptyState = Mirror(reflecting: view).children.first(where: { $0.label == "emptyState" })?.value as? NSView,
            let subtext = Mirror(reflecting: emptyState).children.first(where: { $0.label == "subtext" })?.value as? NSTextField
        else {
            fatalError("CanvasLauncherView no longer has an emptyState field holding a subtext label")
        }
        return (emptyState, subtext)
    }

    /// The workspace's own keyboard hint, read off the same subview tree
    /// `Scripts/render-ui-previews.swift` walks: `WorkspaceContentView`'s
    /// first subview is the editor panel, whose first subview is the hint
    /// label.
    @MainActor
    package static func workspaceKeyboardHint(frame: NSRect, canvas: CanvasWorkspacePlacement) -> String {
        let view = WorkspaceContentView(frame: frame, canvas: canvas)
        guard let panel = view.subviews.first, let hint = panel.subviews.first as? NSTextField else {
            fatalError("expected WorkspaceContentView's first subview to be the editor panel, and its first subview to be the keyboard hint")
        }
        return hint.stringValue
    }

    /// Where the editor's own body text starts, versus where the keyboard
    /// hint above it starts -- both measured in the editor panel's own
    /// coordinate space, the panel being the common parent of the scroll
    /// view and the hint label. A one-edge panel needs these equal.
    @MainActor
    package static func workspaceEditorTextOriginX(
        frame: NSRect,
        canvas: CanvasWorkspacePlacement
    ) -> (textOriginX: CGFloat, hintMinX: CGFloat) {
        let view = WorkspaceContentView(frame: frame, canvas: canvas)
        guard
            let panel = view.subviews.first,
            let hint = panel.subviews.first as? NSTextField,
            let scrollView = view.editor.enclosingScrollView
        else {
            fatalError("expected WorkspaceContentView's editor panel to hold the hint label and the editor's scroll view")
        }
        let textOriginX = scrollView.frame.minX
            + view.editor.textContainerInset.width
            + (view.editor.textContainer?.lineFragmentPadding ?? 0)
        return (textOriginX, hint.frame.minX)
    }

    /// The launcher's own status row and the hint below it, laid out for a
    /// status applied directly through `testApplyStatus`, bypassing the
    /// relay's async hop.
    @MainActor
    package static func launcherStatusLayout(
        frame: NSRect,
        canvas: CanvasWorkspacePlacement,
        status: CanvasLauncherStatus
    ) -> (statusFrame: NSRect, hintFrame: NSRect, viewHeight: CGFloat) {
        let view = CanvasLauncherView(frame: frame, canvas: canvas)
        view.testApplyStatus(status)
        guard
            let statusLabel = Mirror(reflecting: view).children.first(where: { $0.label == "statusLabel" })?.value as? NSTextField,
            let hintLabel = Mirror(reflecting: view).children.first(where: { $0.label == "hintLabel" })?.value as? NSTextField
        else {
            fatalError("CanvasLauncherView no longer has statusLabel/hintLabel fields")
        }
        return (statusLabel.frame, hintLabel.frame, view.frame.height)
    }

    /// The query field's own placeholder text, read directly off the real
    /// `NSTextField` rather than duplicated as a second literal here.
    @MainActor
    package static func launcherQueryPlaceholder(frame: NSRect, canvas: CanvasWorkspacePlacement) -> String {
        let view = CanvasLauncherView(frame: frame, canvas: canvas)
        return view.queryField.placeholderAttributedString?.string ?? ""
    }

    /// The badge window behind a `HostScreenBadgeWindowController`, for
    /// measuring its laid-out size and reading the labels and button it
    /// holds -- the window is a private field, as nothing in production
    /// needs it beyond `show()` and `hide()`.
    @MainActor
    package static func hostScreenBadgeWindow(_ controller: HostScreenBadgeWindowController) -> NSWindow {
        guard let window = Mirror(reflecting: controller).children.first(where: { $0.label == "window" })?.value as? NSWindow else {
            fatalError("HostScreenBadgeWindowController no longer has a stored property named window")
        }
        return window
    }

    /// The presence prompt's eyebrow as drawn -- `CanvasDesign.eyebrow`
    /// upper-cases and letter-spaces it, so this is what the person reads,
    /// not the source literal.
    @MainActor
    package static func presencePromptEyebrowText(content: HostScreenBadgeContent) -> String {
        let controller = HostScreenPresencePromptWindowController(content: content)
        guard let eyebrow = Mirror(reflecting: controller).children.first(where: { $0.label == "eyebrow" })?.value as? NSTextField else {
            fatalError("HostScreenPresencePromptWindowController no longer has a stored property named eyebrow")
        }
        return eyebrow.attributedStringValue.string
    }

    /// The menu-bar pairing panel's own drawn texts, in `draw(_:)`'s own
    /// order -- `HostOperatorPanelView` draws directly into its layer
    /// rather than through `NSTextField`s, so there is no label to read a
    /// font back from without this.
    @MainActor
    package static func menuBarPanelTexts(_ presentation: HostOperatorPresentation) -> [NSAttributedString] {
        let view = HostOperatorPanelView()
        view.presentation = presentation
        return view.testLayoutTexts()
    }

    /// Fires the Host Setup window's pairing countdown tick synchronously --
    /// the same routine its own one-second `Timer` calls while a pairing
    /// code is showing, without a test waiting on a real `Timer`.
    @MainActor
    package static func fireHostSetupWindowPairingTick(_ controller: HostSetupWindowController) {
        controller.handlePairingCountdownTick()
    }

    /// Whether the Host Setup window's pairing countdown `Timer` is still
    /// running -- so a test can prove a tick that finds the code already
    /// expired stops the ticker, not only that it stops moving the label.
    @MainActor
    package static func isHostSetupWindowPairingTickerRunning(_ controller: HostSetupWindowController) -> Bool {
        controller.isPairingCountdownTickerRunning
    }
}

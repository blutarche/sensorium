#if canImport(AppKit)
import AppKit
import Foundation
import SensoriumCore

/// A canvas window, as the menu needs to see one: which window has focus, the
/// two local toggles and the resolution picker's own state.
///
/// Every toggle and every scale change is the window's own, not a second
/// implementation — a menu item that captured the pointer or set the stream
/// scale by any path other than `CanvasSurfaceView.togglePointerCapture()` or
/// `ClientCanvasWindowController.selectStreamScale(_:)` could leave the user
/// with a hidden cursor the escape gesture does not release, or a choice the
/// session HUD never learns about.
@MainActor
public protocol ViewerMenuCommandTarget: AnyObject {
    var viewerWindowState: ViewerWindowState { get }
    var isPointerCaptured: Bool { get }
    var streamScaleMenuState: DisplayScaleMenuState { get }
    /// docs/ux-spec.md's "Displays: 1 or 2" -- session-wide, not per-window,
    /// so every window in a session answers the same rows; see
    /// `ClientCanvasWindowController.updateDisplayCount(_:)`.
    var displayCountMenuState: DisplayCountMenuState { get }
    /// docs/ux-spec.md's "Screen: Virtual display (default) or Host screen"
    /// -- session-wide, like `displayCountMenuState`. Defaulted below to
    /// "Virtual display only, nothing else offered" so a target that
    /// predates this control keeps compiling and shows the one row every
    /// session already has.
    var screenMenuState: ScreenMenuState { get }
    func toggleTelemetryOverlay()
    func togglePointerCapture()
    /// docs/ux-spec.md's "Clipboard: on or off" -- whether this window's own
    /// checkmark reads on. Owned the same way `displayCountMenuState` is:
    /// session-wide truth cached here only so the menu, built lazily on
    /// `menuNeedsUpdate`, can answer synchronously.
    var isClipboardSharingEnabled: Bool { get }
    /// The Clipboard item's own action -- see `ClipboardSharingToggle`.
    func toggleClipboardSharing()
    func selectStreamScale(_ preference: StreamScalePreference)
    /// The Displays menu's own action. What sending the choice and reacting
    /// to the host's reply mean is owned by whoever built this session
    /// (`ClientSessionHost`, not this window) --
    /// see that type's `selectDisplayCount(_:)`.
    func selectDisplayCount(_ count: Int)
    /// The Screen menu's own action -- `nil` selects Virtual display, a
    /// non-nil value names one row of `screenMenuState` by its
    /// `HostScreenListEntry.opaqueToken`. Owned the same way
    /// `selectDisplayCount(_:)` is; see
    /// `ClientSessionHost.selectRealScreen(token:)`, which reconnects at the
    /// new target rather than switching a live session mid-flight.
    /// Defaulted below to a no-op for the same reason `screenMenuState` is.
    func selectRealScreen(token: Data?)
    /// The Screen menu's Resolution submenu: asks the host to set the screen
    /// it is streaming to one of the modes it offered. Owned the same way
    /// `selectRealScreen(token:)` is, and defaulted below for the same
    /// reason -- a live connection this window does not hold is what sends
    /// it.
    func selectHostScreenMode(modeID: String)
    /// The Screen menu's "Start with" submenu: which target this machine
    /// should try first next time it is entered from *Your machines*. Owned
    /// the same way `selectRealScreen(token:)` is -- writing the choice back
    /// to the saved-machines store needs `ClientSessionHost`,
    /// not this window -- and defaulted below for the
    /// same reason.
    func selectStartTarget(_ target: StartTarget)
}

public extension ViewerMenuCommandTarget {
    var screenMenuState: ScreenMenuState {
        ScreenMenuState(items: ScreenMenuPlan.items(displays: [], selectedToken: nil))
    }

    func selectRealScreen(token: Data?) {}

    func selectHostScreenMode(modeID: String) {}

    func selectStartTarget(_ target: StartTarget) {}
}

/// Builds `ViewerMenuPlan` into a real menu bar and points each item at
/// something that already exists.
///
/// Deliberately thin: what the menu contains, which chord each item claims, and
/// which chords it must leave alone are all decided by the plan, which the
/// runners verify without a menu bar. The two items that depend on which
/// window has focus — captured-pointer mode's title and the Display menu's
/// whole content — are rebuilt from `ViewerMenuCommandTarget` on
/// `menuNeedsUpdate`, AppKit's own lazy-refresh hook, rather than pushed here
/// on every state change.
@MainActor
public final class ViewerMainMenuController: NSObject, NSMenuDelegate {
    /// The one quit path. Reused rather than reimplemented, so Quit ends the
    /// session and releases the host's canvas exactly as an interrupt does.
    private let onQuit: () -> Void
    /// The one path to the launch window, reused rather than reimplemented:
    /// this item brings the same window a session's own "Your machines" button
    /// returns to.
    private let onShowYourMachines: () -> Void
    private var targets: [any ViewerMenuCommandTarget] = []
    /// The single item `menuNeedsUpdate` retitles; found once at build time
    /// rather than re-searched on every open.
    private var pointerCaptureItem: NSMenuItem?
    /// The single item `menuNeedsUpdate` checks on, found once the same way
    /// `pointerCaptureItem` is.
    private var clipboardSharingItem: NSMenuItem?
    /// The single item `menuNeedsUpdate` retitles and enables/disables to
    /// match the key window's actual full-screen state, found once the same
    /// way `pointerCaptureItem` is. Explicit rather than automatic: the View
    /// menu keeps `autoenablesItems = false`, like every menu but Edit.
    private var fullScreenItem: NSMenuItem?
    /// The three items `menuNeedsUpdate` enables or disables to match
    /// whichever window it reads its traits from -- found once at build
    /// time, the same way `fullScreenItem` is.
    private var minimizeItem: NSMenuItem?
    private var zoomItem: NSMenuItem?
    private var bringAllToFrontItem: NSMenuItem?
    /// Found once at build time, the same way `displayMenu` below is --
    /// `menuNeedsUpdate` matches on it to refresh the three items above.
    private var windowMenu: NSMenu?
    /// The window `menuNeedsUpdate` reads Minimize and Zoom's traits from.
    /// A test cannot make a real window key or main without a full run loop
    /// and an active app, so this is overridable; every real caller leaves
    /// the default, which is the actual key window, or the main window if
    /// none is key.
    public var windowMenuTargetWindow: () -> NSWindow? = {
        NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
    }
    private var displayMenu: NSMenu?
    private var displayCountMenu: NSMenu?
    private var screenMenu: NSMenu?

    public init(onQuit: @escaping () -> Void, onShowYourMachines: @escaping () -> Void) {
        self.onQuit = onQuit
        self.onShowYourMachines = onShowYourMachines
        super.init()
    }

    /// The windows a toggle can act on, each held for exactly the life of
    /// the session that registered it -- removed by `unregister(_:)` when
    /// that session's windows close, so a switch to a different session (a
    /// successful pair-again included) does not leave this one still
    /// retained and still receiving menu actions.
    public func register(_ target: any ViewerMenuCommandTarget) {
        guard !targets.contains(where: { $0 === target }) else { return }
        targets.append(target)
    }

    /// The other half of `register(_:)` -- called once per registered
    /// target when its session's windows close.
    public func unregister(_ target: any ViewerMenuCommandTarget) {
        targets.removeAll { $0 === target }
    }

    public func install(into application: NSApplication) {
        let bar = NSMenu()
        for menu in ViewerMenuPlan.bar(.initial) {
            let holder = NSMenuItem()
            let built = submenu(for: menu)
            holder.submenu = built
            bar.addItem(holder)
            switch menu.title {
            case "View":
                pointerCaptureItem = built.items.first { $0.action == #selector(togglePointerCapture(_:)) }
                clipboardSharingItem = built.items.first { $0.action == #selector(toggleClipboardSharing(_:)) }
                fullScreenItem = built.items.first { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }
                built.delegate = self
            // Rebuilt whole on every open from the focused window's state.
            case "Displays":
                displayCountMenu = built
                built.delegate = self
            case "Resolution":
                displayMenu = built
                built.delegate = self
            case "Screen":
                screenMenu = built
                built.delegate = self
            case "Window":
                windowMenu = built
                minimizeItem = built.items.first { $0.action == #selector(minimizeKeyWindow(_:)) }
                zoomItem = built.items.first { $0.action == #selector(NSWindow.performZoom(_:)) }
                bringAllToFrontItem = built.items.first { $0.action == #selector(NSApplication.arrangeInFront(_:)) }
                built.delegate = self
            case "Help":
                application.helpMenu = built
            default:
                break
            }
        }
        application.mainMenu = bar
        if let windowMenu {
            // macOS appends the live window list below these, and keeps it
            // current with no further code here.
            application.windowsMenu = windowMenu
        }
    }

    private func submenu(for menu: ViewerMenu) -> NSMenu {
        let result = NSMenu(title: menu.title)
        // Enablement is the plan's decision, not AppKit's, for every menu but
        // Edit: the escape-gesture line is a stated fact and stays disabled,
        // and everything else is always available -- see
        // `ViewerMenu.autoenablesItems`.
        result.autoenablesItems = menu.autoenablesItems
        fill(result, from: menu)
        return result
    }

    private func fill(_ result: NSMenu, from menu: ViewerMenu) {
        result.removeAllItems()
        for item in menu.items {
            result.addItem(menuItem(for: item))
        }
    }

    private func menuItem(for item: ViewerMenuItem) -> NSMenuItem {
        guard item.command != .separator else { return .separator() }
        let result = NSMenuItem(
            title: item.title,
            action: action(for: item.command),
            keyEquivalent: item.keyEquivalent
        )
        result.keyEquivalentModifierMask = Self.modifierMask(item.modifiers)
        result.isEnabled = item.isEnabled
        result.state = item.isSelected ? .on : .off
        result.target = target(for: item.command)
        result.representedObject = representedObject(for: item.command)
        if let submenu = item.submenu {
            result.submenu = self.submenu(for: submenu)
        }
        return result
    }

    /// What a row's action reads back to know which choice it is: `NSNull`
    /// stands in for Automatic, since `nil` cannot sit in that slot.
    private func representedObject(for command: ViewerMenuCommand) -> Any? {
        switch command {
        case let .setStreamScale(scale): scale.map { NSNumber(value: $0) } ?? NSNull()
        case let .selectDisplayCount(count): NSNumber(value: count)
        case let .selectRealScreen(token): token
        case let .selectHostScreenMode(modeID): modeID
        case let .selectStartTarget(target): target
        default: nil
        }
    }

    private func action(for command: ViewerMenuCommand) -> Selector? {
        switch command {
        case .about: #selector(showAbout(_:))
        case .hide: #selector(NSApplication.hide(_:))
        case .hideOthers: #selector(NSApplication.hideOtherApplications(_:))
        case .showAll: #selector(NSApplication.unhideAllApplications(_:))
        case .quit: #selector(quitSession(_:))
        case .showYourMachines: #selector(showYourMachines(_:))
        // Nil-target standard editing selectors, resolved by the responder
        // chain -- AppKit implements none of these on `NSResponder` itself,
        // which is exactly what leaves them disabled while a session canvas,
        // which implements none of them either, is key.
        case .undo: NSSelectorFromString("undo:")
        case .redo: NSSelectorFromString("redo:")
        case .cut: NSSelectorFromString("cut:")
        case .copy: NSSelectorFromString("copy:")
        case .paste: NSSelectorFromString("paste:")
        case .selectAll: NSSelectorFromString("selectAll:")
        // Left to the responder chain so each lands on whichever window is
        // key, which is also what makes it a no-op when none is.
        case .toggleFullScreen: #selector(NSWindow.toggleFullScreen(_:))
        // See `minimizeKeyWindow` for why this isn't `performMiniaturize:` itself.
        case .minimize: #selector(minimizeKeyWindow(_:))
        case .zoom: #selector(NSWindow.performZoom(_:))
        case .bringAllToFront: #selector(NSApplication.arrangeInFront(_:))
        case .toggleTelemetryOverlay: #selector(toggleTelemetryOverlay(_:))
        case .togglePointerCapture: #selector(togglePointerCapture(_:))
        case .toggleClipboardSharing: #selector(toggleClipboardSharing(_:))
        case .setStreamScale: #selector(selectStreamScale(_:))
        case .selectDisplayCount: #selector(selectDisplayCount(_:))
        case .selectRealScreen: #selector(selectRealScreen(_:))
        case .selectHostScreenMode: #selector(selectHostScreenMode(_:))
        case .selectStartTarget: #selector(selectStartTarget(_:))
        case .streamScaleClampNotice, .escapeGestureHint, .separator, .submenu: nil
        }
    }

    private func target(for command: ViewerMenuCommand) -> AnyObject? {
        switch command {
        case .hide, .hideOthers, .showAll, .bringAllToFront: NSApplication.shared
        case .about, .quit, .showYourMachines, .toggleTelemetryOverlay, .togglePointerCapture,
             .toggleClipboardSharing, .minimize, .setStreamScale, .selectDisplayCount, .selectRealScreen,
             .selectHostScreenMode, .selectStartTarget: self
        // Nil: found by the responder chain, starting at the key window's
        // first responder -- the pairing form's own text fields for the six
        // editing commands, whichever window is key for full screen and zoom.
        case .undo, .redo, .cut, .copy, .paste, .selectAll,
             .toggleFullScreen, .zoom,
             .streamScaleClampNotice, .escapeGestureHint, .separator, .submenu: nil
        }
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApplication.shared.orderFrontStandardAboutPanel(options: SensoriumCredit.standardAboutPanelOptions)
    }

    @objc private func quitSession(_ sender: Any?) {
        onQuit()
    }

    @objc private func showYourMachines(_ sender: Any?) {
        onShowYourMachines()
    }

    @objc private func toggleTelemetryOverlay(_ sender: Any?) {
        focusedTarget?.toggleTelemetryOverlay()
    }

    /// Only ever the focused window, which is the same window the
    /// resign-focus path is guaranteed to release the pointer for.
    @objc private func togglePointerCapture(_ sender: Any?) {
        focusedTarget?.togglePointerCapture()
    }

    @objc private func toggleClipboardSharing(_ sender: Any?) {
        focusedTarget?.toggleClipboardSharing()
    }

    /// Minimizes the key window, exactly as `NSWindow.performMiniaturize(_:)`
    /// itself would -- routed through this selector of its own, not that one
    /// directly, so the item's action is never the literal `performMiniaturize:`
    /// AppKit reformats to Cmd-M once its menu becomes `NSApp.windowsMenu`.
    @objc private func minimizeKeyWindow(_ sender: Any?) {
        NSApplication.shared.keyWindow?.performMiniaturize(sender)
    }

    /// The scale a Display menu row selects rides along as `representedObject`
    /// -- `NSNull` for Automatic, since a `nil` cannot sit in that slot itself.
    @objc private func selectStreamScale(_ sender: NSMenuItem) {
        let preference: StreamScalePreference = (sender.representedObject as? NSNumber)
            .map { .fixed($0.doubleValue) } ?? .automatic
        focusedTarget?.selectStreamScale(preference)
    }

    /// The count a Displays menu row selects, the same `representedObject`
    /// convention `selectStreamScale` already uses -- here there is no
    /// "Automatic" case needing `NSNull`, but the pattern is kept identical
    /// rather than a second, divergent one for a menu one row longer.
    @objc private func selectDisplayCount(_ sender: NSMenuItem) {
        guard let count = (sender.representedObject as? NSNumber)?.intValue else { return }
        focusedTarget?.selectDisplayCount(count)
    }

    /// The token a Screen menu row selects, riding `representedObject`
    /// directly as `Data` -- unlike `selectStreamScale`/`selectDisplayCount`,
    /// `nil` (Virtual display) needs no `NSNull` stand-in, since
    /// `representedObject` is already `Any?` and a genuinely absent value
    /// reads back as `nil` on its own.
    @objc private func selectRealScreen(_ sender: NSMenuItem) {
        let token = sender.representedObject as? Data
        focusedTarget?.selectRealScreen(token: token)
    }

    /// The mode a Resolution row selects, riding `representedObject` as the
    /// host's own identifier for it -- the same convention every other row
    /// in these menus already uses, and the only thing a pick ever sends.
    @objc private func selectHostScreenMode(_ sender: NSMenuItem) {
        guard let modeID = sender.representedObject as? String else { return }
        focusedTarget?.selectHostScreenMode(modeID: modeID)
    }

    /// The preference a "Start with" row selects, riding `representedObject`
    /// as the `StartTarget` value itself rather than a token this menu
    /// would have to look back up -- unlike a Screen row's `opaqueToken`,
    /// nothing here is minted per connection, so there is nothing this value
    /// could go stale against.
    @objc private func selectStartTarget(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? StartTarget else { return }
        focusedTarget?.selectStartTarget(target)
    }

    /// AppKit's own lazy-refresh hook: called just before any of the View,
    /// Displays, or Resolution submenus is shown, so the state none of them
    /// can know at build time -- which window has focus, what it is doing
    /// right now -- is always current the moment the user actually looks.
    public func menuNeedsUpdate(_ menu: NSMenu) {
        let model = ViewerMenuPlan.bar(currentState(readingWindowMenu: menu === windowMenu))
        func items(_ title: String) -> [ViewerMenuItem] {
            model.first { $0.title == title }?.items ?? []
        }
        func refresh(_ item: NSMenuItem?, from row: ViewerMenuItem?) {
            guard let item, let row else { return }
            item.title = row.title
            item.isEnabled = row.isEnabled
            item.state = row.isSelected ? .on : .off
        }
        let view = items("View")
        // All three live in the View menu, so each refreshes whenever it
        // opens. AppKit calls `menuNeedsUpdate` before matching a key
        // equivalent as well as before showing a menu (this delegate
        // implements no `menuHasKeyEquivalent(_:for:target:action:)` to skip
        // that), so Ctrl-Cmd-F reads a title and an enabled state that are
        // already current.
        if let pointerCaptureItem, menu.items.contains(where: { $0 === pointerCaptureItem }) {
            refresh(pointerCaptureItem, from: view.first { $0.command == .togglePointerCapture })
        }
        if let clipboardSharingItem, menu.items.contains(where: { $0 === clipboardSharingItem }) {
            refresh(clipboardSharingItem, from: view.first { $0.command == .toggleClipboardSharing })
        }
        if let fullScreenItem, menu.items.contains(where: { $0 === fullScreenItem }) {
            refresh(fullScreenItem, from: view.first { $0.command == .toggleFullScreen })
        }
        // AppKit calls `menuNeedsUpdate` on `NSApp.windowsMenu` too, before
        // showing it and before matching Cmd-M or Cmd-` against the window
        // list it appends below these three items.
        if menu === windowMenu {
            let window = items("Window")
            refresh(minimizeItem, from: window.first { $0.command == .minimize })
            refresh(zoomItem, from: window.first { $0.command == .zoom })
            refresh(bringAllToFrontItem, from: window.first { $0.command == .bringAllToFront })
        }
        for (built, title) in [(displayMenu, "Resolution"), (displayCountMenu, "Displays"), (screenMenu, "Screen")]
        where menu === built {
            if let source = model.first(where: { $0.title == title }) {
                fill(menu, from: source)
            }
        }
    }

    /// The focused window's state, or the defaults when none has focus. No
    /// registered target at all -- the launch window, say, is key instead --
    /// means no window this menu knows about can go full screen: it is not
    /// resizable, and never offers the item.
    private func currentState(readingWindowMenu: Bool) -> ViewerMenuBarState {
        let focused = focusedTarget
        var state = ViewerMenuBarState(
            streamScale: focused?.streamScaleMenuState ?? ViewerMenuBarState.initial.streamScale,
            displayCount: focused?.displayCountMenuState ?? ViewerMenuBarState.initial.displayCount,
            screen: focused?.screenMenuState ?? ViewerMenuBarState.initial.screen,
            isPointerCaptured: focused?.isPointerCaptured ?? false,
            isClipboardSharingEnabled: focused?.isClipboardSharingEnabled ?? ClipboardSyncEngine.sharingEnabledByDefault,
            isFullscreen: focused?.viewerWindowState.isFullscreen ?? false,
            canFullScreen: focused != nil
        )
        if readingWindowMenu {
            let target = windowMenuTargetWindow()
            let window = ViewerMenuPlan.windowMenuState(
                canMiniaturize: target?.styleMask.contains(.miniaturizable) ?? false,
                isMiniaturized: target?.isMiniaturized ?? false,
                canZoom: target?.styleMask.contains(.resizable) ?? false,
                hasVisibleWindow: NSApplication.shared.windows.contains { $0.isVisible }
            )
            state.minimizeEnabled = window.minimizeEnabled
            state.zoomEnabled = window.zoomEnabled
            state.bringAllToFrontEnabled = window.bringAllToFrontEnabled
        }
        return state
    }

    private var focusedTarget: (any ViewerMenuCommandTarget)? {
        targets.first { $0.viewerWindowState.hasKeyFocus }
    }

    private static func modifierMask(_ modifiers: ViewerMenuModifiers) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.control) { mask.insert(.control) }
        return mask
    }
}
#endif

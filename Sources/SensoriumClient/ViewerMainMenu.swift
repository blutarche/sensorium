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
    private var displayMenu: NSMenu?
    private var displayCountMenu: NSMenu?
    private var screenMenu: NSMenu?

    /// What the Resolution menu offers before any window has ever had focus —
    /// the same canvas geometry every session streams, with no cap chosen and
    /// nothing to explain.
    private static let defaultStreamScaleMenuState = DisplayScaleMenuState(
        items: DisplayScaleMenuPlan.items(
            selectedPreference: .automatic,
            canvasLogicalWidth: Double(SavedHost.remoteCanvasPreset.logicalWidth),
            canvasLogicalHeight: Double(SavedHost.remoteCanvasPreset.logicalHeight)
        ),
        clampNotice: nil
    )

    /// What the Displays menu offers before any window has ever had focus --
    /// a session always starts at one display, per docs/ux-spec.md, until the
    /// person chooses otherwise.
    private static let defaultDisplayCountMenuState = DisplayCountMenuState(
        items: DisplayCountMenuPlan.items(selectedCount: 1)
    )

    /// What the Screen menu offers before any window has ever had focus --
    /// Virtual display, the only row every session starts with, before any
    /// `hostScreenList` offer (if this machine is armed for host screen) has
    /// arrived.
    private static let defaultScreenMenuState = ScreenMenuState(
        items: ScreenMenuPlan.items(displays: [], selectedToken: nil)
    )

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
        for menu in ViewerMenuPlan.menus {
            let holder = NSMenuItem()
            let built = submenu(for: menu)
            holder.submenu = built
            bar.addItem(holder)
            if menu.title == "View" {
                pointerCaptureItem = built.items.first { $0.action == #selector(togglePointerCapture(_:)) }
                clipboardSharingItem = built.items.first { $0.action == #selector(toggleClipboardSharing(_:)) }
                built.delegate = self
            }
        }
        bar.addItem(displayCountMenuHolder())
        bar.addItem(displayMenuHolder())
        bar.addItem(screenMenuHolder())
        application.mainMenu = bar
    }

    private func displayMenuHolder() -> NSMenuItem {
        let holder = NSMenuItem()
        let menu = NSMenu(title: "Resolution")
        menu.autoenablesItems = false
        menu.delegate = self
        rebuild(menu, from: Self.defaultStreamScaleMenuState)
        holder.submenu = menu
        displayMenu = menu
        return holder
    }

    /// docs/ux-spec.md's "Displays: 1 or 2" -- a separate menu from
    /// Resolution's per-display scale picker, since the two are separate
    /// controls in the spec's own words.
    private func displayCountMenuHolder() -> NSMenuItem {
        let holder = NSMenuItem()
        let menu = NSMenu(title: "Displays")
        menu.autoenablesItems = false
        menu.delegate = self
        rebuild(menu, from: Self.defaultDisplayCountMenuState)
        holder.submenu = menu
        displayCountMenu = menu
        return holder
    }

    /// docs/ux-spec.md's "Screen" control -- a separate menu from Displays
    /// and Resolution, the same reasoning `displayCountMenuHolder()` above
    /// already follows for its own separate control.
    private func screenMenuHolder() -> NSMenuItem {
        let holder = NSMenuItem()
        let menu = NSMenu(title: "Screen")
        menu.autoenablesItems = false
        menu.delegate = self
        rebuild(menu, from: Self.defaultScreenMenuState)
        holder.submenu = menu
        screenMenu = menu
        return holder
    }

    private func submenu(for menu: ViewerMenu) -> NSMenu {
        let result = NSMenu(title: menu.title)
        // Enablement is the plan's decision, not AppKit's: the escape-gesture
        // line is a stated fact and stays disabled, and everything else is
        // always available.
        result.autoenablesItems = false
        for item in menu.items {
            result.addItem(menuItem(for: item))
        }
        return result
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
        result.target = target(for: item.command)
        return result
    }

    private func action(for command: ViewerMenuCommand) -> Selector? {
        switch command {
        case .about: #selector(showAbout(_:))
        case .hide: #selector(NSApplication.hide(_:))
        case .hideOthers: #selector(NSApplication.hideOtherApplications(_:))
        case .quit: #selector(quitSession(_:))
        case .showYourMachines: #selector(showYourMachines(_:))
        // Left to the responder chain so it lands on whichever window is key,
        // which is also what makes it a no-op when none is.
        case .toggleFullScreen: #selector(NSWindow.toggleFullScreen(_:))
        case .toggleTelemetryOverlay: #selector(toggleTelemetryOverlay(_:))
        case .togglePointerCapture: #selector(togglePointerCapture(_:))
        case .toggleClipboardSharing: #selector(toggleClipboardSharing(_:))
        case .setStreamScale, .streamScaleClampNotice, .escapeGestureHint, .separator: nil
        }
    }

    private func target(for command: ViewerMenuCommand) -> AnyObject? {
        switch command {
        case .hide, .hideOthers: NSApplication.shared
        case .about, .quit, .showYourMachines, .toggleTelemetryOverlay, .togglePointerCapture, .toggleClipboardSharing: self
        case .toggleFullScreen, .setStreamScale, .streamScaleClampNotice, .escapeGestureHint, .separator: nil
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
        if let pointerCaptureItem, menu.items.contains(where: { $0 === pointerCaptureItem }) {
            let isCaptured = focusedTarget?.isPointerCaptured ?? false
            pointerCaptureItem.title = ViewerMenuPlan.pointerCaptureTitle(isCaptured: isCaptured)
            pointerCaptureItem.state = isCaptured ? .on : .off
        }
        // Both items above live in the same View menu, so this is not part
        // of the `else if` chain below -- the pointer-capture item and the
        // Clipboard item must both refresh when that one menu opens, not
        // whichever the chain reaches first.
        if let clipboardSharingItem, menu.items.contains(where: { $0 === clipboardSharingItem }) {
            let isEnabled = focusedTarget?.isClipboardSharingEnabled ?? ClipboardSyncEngine.sharingEnabledByDefault
            clipboardSharingItem.state = isEnabled ? .on : .off
        }
        if menu === displayMenu {
            rebuild(menu, from: focusedTarget?.streamScaleMenuState ?? Self.defaultStreamScaleMenuState)
        } else if menu === displayCountMenu {
            rebuild(menu, from: focusedTarget?.displayCountMenuState ?? Self.defaultDisplayCountMenuState)
        } else if menu === screenMenu {
            rebuild(menu, from: focusedTarget?.screenMenuState ?? Self.defaultScreenMenuState)
        }
    }

    private func rebuild(_ menu: NSMenu, from state: DisplayScaleMenuState) {
        menu.removeAllItems()
        for row in state.items {
            let item = NSMenuItem(title: row.title, action: #selector(selectStreamScale(_:)), keyEquivalent: "")
            item.target = self
            item.state = row.isSelected ? .on : .off
            item.representedObject = row.scale.map { NSNumber(value: $0) } ?? NSNull()
            menu.addItem(item)
        }
        if let clampNotice = state.clampNotice {
            menu.addItem(.separator())
            let notice = NSMenuItem(title: clampNotice, action: nil, keyEquivalent: "")
            notice.isEnabled = false
            menu.addItem(notice)
        }
    }

    private func rebuild(_ menu: NSMenu, from state: DisplayCountMenuState) {
        menu.removeAllItems()
        for row in state.items {
            let item = NSMenuItem(title: row.title, action: #selector(selectDisplayCount(_:)), keyEquivalent: "")
            item.target = self
            item.state = row.isSelected ? .on : .off
            item.isEnabled = row.isEnabled
            item.representedObject = NSNumber(value: row.count)
            menu.addItem(item)
        }
    }

    private func rebuild(_ menu: NSMenu, from state: ScreenMenuState) {
        menu.removeAllItems()
        for row in state.items {
            let item = NSMenuItem(title: row.title, action: #selector(selectRealScreen(_:)), keyEquivalent: "")
            item.target = self
            item.state = row.isSelected ? .on : .off
            item.representedObject = row.token
            menu.addItem(item)
        }
        // The host screen's own resolution, under the screen it belongs to.
        // Always present, so its absence never has to be explained: outside
        // a live host-screen session it is simply not pickable.
        menu.addItem(.separator())
        let holder = NSMenuItem(title: state.modes.title, action: nil, keyEquivalent: "")
        holder.isEnabled = state.modes.isEnabled
        let submenu = NSMenu(title: state.modes.title)
        submenu.autoenablesItems = false
        for row in state.modes.items {
            let item = NSMenuItem(title: row.title, action: #selector(selectHostScreenMode(_:)), keyEquivalent: "")
            item.target = self
            item.state = row.isSelected ? .on : .off
            item.isEnabled = state.modes.isEnabled
            item.representedObject = row.modeID
            submenu.addItem(item)
        }
        holder.submenu = submenu
        menu.addItem(holder)
        // The saved preference for this machine's *next* launch -- a
        // separate submenu from Resolution's live, this-session-only mode
        // picker just above, so the two are never mistaken for one control.
        let startWithHolder = NSMenuItem(title: state.startWith.title, action: nil, keyEquivalent: "")
        let startWithSubmenu = NSMenu(title: state.startWith.title)
        startWithSubmenu.autoenablesItems = false
        for row in state.startWith.items {
            let item = NSMenuItem(title: row.title, action: #selector(selectStartTarget(_:)), keyEquivalent: "")
            item.target = self
            item.state = row.isSelected ? .on : .off
            item.isEnabled = row.isEnabled
            item.representedObject = row.target
            startWithSubmenu.addItem(item)
        }
        startWithHolder.submenu = startWithSubmenu
        menu.addItem(startWithHolder)
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

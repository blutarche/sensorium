import Foundation
import SensoriumCore

/// The viewer's menu bar as the Linux viewer draws it: `ViewerMenuPlan.bar`,
/// less the items that only reach a macOS application service.
public enum LinuxViewerMenu {
    /// Hide Others, Show All and Bring All to Front act on every other
    /// application's windows through macOS's own application services. A
    /// Wayland client can neither hide nor raise another application.
    public static let omitted: [ViewerMenuCommand] = [.hideOthers, .showAll, .bringAllToFront]

    public static func bar(_ state: ViewerMenuBarState) -> [ViewerMenu] {
        ViewerMenuPlan.bar(state).map(withoutOmitted)
    }

    /// Where macOS types Command, Linux types Ctrl; Shift and Option stay as
    /// they are, Option as Alt. The one macOS chord that also holds Control,
    /// Enter Full Screen's, takes Super for it so it stays apart from the
    /// Ctrl-for-Command chords.
    private static let modifierNames: [(ViewerMenuModifiers, String)] = [
        (.shift, "<Shift>"),
        (.option, "<Alt>"),
        (.command, "<Control>"),
        (.control, "<Super>")
    ]

    /// `keyEquivalent` and `modifiers` in GTK's accelerator syntax, or `nil`
    /// for an item without a chord.
    public static func accelerator(keyEquivalent: String, modifiers: ViewerMenuModifiers) -> String? {
        guard !keyEquivalent.isEmpty else { return nil }
        return modifierNames.filter { modifiers.contains($0.0) }.map(\.1).joined() + keyEquivalent
    }

    /// Which key stands for Command: Ctrl in Your Machines, which forwards
    /// nothing, and Super in a session window, where Ctrl reaches the host as
    /// Control and Super as Command.
    public enum ChordStyle: Sendable {
        case yourMachines
        case session
    }

    /// A chord as a menu row spells it, in the order and words GTK's own
    /// accelerator labels use.
    public static func chordLabel(keyEquivalent: String, modifiers: ViewerMenuModifiers, style: ChordStyle) -> String? {
        guard !keyEquivalent.isEmpty else { return nil }
        let ctrl = style == .yourMachines ? modifiers.contains(.command) : modifiers.contains(.control)
        let superKey = style == .yourMachines ? modifiers.contains(.control) : modifiers.contains(.command)
        var parts: [String] = []
        if modifiers.contains(.shift) { parts.append("Shift") }
        if ctrl { parts.append("Ctrl") }
        if modifiers.contains(.option) { parts.append("Alt") }
        if superKey { parts.append("Super") }
        parts.append(keyEquivalent.uppercased())
        return parts.joined(separator: "+")
    }

    /// The macOS modifiers a key press held, from the names of the Linux
    /// modifiers down: `<Control>`, `<Shift>`, `<Alt>` and `<Super>`.
    public static func modifiers(held names: [String]) -> ViewerMenuModifiers {
        var modifiers: ViewerMenuModifiers = []
        for (modifier, name) in modifierNames where names.contains(name) {
            modifiers.insert(modifier)
        }
        return modifiers
    }

    /// The enabled item that shows `key` with `held`, outside Edit: Edit's
    /// chords belong to the focused field, which handles them itself.
    public static func command(key: String, held: ViewerMenuModifiers, in menus: [ViewerMenu]) -> ViewerMenuCommand? {
        func find(in menu: ViewerMenu) -> ViewerMenuCommand? {
            for item in menu.items where item.isEnabled {
                if let submenu = item.submenu, let found = find(in: submenu) { return found }
                if !item.keyEquivalent.isEmpty, item.keyEquivalent == key, item.modifiers == held { return item.command }
            }
            return nil
        }
        for menu in menus where !menu.autoenablesItems {
            if let found = find(in: menu) { return found }
        }
        return nil
    }

    /// The item a key pressed in a session window chooses, by the rule a
    /// macOS canvas follows: a chord `SystemShortcutRouter` would forward
    /// from there is forwarded from here too, and only the rest reach the
    /// menu. `chord` is as the host would receive it, Super as Command and
    /// Ctrl as Control, and the menu is matched the same way, so no Ctrl
    /// chord, which a macOS canvas forwards as Control, is ever taken here.
    public static func sessionCommand(
        chord: KeyChord,
        key: String,
        in menus: [ViewerMenu],
        router: SystemShortcutRouter,
        viewer: ViewerWindowState
    ) -> ViewerMenuCommand? {
        guard !router.claimsKeyEquivalent(chord: chord, viewer: viewer, accessibilityGranted: true) else {
            return nil
        }
        var held: ViewerMenuModifiers = []
        if chord.modifiers.contains(.command) { held.insert(.command) }
        if chord.modifiers.contains(.control) { held.insert(.control) }
        if chord.modifiers.contains(.option) { held.insert(.option) }
        if chord.modifiers.contains(.shift) { held.insert(.shift) }
        return command(key: key, held: held, in: menus)
    }

    /// The macOS chord an accelerator stands for.
    public static func chord(accelerator: String) -> (keyEquivalent: String, modifiers: ViewerMenuModifiers)? {
        var rest = Substring(accelerator)
        var modifiers: ViewerMenuModifiers = []
        for (modifier, name) in modifierNames where rest.hasPrefix(name) {
            modifiers.insert(modifier)
            rest = rest.dropFirst(name.count)
        }
        return rest.isEmpty || rest.contains("<") ? nil : (String(rest), modifiers)
    }

    private static func withoutOmitted(_ menu: ViewerMenu) -> ViewerMenu {
        var items: [ViewerMenuItem] = []
        for item in menu.items where !omitted.contains(item.command) {
            if item.command == .separator, items.last?.command == .separator || items.isEmpty { continue }
            items.append(item.submenu.map { submenu in
                ViewerMenuItem(
                    title: item.title, command: item.command, keyEquivalent: item.keyEquivalent,
                    modifiers: item.modifiers, isEnabled: item.isEnabled, isSelected: item.isSelected,
                    submenu: withoutOmitted(submenu)
                )
            } ?? item)
        }
        if items.last?.command == .separator { items.removeLast() }
        return ViewerMenu(title: menu.title, autoenablesItems: menu.autoenablesItems, items: items)
    }

    /// What `command` does when a session window's menu chooses it.
    public static func sessionAction(for command: ViewerMenuCommand, clipboardSharingEnabled: Bool) -> LinuxSessionMenuAction {
        switch command {
        case .about, .hide, .quit, .showYourMachines:
            .application(command)
        case .toggleFullScreen: .toggleFullScreen
        case .toggleTelemetryOverlay: .toggleDiagnostics
        case .togglePointerCapture: .togglePointerCapture
        case .minimize: .minimize
        case .zoom: .zoom
        case .toggleClipboardSharing:
            .sessionChoice(.setClipboardSharing(ClipboardSharingToggle.nextValue(currentlyEnabled: clipboardSharingEnabled)))
        case let .setStreamScale(scale): .sessionChoice(.setStreamScale(scale))
        case let .selectDisplayCount(count): .sessionChoice(.selectDisplayCount(count))
        case let .selectRealScreen(token): .sessionChoice(.selectRealScreen(token))
        case let .selectHostScreenMode(modeID): .sessionChoice(.selectHostScreenMode(modeID))
        case let .selectStartTarget(target): .sessionChoice(.selectStartTarget(target))
        case .hideOthers, .showAll, .bringAllToFront, .undo, .redo, .cut, .copy, .paste, .selectAll,
             .streamScaleClampNotice, .escapeGestureHint, .separator, .submenu:
            .none
        }
    }
}

public enum LinuxSessionMenuAction: Equatable, Sendable {
    /// One of the app menu's own items, which act beyond this window.
    case application(ViewerMenuCommand)
    /// A choice about the session, sent where every other such choice goes.
    case sessionChoice(SessionControlsActivation)
    case toggleFullScreen
    case toggleDiagnostics
    case togglePointerCapture
    case minimize
    case zoom
    case none
}

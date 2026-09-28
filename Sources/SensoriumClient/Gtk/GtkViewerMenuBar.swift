#if canImport(CGtk4)
import CGtk4
import Foundation

/// `LinuxViewerMenu.bar` as a GTK menu bar across the top of a window.
///
/// Every item is an action in the window's `menu` group: a check where the
/// macOS item can carry one, enabled exactly as the model says. A separator
/// starts a new section, which is how a GTK menu draws one. The chord is only
/// shown beside the item: GTK binds no key to it. Edit's items act on the
/// focused field here; every other item goes to `onCommand`.
@MainActor
package final class GtkViewerMenuBar {
    package let widget: UnsafeMutableRawPointer
    package var onCommand: ((ViewerMenuCommand) -> Void)?

    private let window: GtkRef
    private let actions: GtkRef
    private var actionNames: [String] = []
    private var commands: [ViewerMenuCommand] = []
    private var titles: [String] = []
    private var menus: [ViewerMenu] = []
    private var editActions: [GtkRef] = []
    private var model: GtkRef?
    private var callbacks: [AnyObject] = []

    package init(window: UnsafeMutableRawPointer) {
        self.window = window
        actions = gtkRef(g_simple_action_group_new())
        gtk_widget_insert_action_group(sensorium_gtk_widget(window), "menu", sensorium_g_action_group(actions))
        widget = gtkRef(gtk_popover_menu_bar_new_from_model(nil))
        let focusChanged = GtkCallback { [weak self] in self?.refreshEditEnablement() }
        callbacks.append(focusChanged)
        let notify: @convention(c) (GtkRef?, GtkRef?, GtkRef?) -> Void = { _, _, data in gtkRunCallback(data) }
        gtkConnect(window, "notify::focus-widget", notify, Unmanaged.passUnretained(focusChanged).toOpaque())
    }

    /// Replaces every menu with `menus`. Called when the state behind them
    /// changes, never while one of them is open.
    package func update(_ menus: [ViewerMenu]) {
        guard menus != self.menus else { return }
        self.menus = menus
        for name in actionNames {
            g_action_map_remove_action(sensorium_g_action_map(actions), name)
        }
        actionNames = []
        commands = []
        titles = []
        editActions = []
        callbacks.removeAll { $0 is GtkIndexedCallback }
        let bar = gtkRef(g_menu_new())
        for menu in menus {
            let built = build(menu)
            g_menu_append_submenu(sensorium_g_menu(bar), menu.title, sensorium_g_menu_model(built))
            g_object_unref(built)
        }
        gtk_popover_menu_bar_set_menu_model(sensorium_gtk_popover_menu_bar(widget), sensorium_g_menu_model(bar))
        if let model { g_object_unref(model) }
        model = bar
        refreshEditEnablement()
    }

    /// The command a key press stands for, if an enabled item shows that
    /// chord.
    package func command(keyval: guint, state: GdkModifierType) -> ViewerMenuCommand? {
        let unicode = gdk_keyval_to_unicode(gdk_keyval_to_lower(keyval))
        guard unicode != 0, let scalar = Unicode.Scalar(unicode) else { return nil }
        let key = String(Character(scalar))
        let masks: [(GdkModifierType, String)] = [
            (GDK_CONTROL_MASK, "<Control>"), (GDK_SHIFT_MASK, "<Shift>"),
            (GDK_ALT_MASK, "<Alt>"), (GDK_SUPER_MASK, "<Super>")
        ]
        let held = LinuxViewerMenu.modifiers(held: masks.filter { state.rawValue & $0.0.rawValue != 0 }.map(\.1))
        return LinuxViewerMenu.command(key: key, held: held, in: menus)
    }

    private static func isCheckable(_ command: ViewerMenuCommand) -> Bool {
        switch command {
        case .togglePointerCapture, .toggleClipboardSharing, .setStreamScale, .selectDisplayCount,
             .selectRealScreen, .selectHostScreenMode, .selectStartTarget:
            true
        default:
            false
        }
    }

    private func build(_ menu: ViewerMenu) -> GtkRef {
        let result = gtkRef(g_menu_new())
        var section = gtkRef(g_menu_new())
        func closeSection() {
            if g_menu_model_get_n_items(sensorium_g_menu_model(section)) > 0 {
                g_menu_append_section(sensorium_g_menu(result), nil, sensorium_g_menu_model(section))
            }
            g_object_unref(section)
        }
        for item in menu.items {
            if item.command == .separator {
                closeSection()
                section = gtkRef(g_menu_new())
                continue
            }
            let name = addAction(for: item, isEdit: menu.autoenablesItems)
            let entry = gtkRef(g_menu_item_new(item.title, nil))
            if let submenu = item.submenu {
                let built = build(submenu)
                g_menu_item_set_submenu(OpaquePointer(entry), sensorium_g_menu_model(built))
                g_object_unref(built)
                // A submenu opens from its item only while this action is
                // enabled, which is how the item is shown disabled.
                g_menu_item_set_attribute_value(OpaquePointer(entry), "submenu-action", g_variant_new_string("menu.\(name)"))
            } else {
                g_menu_item_set_detailed_action(OpaquePointer(entry), "menu.\(name)")
            }
            if let accel = LinuxViewerMenu.accelerator(keyEquivalent: item.keyEquivalent, modifiers: item.modifiers) {
                g_menu_item_set_attribute_value(OpaquePointer(entry), "accel", g_variant_new_string(accel))
            }
            g_menu_append_item(sensorium_g_menu(section), OpaquePointer(entry))
            g_object_unref(entry)
        }
        closeSection()
        return result
    }

    private func addAction(for item: ViewerMenuItem, isEdit: Bool) -> String {
        let name = "item-\(actionNames.count)"
        let action: GtkRef
        if item.submenu != nil {
            // GTK sets a submenu's action true while it is open.
            action = gtkRef(g_simple_action_new_stateful(name, nil, g_variant_new_boolean(0)))
        } else if Self.isCheckable(item.command) {
            action = gtkRef(g_simple_action_new_stateful(name, nil, g_variant_new_boolean(item.isSelected ? 1 : 0)))
        } else {
            action = gtkRef(g_simple_action_new(name, nil))
        }
        g_simple_action_set_enabled(OpaquePointer(action), item.isEnabled ? 1 : 0)
        let index = commands.count
        commands.append(item.command)
        titles.append(item.title)
        actionNames.append(name)
        if isEdit { editActions.append(action) }
        if item.submenu == nil {
            let callback = GtkIndexedCallback { [weak self] _ in
                guard let self, index < self.commands.count else { return }
                if isEdit {
                    self.performEdit(self.commands[index])
                } else {
                    self.onCommand?(self.commands[index])
                }
            }
            callbacks.append(callback)
            let activate: @convention(c) (GtkRef?, OpaquePointer?, GtkRef?) -> Void = { _, _, data in
                gtkRunIndexedCallback(data, 0)
            }
            gtkConnect(action, "activate", activate, Unmanaged.passUnretained(callback).toOpaque())
        }
        g_action_map_add_action(sensorium_g_action_map(actions), sensorium_g_action(action))
        g_object_unref(action)
        return name
    }

    /// Edit's items work on the focused text field, as they do on macOS,
    /// where the responder chain enables them only when one has focus.
    private func refreshEditEnablement() {
        let focus = gtk_window_get_focus(sensorium_gtk_window(window))
        let enabled: gboolean = sensorium_is_editable(focus) != 0 ? 1 : 0
        for action in editActions {
            g_simple_action_set_enabled(OpaquePointer(action), enabled)
        }
    }

    /// Runs one of Edit's commands on the focused field.
    private func performEdit(_ command: ViewerMenuCommand) {
        guard let focus = gtk_window_get_focus(sensorium_gtk_window(window)) else { return }
        let name: String
        switch command {
        case .undo: name = "text.undo"
        case .redo: name = "text.redo"
        case .cut: name = "clipboard.cut"
        case .copy: name = "clipboard.copy"
        case .paste: name = "clipboard.paste"
        case .selectAll: name = "selection.select-all"
        default: return
        }
        _ = gtk_widget_activate_action_variant(focus, name, nil)
    }

    /// Chooses the item titled `title`, as a click on it would. False, and
    /// nothing done, when that item is disabled.
    package func activate(title: String) -> Bool {
        guard let index = titles.firstIndex(of: title) else { return false }
        let group = sensorium_g_action_group(actions)
        guard g_action_group_get_action_enabled(group, actionNames[index]) != 0 else { return false }
        g_action_group_activate_action(group, actionNames[index], nil)
        return true
    }

    /// The bar as it is drawn, flattened the way `ViewerMenuPlan.rows(of:)`
    /// flattens the model, so a test can compare the two.
    package func rows() -> [ViewerMenuRow] {
        guard let model, let bar = sensorium_g_menu_model(model) else { return [] }
        var result: [ViewerMenuRow] = []
        for index in 0..<g_menu_model_get_n_items(bar) {
            result.append(ViewerMenuRow(
                depth: 0, title: label(bar, index), keyEquivalent: "", modifiers: [],
                isEnabled: true, isChecked: false, isSeparator: false
            ))
            if let submenu = g_menu_model_get_item_link(bar, index, "submenu") {
                let isEdit = menus.first { $0.title == label(bar, index) }?.autoenablesItems ?? false
                appendRows(of: submenu, depth: 1, isEdit: isEdit, into: &result)
                g_object_unref(submenu)
            }
        }
        return result
    }

    private func appendRows(of menu: UnsafeMutablePointer<GMenuModel>, depth: Int, isEdit: Bool, into result: inout [ViewerMenuRow]) {
        for sectionIndex in 0..<g_menu_model_get_n_items(menu) {
            guard let section = g_menu_model_get_item_link(menu, sectionIndex, "section") else { continue }
            if sectionIndex > 0 {
                result.append(ViewerMenuRow(
                    depth: depth, title: "", keyEquivalent: "", modifiers: [],
                    isEnabled: isEdit ? nil : false, isChecked: false, isSeparator: true
                ))
            }
            for index in 0..<g_menu_model_get_n_items(section) {
                let action = (attribute(section, index, "action") ?? attribute(section, index, "submenu-action"))
                    .map { String($0.dropFirst("menu.".count)) }
                let chord = attribute(section, index, "accel").flatMap(LinuxViewerMenu.chord(accelerator:))
                let group = sensorium_g_action_group(actions)
                var isChecked = false
                if let action, let state = g_action_group_get_action_state(group, action) {
                    isChecked = g_variant_get_boolean(state) != 0 && attribute(section, index, "action") != nil
                    g_variant_unref(state)
                }
                result.append(ViewerMenuRow(
                    depth: depth,
                    title: label(section, index),
                    keyEquivalent: chord?.keyEquivalent ?? "",
                    modifiers: chord?.modifiers ?? [],
                    isEnabled: isEdit ? nil : action.map { g_action_group_get_action_enabled(group, $0) != 0 } ?? false,
                    isChecked: isChecked,
                    isSeparator: false
                ))
                if let submenu = g_menu_model_get_item_link(section, index, "submenu") {
                    appendRows(of: submenu, depth: depth + 1, isEdit: false, into: &result)
                    g_object_unref(submenu)
                }
            }
            g_object_unref(section)
        }
    }

    private func label(_ menu: UnsafeMutablePointer<GMenuModel>, _ index: Int32) -> String {
        attribute(menu, index, "label") ?? ""
    }

    private func attribute(_ menu: UnsafeMutablePointer<GMenuModel>, _ index: Int32, _ name: String) -> String? {
        guard let value = g_menu_model_get_item_attribute_value(menu, index, name, sensorium_variant_type_string()) else {
            return nil
        }
        defer { g_variant_unref(value) }
        return String(cString: g_variant_get_string(value, nil))
    }
}
#endif

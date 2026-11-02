#if canImport(AppKit)
import AppKit

@MainActor
public final class AppAppearance: NSObject, NSMenuDelegate {
    public static let shared = AppAppearance()
    private let store = AppearancePreferenceStore()
    private var refreshColors: (() -> Void)?
    private var windowAppearances: [ObjectIdentifier: String] = [:]
    private var observation: NSKeyValueObservation?

    public func install(refreshColors: @escaping () -> Void) {
        self.refreshColors = refreshColors
        NotificationCenter.default.removeObserver(self)
        NotificationCenter.default.addObserver(self, selector: #selector(windowUpdated(_:)), name: NSWindow.didUpdateNotification, object: nil)
        NSApplication.shared.appearance = store.preference.nsAppearance
        observation = NSApplication.shared.observe(\.effectiveAppearance) { _, _ in
            MainActor.assumeIsolated { AppAppearance.shared.refreshColors?() }
        }
        refreshColors()
    }

    @objc private func windowUpdated(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let key = ObjectIdentifier(window)
        let name = window.effectiveAppearance.name.rawValue
        guard windowAppearances[key] != name else { return }
        windowAppearances[key] = name
        refreshColors?()
    }

    public func menuItem() -> NSMenuItem {
        let holder = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Appearance")
        menu.delegate = self
        menu.autoenablesItems = false
        holder.keyEquivalentModifierMask = []
        for preference in AppearancePreference.allCases {
            let item = NSMenuItem(title: preference.rawValue.capitalized, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.keyEquivalentModifierMask = []
            item.state = preference == store.preference ? .on : .off
            item.representedObject = preference.rawValue
            item.target = self
            menu.addItem(item)
        }
        holder.submenu = menu
        return holder
    }

    public func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            item.state = (item.representedObject as? String) == store.preference.rawValue ? .on : .off
        }
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let preference = AppearancePreference(rawValue: raw) else { return }
        store.preference = preference
        NSApplication.shared.appearance = preference.nsAppearance
        refreshColors?()
    }
}
#endif

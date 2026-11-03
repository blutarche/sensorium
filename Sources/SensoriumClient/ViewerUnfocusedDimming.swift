#if canImport(AppKit)
import AppKit

@MainActor
final class ViewerUnfocusedDimming: NSObject {
    static let shared = ViewerUnfocusedDimming()
    static let changed = Notification.Name("ViewerUnfocusedDimmingChanged")
    private let key = "viewerUnfocusedDimmingPercent"
    private weak var valueLabel: NSTextField?

    var percent: Double {
        min(100, max(0, UserDefaults.standard.double(forKey: key)))
    }

    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Dim When Unfocused", action: nil, keyEquivalent: "")
        item.keyEquivalentModifierMask = []
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 62))
        let label = NSTextField(labelWithString: "Dim When Unfocused: \(Int(percent))%")
        label.frame = NSRect(x: 16, y: 36, width: 230, height: 18)
        let slider = NSSlider(value: percent, minValue: 0, maxValue: 100, target: self, action: #selector(adjust(_:)))
        slider.frame = NSRect(x: 16, y: 8, width: 228, height: 24)
        slider.isContinuous = true
        slider.setAccessibilityLabel("Dim When Unfocused")
        view.addSubview(label)
        view.addSubview(slider)
        valueLabel = label
        item.view = view
        return item
    }

    @objc private func adjust(_ sender: NSSlider) {
        let value = sender.doubleValue.rounded()
        UserDefaults.standard.set(value, forKey: key)
        valueLabel?.stringValue = "Dim When Unfocused: \(Int(value))%"
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

@MainActor
package final class ViewerWindowDimming: NSObject {
    private weak var window: NSWindow?
    private let overlay = DimmingOverlay()

    package init(window: NSWindow) {
        self.window = window
        super.init()
        guard let content = window.contentView else { return }
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.black.cgColor
        overlay.frame = content.bounds
        overlay.autoresizingMask = [.width, .height]
        content.addSubview(overlay, positioned: .above, relativeTo: nil)
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(update), name: name, object: window)
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification, ViewerUnfocusedDimming.changed] {
            NotificationCenter.default.addObserver(self, selector: #selector(update), name: name, object: nil)
        }
        update()
    }

    @objc private func update() {
        let focused = window?.isKeyWindow == true && NSApp.isActive
        overlay.alphaValue = focused ? 0 : ViewerUnfocusedDimming.shared.percent / 100
    }
}

@MainActor
private final class DimmingOverlay: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
#endif

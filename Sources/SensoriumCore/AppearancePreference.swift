import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// The palette a window is drawn in once the person's choice and the machine's
/// own setting have been settled.
public enum ResolvedAppearance: String, Codable, Sendable, CaseIterable {
    case light
    case dark
}

/// What the person asked for in an app's appearance setting. `system` follows
/// the machine; the other two pin the app regardless of it.
public enum AppearancePreference: String, Codable, Sendable, CaseIterable {
    case system
    case light
    case dark

    public func resolved(systemIsDark: Bool) -> ResolvedAppearance {
        switch self {
        case .system: return systemIsDark ? .dark : .light
        case .light: return .light
        case .dark: return .dark
        }
    }

    #if canImport(AppKit)
    /// The appearance to assign to `NSApplication.appearance` or a window.
    /// `nil` hands the decision back to the machine.
    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    #endif
}

/// One app's stored appearance setting. Each app passes its own defaults
/// domain, so the host and the viewer keep separate values.
public final class AppearancePreferenceStore: @unchecked Sendable {
    public static let key = "appearancePreference"
    public static let didChangeNotification = Notification.Name("SensoriumAppearancePreferenceDidChange")

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter

    public init(defaults: UserDefaults = .standard, notificationCenter: NotificationCenter = .default) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    /// A missing or unrecognised stored value reads as `.system`. Setting a
    /// different value notifies observers once; setting the same one is silent.
    public var preference: AppearancePreference {
        get {
            defaults.string(forKey: Self.key).flatMap(AppearancePreference.init(rawValue:)) ?? .system
        }
        set {
            guard newValue != preference else { return }
            defaults.set(newValue.rawValue, forKey: Self.key)
            notificationCenter.post(name: Self.didChangeNotification, object: self)
        }
    }

    /// Calls `handler` with the new value after each change made through this
    /// store's notification center. The caller removes the returned token from
    /// that center when it no longer needs the callback. A window that
    /// re-applies on change observes with `queue: .main`.
    public func observe(
        queue: OperationQueue? = nil,
        handler: @escaping @Sendable (AppearancePreference) -> Void
    ) -> NSObjectProtocol {
        notificationCenter.addObserver(forName: Self.didChangeNotification, object: self, queue: queue) { notification in
            guard let store = notification.object as? AppearancePreferenceStore else { return }
            handler(store.preference)
        }
    }
}

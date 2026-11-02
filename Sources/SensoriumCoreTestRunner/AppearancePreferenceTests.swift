import Foundation
import SensoriumCore

#if canImport(AppKit)
import AppKit
#endif

func testAppearancePreferenceResolvesAgainstTheSystemOnlyWhenFollowingIt() {
    for systemIsDark in [true, false] {
        expect(
            AppearancePreference.system.resolved(systemIsDark: systemIsDark) == (systemIsDark ? .dark : .light),
            "System follows the machine (systemIsDark \(systemIsDark))"
        )
        expect(
            AppearancePreference.light.resolved(systemIsDark: systemIsDark) == .light,
            "Light stays light whatever the machine is set to (systemIsDark \(systemIsDark))"
        )
        expect(
            AppearancePreference.dark.resolved(systemIsDark: systemIsDark) == .dark,
            "Dark stays dark whatever the machine is set to (systemIsDark \(systemIsDark))"
        )
    }
}

func testAppearancePreferenceKeepsStableRawValuesAndRoundTripsThroughCodable() {
    expect(
        AppearancePreference.allCases.map(\.rawValue) == ["system", "light", "dark"],
        "the stored names are system, light and dark, in the order a picker lists them"
    )
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    for preference in AppearancePreference.allCases {
        let data = try? encoder.encode([preference])
        expect(
            data.flatMap { try? decoder.decode([AppearancePreference].self, from: $0) } == [preference],
            "\(preference.rawValue) survives a Codable round trip"
        )
    }
    expect(
        (try? decoder.decode([AppearancePreference].self, from: Data("[\"sepia\"]".utf8))) == nil,
        "an unknown name does not decode"
    )
}

#if canImport(AppKit)
func testAppearancePreferenceMapsToTheMatchingNSAppearance() {
    expect(AppearancePreference.system.nsAppearance == nil, "System leaves the appearance to the machine")
    expect(AppearancePreference.light.nsAppearance?.name == .aqua, "Light is aqua")
    expect(AppearancePreference.dark.nsAppearance?.name == .darkAqua, "Dark is dark aqua")
}
#endif

private func withScratchDefaults(_ body: (UserDefaults) -> Void) {
    let suiteName = "org.sensorium.test.appearance.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
        expect(false, "a scratch defaults suite could be opened")
        return
    }
    defer { defaults.removePersistentDomain(forName: suiteName) }
    body(defaults)
}

func testAppearancePreferenceStoreDefaultsToSystemAndReadsBackWhatWasSet() {
    withScratchDefaults { defaults in
        let store = AppearancePreferenceStore(defaults: defaults, notificationCenter: NotificationCenter())
        expect(store.preference == .system, "nothing stored reads as System")
        for preference in AppearancePreference.allCases {
            store.preference = preference
            expect(store.preference == preference, "\(preference.rawValue) reads back")
            expect(
                AppearancePreferenceStore(defaults: defaults, notificationCenter: NotificationCenter()).preference == preference,
                "\(preference.rawValue) is read by a second store over the same defaults"
            )
        }
        expect(
            defaults.string(forKey: AppearancePreferenceStore.key) == "dark",
            "the value is kept as its name under appearancePreference"
        )
    }
}

func testAppearancePreferenceStoreTreatsAnInvalidStoredValueAsSystem() {
    withScratchDefaults { defaults in
        let store = AppearancePreferenceStore(defaults: defaults, notificationCenter: NotificationCenter())
        defaults.set("sepia", forKey: AppearancePreferenceStore.key)
        expect(store.preference == .system, "an unknown name reads as System")
        defaults.set(3, forKey: AppearancePreferenceStore.key)
        expect(store.preference == .system, "a value of the wrong type reads as System")
        defaults.removeObject(forKey: AppearancePreferenceStore.key)
        expect(store.preference == .system, "a removed value reads as System")
    }
}

func testAppearancePreferenceStoreAnnouncesOnlyRealChanges() {
    withScratchDefaults { defaults in
        let center = NotificationCenter()
        let store = AppearancePreferenceStore(defaults: defaults, notificationCenter: center)
        let seen = AppearanceChangeLog()
        let observation = store.observe { seen.append($0) }
        defer { center.removeObserver(observation) }

        store.preference = .dark
        store.preference = .dark
        store.preference = .light
        store.preference = .system
        expect(
            seen.values == [.dark, .light, .system],
            "each change reaches an observer once, and setting the same value again is silent: \(seen.values)"
        )

        let other = AppearancePreferenceStore(defaults: defaults, notificationCenter: NotificationCenter())
        other.preference = .dark
        expect(seen.values.count == 3, "a store on another notification center does not reach this observer")
    }
}

final class AppearanceChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AppearancePreference] = []

    func append(_ value: AppearancePreference) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(value)
    }

    var values: [AppearancePreference] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

import AppKit
import Foundation
import SensoriumCore
import SensoriumHost

/// "Allow connections from this network" is off unless the person at this
/// machine turned it on.
@MainActor
func runHostLocalNetworkSettingTests() {
    do {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-local-network-missing-\(UUID().uuidString).json")
        let store = HostLocalNetworkSettingStore(url: url)
        expect(!store.load().allowsLocalNetwork, "a machine that never stored the setting does not allow this network")
        print("PASS: connections from this network are off by default, including on a machine that never stored the setting")
    }

    do {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-local-network-unreadable-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try! Data("not json".utf8).write(to: url)
        var logged: [String] = []
        let store = HostLocalNetworkSettingStore(url: url, log: { logged.append($0) })
        expect(!store.load().allowsLocalNetwork, "an unreadable setting reads as off")
        _ = store.load()
        expect(logged.count == 1, "an unreadable setting is reported once, got \(logged.count)")
        print("PASS: an unreadable local network setting reads as off and says so once")
    }

    do {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-local-network-saved-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try! HostLocalNetworkSettingStore(url: url).save(HostLocalNetworkSetting(allowsLocalNetwork: true))
        expect(
            HostLocalNetworkSettingStore(url: url).load().allowsLocalNetwork,
            "a setting turned on is still on for the next launch"
        )
        try! HostLocalNetworkSettingStore(url: url).save(HostLocalNetworkSetting(allowsLocalNetwork: false))
        expect(
            !HostLocalNetworkSettingStore(url: url).load().allowsLocalNetwork,
            "a setting turned off again is still off for the next launch"
        )
        print("PASS: the local network setting persists across launches")
    }
}

/// Turning the setting off ends every live connection that did not come over
/// the tailnet, including one accepted just before and registered just after.
@MainActor
func runHostLocalNetworkConnectionRegistryTests() {
    do {
        let registry = HostLocalNetworkConnectionRegistry(allowsLocalNetwork: true)
        var stopped: [String] = []
        let first = registry.admit(stop: { stopped.append("first") })
        let second = registry.admit(stop: { stopped.append("second") })
        expect(first != nil && second != nil, "with the setting on, a connection from this network is kept")
        expect(stopped.isEmpty, "nothing is stopped while the setting stays on")

        registry.setAllowsLocalNetwork(false)
        expect(Set(stopped) == ["first", "second"], "turning the setting off stops every one, got \(stopped)")

        registry.setAllowsLocalNetwork(false)
        expect(stopped.count == 2, "each connection is stopped once, got \(stopped)")
        print("PASS: turning the setting off ends every live connection from this network, once")
    }

    do {
        let registry = HostLocalNetworkConnectionRegistry(allowsLocalNetwork: true)
        var stopped: [String] = []
        let ended = registry.admit(stop: { stopped.append("ended") })!
        _ = registry.admit(stop: { stopped.append("live") })
        registry.release(ended)
        registry.setAllowsLocalNetwork(false)
        expect(stopped == ["live"], "a connection that already ended is not stopped again, got \(stopped)")
        print("PASS: a connection that ended on its own is forgotten")
    }

    do {
        let registry = HostLocalNetworkConnectionRegistry(allowsLocalNetwork: true)
        registry.setAllowsLocalNetwork(false)
        var stopped = 0
        let late = registry.admit(stop: { stopped += 1 })
        expect(late == nil, "a connection registered after the setting went off is not kept")
        expect(stopped == 1, "and is stopped at once, got \(stopped)")

        registry.setAllowsLocalNetwork(true)
        var kept = 0
        expect(registry.admit(stop: { kept += 1 }) != nil, "turning it back on keeps new connections again")
        expect(kept == 0, "without stopping them")
        print("PASS: a connection that registers after the setting went off is stopped at once")
    }
}

/// The host window's "Allow connections from this network" checkbox shows the
/// stored setting and hands a click back to whoever stores it.
@MainActor
func runHostLocalNetworkSwitchTests() {
    func stored<T>(_ name: String, in controller: HostSetupWindowController, as type: T.Type) -> T {
        for child in Mirror(reflecting: controller).children where child.label == name {
            if let value = child.value as? T {
                return value
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named \(name)")
    }

    var allowed = false
    var toggles: [Bool] = []
    let controller = HostSetupWindowController(
        status: HostOperatorStatus(
            connection: .notHosting,
            permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted),
            problem: nil
        ),
        onRevealPairingCode: {},
        onStop: {},
        tailscaleAppURLLookup: { nil },
        onOpenTailscaleApp: { _ in },
        onToggleSharing: { _, _ in },
        onRemovePairedDevice: { _ in },
        allowsLocalNetwork: { allowed },
        onToggleLocalNetwork: { isOn in
            toggles.append(isOn)
            allowed = isOn
        }
    )
    let checkbox = stored("localNetworkCheckbox", in: controller, as: NSButton.self)
    let explanation = stored("localNetworkExplanationLabel", in: controller, as: NSTextField.self)
    expect(
        checkbox.title == "Allow connections from this network",
        "the checkbox is titled for what it allows, got \(checkbox.title)"
    )
    expect(
        explanation.stringValue == "Lets a viewer on the same Wi-Fi or wired network connect by name, such as "
            + "mini.local, without Tailscale. Anyone on this network can then ask to pair. Leave it off on "
            + "shared networks.",
        "the explanation sits under it, got \(explanation.stringValue)"
    )
    expect(checkbox.state == .off, "the stored setting off reads as an off checkbox")

    checkbox.performClick(nil)
    expect(toggles == [true], "a click turns the setting on through the caller, got \(toggles)")
    expect(checkbox.state == .on, "the checkbox then reads the stored setting back as on")

    checkbox.performClick(nil)
    expect(toggles == [true, false], "a second click turns it off again, got \(toggles)")
    expect(checkbox.state == .off, "and the checkbox reads it back as off")
    print("PASS: the host window's local network checkbox shows the stored setting and changes it")
}

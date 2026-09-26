import Foundation
import AppKit
import SensoriumCore
import SensoriumHost

/// "Offer a private desktop" is off unless the person at this machine turned
/// it on, and while it is off nothing creates a virtual display at launch.
@MainActor
func runHostPrivateDesktopSettingTests() {
    do {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-private-desktop-missing-\(UUID().uuidString).json")
        let store = HostPrivateDesktopSettingStore(url: url)
        expect(!store.load().offersPrivateDesktop, "a machine that never stored the setting does not offer a private desktop")
        print("PASS: the private desktop is off by default, including on a machine that never stored the setting")
    }

    do {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-private-desktop-unreadable-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try! Data("not json".utf8).write(to: url)
        var logged: [String] = []
        let store = HostPrivateDesktopSettingStore(url: url, log: { logged.append($0) })
        expect(!store.load().offersPrivateDesktop, "an unreadable setting reads as off")
        expect(logged.count == 1, "an unreadable setting is reported once")
        print("PASS: an unreadable private desktop setting reads as off and says so")
    }

    do {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-private-desktop-saved-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try! HostPrivateDesktopSettingStore(url: url).save(HostPrivateDesktopSetting(offersPrivateDesktop: true))
        expect(
            HostPrivateDesktopSettingStore(url: url).load().offersPrivateDesktop,
            "a setting turned on is still on for the next launch"
        )
        try! HostPrivateDesktopSettingStore(url: url).save(HostPrivateDesktopSetting(offersPrivateDesktop: false))
        expect(
            !HostPrivateDesktopSettingStore(url: url).load().offersPrivateDesktop,
            "a setting turned off again is still off for the next launch"
        )
        print("PASS: the private desktop setting persists across launches")
    }

    do {
        let adapter = FakeVirtualDisplayAdapter()
        let verdict = HostVirtualDisplayCapability.startupCheck(
            offersPrivateDesktop: false,
            makeAdapter: { _ in adapter }
        )
        expect(verdict == .notOffered, "with the private desktop off, the startup check reports it is not offered")
        expect(
            adapter.acquiredConfigurations.isEmpty && adapter.releasedHandles.isEmpty,
            "with the private desktop off, launch creates no virtual display at all"
        )

        let offeredAdapter = FakeVirtualDisplayAdapter()
        let offered = HostVirtualDisplayCapability.startupCheck(
            offersPrivateDesktop: true,
            makeAdapter: { _ in offeredAdapter }
        )
        expect(offered == .supported, "with the private desktop on, the startup check still probes")
        expect(
            offeredAdapter.acquiredConfigurations == [.remoteDefault] && offeredAdapter.releasedHandles.count == 1,
            "with the private desktop on, the probe creates and releases exactly one display, as before"
        )
        print("PASS: launch creates no virtual display while the private desktop is off, and probes as before while it is on")
    }
}

/// With the private desktop off, no canvas request creates one, the offer
/// says so, and turning it off mid-session leaves the live canvas alone.
@MainActor
func runHostPrivateDesktopRefusalTests() {
    let identity = try! DeviceIdentity.generate()
    func hello() -> SensoriumMessage {
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, hostCertificateHash: nil
        )
        return .authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey,
            signature: try! identity.sign(transcript)
        )
    }
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(devicePublicKey: identity.publicKey, deviceName: "Probe", armedAt: Date()),
    ])

    do {
        let adapter = FakeVirtualDisplayAdapter()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: adapter)),
            keyConfinement: .unconfined,
            privateDesktopOffered: { false }
        )
        let response = try? controller.handle(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
        )
        expect(
            response == .canvasRefused(reason: CanvasRefusalReason.canvasNotOffered, surfaceID: 0),
            "a canvas request is refused while the private desktop is off, got \(String(describing: response))"
        )
        expect(adapter.acquiredConfigurations.isEmpty, "a refused canvas request creates no virtual display")
        expect(CanvasRefusalReason.canvasNotOffered == "canvas-not-offered", "the token a viewer branches on is stable")
        print("PASS: a canvas request is refused, and creates nothing, while the private desktop is off")
    }

    do {
        for offered in [false, true] {
            let controller = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                approvedPublicKeys: [identity.publicKey],
                requireAuthentication: true,
                keyConfinement: .unconfined,
                hostScreenArmingProvider: { arming },
                hostScreenCurrentDisplaysProvider: { [] },
                privateDesktopOffered: { offered }
            )
            _ = try! controller.handle(hello())
            let offer = try! controller.offerHostScreenList()
            expect(
                offer == .hostScreenList(displays: [], canvasAvailable: offered),
                "the offer says whether a private desktop is available (\(offered)), got \(offer)"
            )
        }
        print("PASS: the host-screen offer tells the viewer whether a private desktop is available")
    }

    do {
        var offered = true
        let primary = FakeVirtualDisplayAdapter()
        let second = FakeVirtualDisplayAdapter()
        let controller = HostSessionController(
            sessions: CanvasSurfaceSlots(
                surface0: VirtualDisplaySession(adapter: primary),
                surface1: VirtualDisplaySession(adapter: second)
            ),
            keyConfinement: .unconfined,
            privateDesktopOffered: { offered }
        )
        let ready = try? controller.handle(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
        )
        guard case .canvasReady? = ready else {
            expect(false, "a canvas request is admitted while the private desktop is on, got \(String(describing: ready))")
            return
        }
        offered = false
        let secondResponse = try? controller.handle(.displayCount(2))
        expect(
            secondResponse == .canvasRefused(reason: CanvasRefusalReason.canvasNotOffered, surfaceID: 1),
            "a second display asked for after the setting went off is refused, got \(String(describing: secondResponse))"
        )
        expect(second.acquiredConfigurations.isEmpty, "the refused second display creates nothing")
        expect(
            primary.acquiredConfigurations.count == 1 && primary.releasedHandles.isEmpty,
            "the canvas already live when the setting went off is left running"
        )
        print("PASS: turning the private desktop off leaves a live canvas running and applies to the next request")
    }

    do {
        // Off unless the caller says otherwise -- matching
        // `HostPrivateDesktopSettingStore`'s own off-by-default and
        // `HostSetupWindow`'s unchecked box, so a caller that forgets to wire
        // the setting through gets the safe answer rather than a canvas it
        // never asked to offer.
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        let response = try? controller.handle(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
        )
        expect(
            response == .canvasRefused(reason: CanvasRefusalReason.canvasNotOffered, surfaceID: 0),
            "HostSessionController with no privateDesktopOffered argument refuses a canvas by default, "
                + "got \(String(describing: response))"
        )

        let factoryController = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        ).makeController()
        let factoryResponse = try? factoryController.handle(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
        )
        expect(
            factoryResponse == .canvasRefused(reason: CanvasRefusalReason.canvasNotOffered, surfaceID: 0),
            "HostConnectionSessionFactory with no privateDesktopOffered argument builds a controller that "
                + "refuses a canvas by default, got \(String(describing: factoryResponse))"
        )
        print("PASS: neither HostSessionController nor HostConnectionSessionFactory offers a private desktop unless told to")
    }
}

/// The host window's "Offer a private desktop" checkbox shows the stored
/// setting and hands a click back to whoever stores it.
@MainActor
func runHostPrivateDesktopSwitchTests() {
    func stored<T>(_ name: String, in controller: HostSetupWindowController, as type: T.Type) -> T {
        for child in Mirror(reflecting: controller).children where child.label == name {
            if let value = child.value as? T {
                return value
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named \(name)")
    }

    var offered = false
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
        offersPrivateDesktop: { offered },
        onTogglePrivateDesktop: { isOn in
            toggles.append(isOn)
            offered = isOn
        }
    )
    let checkbox = stored("privateDesktopCheckbox", in: controller, as: NSButton.self)
    let explanation = stored("privateDesktopExplanationLabel", in: controller, as: NSTextField.self)
    expect(checkbox.title == "Offer a private desktop", "the checkbox is titled for what it offers, got \(checkbox.title)")
    expect(
        explanation.stringValue == "Lets a viewer open a separate desktop that isn\u{2019}t shown on this Mac\u{2019}s screens.",
        "the one-line explanation sits under it, got \(explanation.stringValue)"
    )
    expect(checkbox.state == .off, "the stored setting off reads as an off checkbox")

    checkbox.performClick(nil)
    expect(toggles == [true], "a click turns the setting on through the caller, got \(toggles)")
    expect(checkbox.state == .on, "the checkbox then reads the stored setting back as on")

    checkbox.performClick(nil)
    expect(toggles == [true, false], "a second click turns it off again, got \(toggles)")
    expect(checkbox.state == .off, "and the checkbox reads it back as off")
    print("PASS: the host window's private desktop checkbox shows the stored setting and changes it")
}

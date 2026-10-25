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
        explanation.stringValue == "Lets a viewer open a separate desktop that isn\u{2019}t shown on this machine\u{2019}s screens.",
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

/// A machine that cannot make a private desktop still hosts: host screen is
/// the product and does not need one. The probe's reason is kept for the rest
/// of the run, no viewer is offered a private desktop, and the host window
/// says why under the switch while its status card reads as it would without.
@MainActor
func runHostPrivateDesktopProbeFailureTests() {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
    let failing = FakeVirtualDisplayAdapter()
    failing.acquireError = CoreGraphicsVirtualDisplayError.creationFailed
    let store = HostOperatorStatusStore(permissions: granted)
    var events: [String] = []
    var logged: [String] = []
    var probeReason: String?
    HostHostingStartup.begin(
        offersPrivateDesktop: true,
        status: store,
        probe: {
            events.append("probe")
            let verdict = HostVirtualDisplayCapability.probe(makeAdapter: { _ in failing })
            if case let .unsupported(reason) = verdict { probeReason = reason }
            return verdict
        },
        log: { logged.append($0) },
        beginHosting: {
            expect(
                probeReason != nil && store.status.privateDesktopUnavailableReason == probeReason,
                "startup records the probe failure before beginning hosting"
            )
            events.append("begin")
            store.beginHosting(address: "100.64.1.5")
        }
    )
    expect(events == ["probe", "begin"], "the GUI startup path begins hosting after an unsupported private-desktop probe")
    guard let reason = probeReason else {
        expect(false, "with the switch on, a failing probe reports why")
        return
    }
    expect(logged == ["Sensorium host: \(reason)"], "the failed probe is recorded in the session log once")

    do {
        let now = Date()
        expect(
            store.status.connection == .hosting(address: "100.64.1.5") && store.status.problem == nil
                && store.status.identityProblem == nil,
            "a failed private-desktop probe still lets hosting begin, got \(store.status.connection)"
        )
        expect(
            store.status.privateDesktopUnavailableReason == reason,
            "the probe's reason outlives hosting starting"
        )
        expect(
            !store.status.offersPrivateDesktop(whenSwitchedOn: true),
            "with the probe failed, no viewer is offered a private desktop even with the switch on"
        )

        let adapter = FakeVirtualDisplayAdapter()
        let controller = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: adapter)),
            keyConfinement: .unconfined,
            privateDesktopOffered: { store.status.offersPrivateDesktop(whenSwitchedOn: true) }
        ).makeController()
        expect(
            try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0))
                == .canvasRefused(reason: CanvasRefusalReason.canvasNotOffered, surfaceID: 0),
            "a connection created after a failed probe refuses a private-desktop request"
        )
        expect(adapter.acquiredConfigurations.isEmpty, "a connection after a failed probe never attempts a session canvas")

        let unaffected = HostOperatorStatus(connection: .hosting(address: "100.64.1.5"), permissions: granted)
        expect(
            unaffected.offersPrivateDesktop(whenSwitchedOn: true) && !unaffected.offersPrivateDesktop(whenSwitchedOn: false),
            "with no failed probe, the switch alone decides"
        )
        expect(
            store.status.presentation(now: now) == unaffected.presentation(now: now),
            "the eyebrow, headline, detail and pairing read exactly as they would without the failed probe"
        )

        store.reportProblem("address already in use")
        store.stopHosting()
        store.reportIdentityProblem(.cannotReadKey)
        store.clearIdentityProblem()
        store.beginHosting(address: "100.64.1.5")
        expect(
            store.status.privateDesktopUnavailableReason == reason,
            "the reason holds for the rest of the run, whatever hosting does next"
        )
        for switchedOn in [false, true] {
            HostHostingStartup.begin(
                offersPrivateDesktop: switchedOn,
                status: store,
                probe: { events.append("unexpected probe"); return .supported },
                log: { logged.append($0) },
                beginHosting: { events.append("begin") }
            )
        }
        expect(events == ["probe", "begin", "begin", "begin"], "later starts still host and never probe again after failure, even after the switch changes")
        expect(logged.count == 1 && store.status.privateDesktopUnavailableReason == reason, "the failure remains sticky for the process lifetime")
        print("PASS: a failed private-desktop probe still begins hosting, offers no private desktop, and keeps its reason for the run")
    }

    for switchedOn in [false, true] {
        let status = HostOperatorStatusStore(permissions: granted)
        let adapter = FakeVirtualDisplayAdapter()
        var steps: [String] = []
        HostHostingStartup.begin(
            offersPrivateDesktop: switchedOn,
            status: status,
            probe: {
                steps.append("probe")
                return HostVirtualDisplayCapability.probe(makeAdapter: { _ in adapter })
            },
            log: { _ in expect(false, "a supported or disabled private desktop needs no warning") },
            beginHosting: {
                steps.append("begin")
                status.beginHosting(address: "100.64.1.5")
            }
        )
        expect(steps == (switchedOn ? ["probe", "begin"] : ["begin"]), "startup probes only when offered, then begins hosting")
        expect(status.status.offersPrivateDesktop(whenSwitchedOn: switchedOn) == switchedOn, "a successful probe preserves the normal private-desktop offer")
        expect(adapter.acquiredConfigurations.count == (switchedOn ? 1 : 0), "a private desktop not offered creates nothing at startup")
        expect(adapter.releasedHandles.count == adapter.acquiredConfigurations.count, "a successful startup probe releases its display")
    }
    print("PASS: the GUI startup path hosts without probing when private desktop is off, and offers it after a successful probe")

    do {
        func stored<T>(_ name: String, in controller: HostSetupWindowController, as type: T.Type) -> T {
            for child in Mirror(reflecting: controller).children where child.label == name {
                if let value = child.value as? T {
                    return value
                }
            }
            fatalError("HostSetupWindowController no longer has a stored property named \(name)")
        }
        func window(_ status: HostOperatorStatus) -> HostSetupWindowController {
            HostSetupWindowController(
                status: status,
                onRevealPairingCode: {},
                onStop: {},
                tailscaleAppURLLookup: { nil },
                onOpenTailscaleApp: { _ in },
                onToggleSharing: { _, _ in },
                onRemovePairedDevice: { _ in },
                autoLoginStatus: { .requiresApproval },
                offersPrivateDesktop: { true }
            )
        }

        var status = HostOperatorStatus(connection: .hosting(address: "100.64.1.5"), permissions: granted)
        status.privateDesktopUnavailableReason = reason
        let controller = window(status)
        let line = stored("privateDesktopUnavailableLabel", in: controller, as: NSTextField.self)
        let checkbox = stored("privateDesktopCheckbox", in: controller, as: NSButton.self)
        let loginLine = stored("autoLoginStatusLabel", in: controller, as: NSTextField.self)
        let arranged = stored("root", in: controller, as: NSStackView.self).arrangedSubviews
        let words = line.stringValue
            .replacingOccurrences(of: HostTextFlow.noBreakSpace, with: " ")
            .replacingOccurrences(of: HostTextFlow.nonBreakingHyphen, with: "-")
        expect(!line.isHidden && words == reason, "the host window carries the probe's reason, got \(line.stringValue)")
        expect(line.textColor == CanvasDesign.warn.nsColor, "the reason is drawn in the warning colour")
        expect(
            line.font == loginLine.font && line.lineBreakMode == loginLine.lineBreakMode
                && line.maximumNumberOfLines == loginLine.maximumNumberOfLines,
            "the reason is set like the line under Open at login"
        )
        expect(
            arranged.firstIndex(of: line) == arranged.firstIndex(of: checkbox).map { $0 + 1 },
            "the reason sits directly beneath the Offer a private desktop switch"
        )
        expect(checkbox.state == .on, "the switch still shows what the person chose")

        let clear = window(HostOperatorStatus(connection: .hosting(address: "100.64.1.5"), permissions: granted))
        expect(
            stored("privateDesktopUnavailableLabel", in: clear, as: NSTextField.self).isHidden,
            "with no failed probe, there is no line under the switch"
        )
        print("PASS: the host window shows a failed private-desktop probe's reason in warning colour beneath the switch")
    }
}

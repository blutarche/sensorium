import AppKit
import Foundation
import SensoriumCore
import SensoriumHost

private final class RenamePresenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [HostPeerPresence] = []

    func record(_ peer: HostPeerPresence) {
        lock.lock()
        defer { lock.unlock() }
        seen.append(peer)
    }

    var events: [HostPeerPresence] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

private final class RecordingRenamePresenceGate: HostScreenPresenceGating, @unchecked Sendable {
    private(set) var calls: [HostScreenBadgeContent] = []

    func ask(content: HostScreenBadgeContent) -> HostScreenPresenceOutcome {
        calls.append(content)
        return .proceed
    }
}

@MainActor
private final class RenameBadgeDisplay: HostScreenBadgeDisplaying {
    func show() {}
    func hide() {}
}

private final class RenameRecentlyActiveSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading { .idleFor(0) }
}

/// The person at the host renaming a paired machine: what the host shows
/// for it everywhere, kept on this machine alone, and never overwritten by
/// the name the machine itself reports on the wire.
@MainActor
func runPairedMachineRenameTests() async {
    func temporaryURL(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-\(label)-\(UUID().uuidString).json")
    }

    func field<T>(_ name: String, of subject: Any, as type: T.Type) -> T {
        for child in Mirror(reflecting: subject).children {
            if child.label == name, let value = child.value as? T {
                return value
            }
        }
        fatalError("\(Swift.type(of: subject)) no longer has a stored property named \(name) of type \(T.self)")
    }

    /// A pairing service with `device` already paired under `reportedName`.
    func pairedService(
        device: DeviceIdentity,
        reportedName: String,
        store: any ApprovedDeviceStoring,
        onDeviceApproved: ((PairingApproval) -> Void)? = nil
    ) -> HostPairingService {
        let pairing = HostPairingService(
            hostIdentity: try! DeviceIdentity.generate(),
            approvedStore: store,
            onDeviceApproved: onDeviceApproved
        )
        pairing.issueCode(code: "424242")
        let signature = try! device.sign(SensoriumFrameCodec.pairRequestTranscript(
            deviceName: reportedName, clientPublicKey: device.publicKey, code: "424242"
        ))
        guard case .pairApproved = pairing.handlePairRequest(
            deviceName: reportedName, publicKey: device.publicKey, code: "424242", signature: signature
        ) else {
            fatalError("the fixture's own pairing was refused")
        }
        return pairing
    }

    func signedHello(_ device: DeviceIdentity, deviceName: String) -> SensoriumMessage {
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: deviceName, publicKey: device.publicKey, hostCertificateHash: nil
        )
        return .authenticatedHello(
            protocolVersion: 1, deviceName: deviceName, publicKey: device.publicKey,
            signature: try! device.sign(transcript)
        )
    }

    do {
        // The typed name is trimmed, capped, and an empty one means "no
        // name of my own" rather than a blank row.
        expect(PairedDeviceName.normalized("  Studio Laptop \n") == "Studio Laptop", "a typed name is trimmed")
        expect(PairedDeviceName.normalized("   ") == nil, "a name of only spaces is no name at all")
        expect(PairedDeviceName.normalized("") == nil, "an empty name is no name at all")
        let long = String(repeating: "a", count: 100)
        expect(
            PairedDeviceName.normalized(long) == String(repeating: "a", count: 64),
            "a name longer than the cap is cut to \(PairedDeviceName.maximumLength) characters"
        )
        expect(PairedDeviceName.maximumLength == 64, "the cap is 64 characters")
        let emoji = String(repeating: "\u{1F5A5}\u{FE0F}", count: 70)
        expect(
            PairedDeviceName.normalized(emoji)?.count == 64,
            "the cap counts characters a person sees, not bytes"
        )
        print("PASS: a typed device name is trimmed, capped at 64 characters, and empty means none")
    }

    do {
        // Rename persists on disk, apart from the reported name, and leaves
        // the key set and the file's owner-only permission alone.
        let url = temporaryURL("approved-devices-rename")
        defer { try? FileManager.default.removeItem(at: url) }
        let key = Data([0x01, 0x02])
        let store = FileApprovedDeviceStore(url: url)
        store.save([key])
        store.setName("Kestrel Laptop Pro", for: key)

        PairedDeviceName.rename(key, to: "  Studio Laptop  ", in: store)

        let reopened = FileApprovedDeviceStore(url: url)
        expect(reopened.customName(for: key) == "Studio Laptop", "a rename survives a fresh read of the file")
        expect(reopened.name(for: key) == "Kestrel Laptop Pro", "the reported name is kept alongside, untouched")
        expect(reopened.load() == [key], "renaming adds and removes no key")
        expect(
            ApprovedDeviceDisplayName.resolve(for: key, in: reopened) == "Studio Laptop",
            "the name this host shows is the one chosen here"
        )
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        expect(
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            "the approved-devices file stays owner-read-write only after a rename"
        )

        PairedDeviceName.rename(key, to: "   ", in: reopened)
        expect(reopened.customName(for: key) == nil, "an empty rename clears the chosen name")
        expect(
            ApprovedDeviceDisplayName.resolve(for: key, in: reopened) == "Kestrel Laptop Pro",
            "and the host goes back to the name the machine reported"
        )

        PairedDeviceName.rename(Data([0x09]), to: "Stranger", in: reopened)
        expect(
            reopened.load() == [key] && reopened.customName(for: Data([0x09])) == nil,
            "renaming a key that is not paired writes nothing and pairs nothing"
        )
        print("PASS: a rename persists apart from the reported name, and empty goes back to the reported name")
    }

    do {
        // A file written before chosen names existed decodes exactly as it
        // did, in both of its older shapes.
        let url = temporaryURL("approved-devices-old-shape")
        defer { try? FileManager.default.removeItem(at: url) }
        let named = Data([0x01])
        let unnamed = Data([0x02])
        let oldJSON = "[{\"publicKey\":\"\(named.base64EncodedString())\",\"name\":\"Kestrel Laptop Pro\"},"
            + "{\"publicKey\":\"\(unnamed.base64EncodedString())\"}]"
        try! oldJSON.write(to: url, atomically: true, encoding: .utf8)
        let store = FileApprovedDeviceStore(url: url)
        expect(store.load() == [named, unnamed], "an older file's keys all load")
        expect(store.name(for: named) == "Kestrel Laptop Pro", "an older file's reported name still reads")
        expect(
            store.customName(for: named) == nil && store.customName(for: unnamed) == nil,
            "an older file has no chosen names"
        )
        expect(
            ApprovedDeviceDisplayName.resolve(for: named, in: store) == "Kestrel Laptop Pro"
                && ApprovedDeviceDisplayName.resolve(for: unnamed, in: store)
                    == ApprovedDeviceDisplayName.fingerprint(of: unnamed),
            "and resolves to the same names it always did"
        )

        let legacyURL = temporaryURL("approved-devices-key-only")
        defer { try? FileManager.default.removeItem(at: legacyURL) }
        try! "[\"\(named.base64EncodedString())\"]".write(to: legacyURL, atomically: true, encoding: .utf8)
        let legacy = FileApprovedDeviceStore(url: legacyURL)
        expect(
            legacy.load() == [named] && legacy.name(for: named) == nil && legacy.customName(for: named) == nil,
            "a key-only file still loads with no names of either kind"
        )
        print("PASS: approved-devices files written before chosen names existed decode unchanged")
    }

    do {
        // Un-pairing forgets the chosen name with the key, so pairing again
        // later starts from the name the machine reports.
        for store in [InMemoryApprovedDeviceStore(), FileApprovedDeviceStore(url: temporaryURL("approved-devices-remove"))] as [any ApprovedDeviceStoring] {
            let key = Data([0x05])
            store.save([key])
            store.setName("Kestrel Laptop Pro", for: key)
            store.setCustomName("Studio Laptop", for: key)
            store.remove(key)
            expect(store.customName(for: key) == nil, "\(type(of: store)): removing a device forgets its chosen name")
        }
        print("PASS: removing a paired machine forgets the name chosen for it")
    }

    do {
        // Rename touches neither the arming record nor anything else that
        // grants access.
        let armingURL = temporaryURL("host-screen-arming-rename")
        defer { try? FileManager.default.removeItem(at: armingURL) }
        let key = Data([0x07])
        let store = InMemoryApprovedDeviceStore(keys: [key])
        store.setName("Kestrel Laptop Pro", for: key)
        let armingStore = HostScreenArmingStore(url: armingURL)
        let armedAt = Date(timeIntervalSince1970: 1_700_000_000)
        armingStore.arm(HostScreenDeviceArming(
            devicePublicKey: key, deviceName: "Kestrel Laptop Pro", armedAt: armedAt,
            asksWhenSomeoneIsUsingThisMachine: true
        ))
        let armingBefore = armingStore.load()
        let fingerprintBefore = HostScreenArmingFingerprint(armingBefore.devices[0])
        let armingBytesBefore = try! Data(contentsOf: armingURL)
        let writesBefore = armingStore.writeCount

        PairedDeviceName.rename(key, to: "Studio Laptop", in: store)

        expect(armingStore.writeCount == writesBefore, "a rename never writes the arming record")
        expect(try! Data(contentsOf: armingURL) == armingBytesBefore, "the arming file is byte-for-byte unchanged")
        expect(armingStore.load() == armingBefore, "arming reads back the same record")
        expect(
            HostScreenArmingFingerprint(armingStore.load().devices[0]) == fingerprintBefore,
            "the arming fingerprint a resume ticket is bound to is unchanged"
        )
        expect(store.load() == [key], "the approved key set is unchanged")
        print("PASS: renaming a machine leaves its key, its arming record and its fingerprint untouched")
    }

    do {
        // The name a machine reports on the wire never overwrites one chosen
        // here: not in a later hello, not when it pairs again.
        let device = try! DeviceIdentity.generate()
        let store = InMemoryApprovedDeviceStore()
        var approvals: [PairingApproval] = []
        let pairing = pairedService(
            device: device, reportedName: "Kestrel Laptop Pro", store: store,
            onDeviceApproved: { approvals.append($0) }
        )
        PairedDeviceName.rename(device.publicKey, to: "Studio Laptop", in: store)

        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            pairing: pairing,
            keyConfinement: .unconfined
        )
        _ = try! controller.handle(signedHello(device, deviceName: "Kestrel Laptop Air"))
        expect(store.name(for: device.publicKey) == "Kestrel Laptop Air", "a hello still updates the reported name")
        expect(store.customName(for: device.publicKey) == "Studio Laptop", "a hello never overwrites the chosen name")
        expect(
            ApprovedDeviceDisplayName.resolve(for: device.publicKey, in: store) == "Studio Laptop",
            "the host still shows the chosen name after a hello reporting another"
        )
        expect(
            controller.authenticatedDeviceDisplayName == "Studio Laptop",
            "the connection is named by the chosen name, not the hello's own"
        )

        pairing.issueCode(code: "515151")
        let signature = try! device.sign(SensoriumFrameCodec.pairRequestTranscript(
            deviceName: "Kestrel Laptop Max", clientPublicKey: device.publicKey, code: "515151"
        ))
        guard case .pairApproved = pairing.handlePairRequest(
            deviceName: "Kestrel Laptop Max", publicKey: device.publicKey, code: "515151", signature: signature
        ) else {
            fatalError("pairing again was refused")
        }
        expect(store.customName(for: device.publicKey) == "Studio Laptop", "pairing again never overwrites the chosen name")
        expect(store.name(for: device.publicKey) == "Kestrel Laptop Max", "pairing again still records the reported name")
        expect(
            approvals.last?.deviceName == "Studio Laptop",
            "the pairing status names a machine paired again by its chosen name -- got \(approvals.last?.deviceName ?? "nil")"
        )
        expect(approvals.first?.deviceName == "Kestrel Laptop Pro", "a first pairing has only the reported name to show")
        print("PASS: neither a hello nor pairing again overwrites a chosen name")
    }

    do {
        // The window, the menu bar and the host log name a connected machine
        // by its chosen name, not by the one its hello reports.
        let device = try! DeviceIdentity.generate()
        let store = InMemoryApprovedDeviceStore()
        let pairing = pairedService(device: device, reportedName: "Kestrel Laptop Pro", store: store)
        PairedDeviceName.rename(device.publicKey, to: "Studio Laptop", in: store)
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            pairing: pairing,
            keyConfinement: .unconfined
        )
        let channel = FakeHostByteChannel(scriptedMessages: [signedHello(device, deviceName: "Kestrel Laptop Air")])
        let presence = RenamePresenceRecorder()
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            onPeerPresence: { presence.record($0) }
        )
        session.start()
        let identified = await waitUntil(timeoutSeconds: 2) {
            presence.events.contains { if case .identified = $0 { return true } else { return false } }
        }
        expect(identified, "a verified hello identifies the connection")
        expect(
            presence.events.first == .identified(deviceName: "Studio Laptop"),
            "the connection is named by the chosen name -- got \(presence.events)"
        )
        session.stop()
        print("PASS: a connected machine is named by its chosen name, not its hello's own")
    }

    do {
        // A hello's name comes from the other machine. Before it reaches the
        // menu bar and the host log it loses its control and format
        // characters, and one with nothing left is named by the device's
        // key, as an unnamed paired machine is.
        let device = try! DeviceIdentity.generate()
        let store = InMemoryApprovedDeviceStore()
        let pairing = pairedService(device: device, reportedName: "Kestrel Laptop Pro", store: store)
        for (reported, expected) in [
            ("Kestrel\u{202E}\nLaptop\u{200B}", "Kestrel Laptop"),
            ("\u{202E}\u{200B}", ApprovedDeviceDisplayName.fingerprint(of: device.publicKey)),
        ] {
            let controller = HostSessionController(
                sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
                requireAuthentication: true,
                pairing: pairing,
                keyConfinement: .unconfined
            )
            let channel = FakeHostByteChannel(scriptedMessages: [signedHello(device, deviceName: reported)])
            let presence = RenamePresenceRecorder()
            let session = HostNetworkSession(
                connection: channel,
                controller: controller,
                onPeerPresence: { presence.record($0) }
            )
            session.start()
            let identified = await waitUntil(timeoutSeconds: 2) {
                presence.events.contains { if case .identified = $0 { return true } else { return false } }
            }
            expect(identified, "a verified hello identifies the connection")
            expect(
                presence.events.first == .identified(deviceName: expected),
                "a hello's name is cleaned before it is shown -- got \(presence.events), wanted \(expected)"
            )
            session.stop()
        }
        print("PASS: a hello's reported name is sanitized before the menu bar and host log show it")
    }

    do {
        // Arming never copies a chosen name into the arming record, so
        // clearing the name later shows the reported one everywhere again.
        let key = Data([0x0A])
        let store = InMemoryApprovedDeviceStore(keys: [key])
        store.setName("Kestrel Laptop Pro", for: key)
        PairedDeviceName.rename(key, to: "Studio Laptop", in: store)
        let armed = HostScreenDeviceArming.onPairing(devicePublicKey: key, approvedStore: store, now: Date())
        expect(
            armed.deviceName == "Kestrel Laptop Pro",
            "arming records the reported name, never a chosen one -- got \(armed.deviceName)"
        )
        PairedDeviceName.rename(key, to: "", in: store)
        let lines = HostScreenArmingPresentation.lines(
            for: HostScreenArming(devices: [armed]),
            hostChosenName: { store.customName(for: $0) }
        )
        expect(lines.map(\.deviceName) == ["Kestrel Laptop Pro"], "a cleared name shows the reported one after arming again")
        print("PASS: arming never keeps a chosen name, so clearing it takes effect everywhere")
    }

    do {
        // The menu bar's own line names a sharing machine by the chosen name.
        let key = Data([0xAB])
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(devicePublicKey: key, deviceName: "Kestrel Laptop Pro", armedAt: Date())
        ])
        let lines = HostScreenArmingPresentation.lines(for: arming, hostChosenName: { $0 == key ? "Studio Laptop" : nil })
        expect(lines.map(\.deviceName) == ["Studio Laptop"], "the menu bar names a sharing machine by its chosen name")
        expect(
            HostScreenArmingPresentation.lines(for: arming).map(\.deviceName) == ["Kestrel Laptop Pro"],
            "with no chosen name, the menu bar keeps the arming record's own name"
        )
        print("PASS: the menu bar names a sharing machine by its chosen name")
    }

    do {
        // The ask-first prompt, the indicator and the session record all name
        // the device by its chosen name, and the record keeps the reported
        // one alongside.
        let device = try! DeviceIdentity.generate()
        let store = InMemoryApprovedDeviceStore()
        let pairing = pairedService(device: device, reportedName: "Kestrel Laptop Pro", store: store)
        PairedDeviceName.rename(device.publicKey, to: "Studio Laptop", in: store)
        let display = DisplaySnapshot(
            id: 7, pixelWidth: 5120, pixelHeight: 2880, modeWidth: 2560, modeHeight: 1440,
            modePixelWidth: 5120, modePixelHeight: 2880, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            online: true, builtin: false, main: false, vendorNumber: 1552, modelNumber: 40
        )
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: device.publicKey, deviceName: "Kestrel Laptop Pro", armedAt: Date(),
                asksWhenSomeoneIsUsingThisMachine: true
            )
        ])
        let gate = RecordingRenamePresenceGate()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            inputInjectorFactory: FakeInputInjectorFactory(),
            pairing: pairing,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceActivitySignal: RenameRecentlyActiveSignal(),
            hostScreenPresenceGate: gate
        )
        _ = try! controller.handle(signedHello(device, deviceName: "Kestrel Laptop Air"))
        guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList(), let entry = displays.first else {
            fatalError("the fixture offers no display")
        }
        let response = try! controller.handle(.hostScreenRequest(token: entry.opaqueToken, resumeTicket: nil))
        guard case .hostScreenReady = response else {
            fatalError("the fixture's host-screen request was refused: \(response)")
        }
        expect(gate.calls.first?.deviceName == "Studio Laptop", "the ask-first prompt names the chosen name")
        expect(controller.hostScreenDeviceName == "Studio Laptop", "the indicator and session record name the chosen name")
        expect(
            controller.hostScreenReportedDeviceName == "Kestrel Laptop Air",
            "the session record can keep the name the machine reported alongside -- got \(controller.hostScreenReportedDeviceName ?? "nil")"
        )

        let logURL = temporaryURL("host-screen-sessions-rename")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let log = HostScreenSessionLogStore(url: logURL)
        let media = HostScreenAccountableMedia(
            rawFactory: { _, _ in FakeScalableCanvasMedia() },
            sessionLog: log,
            deviceName: { controller.hostScreenDeviceName ?? "" },
            reportedDeviceName: { controller.hostScreenReportedDeviceName },
            displayLabel: { controller.hostScreenDisplayLabel ?? "" },
            onBadgeStop: {},
            badgeFactory: { _, _ in RenameBadgeDisplay() }
        )
        _ = media.makeMedia(.fullHiDPI, displayID: 7)
        expect(media.badgeState?.content.deviceName == "Studio Laptop", "the live indicator names the chosen name")
        expect(log.lastRecord?.deviceName == "Studio Laptop", "the session record names the chosen name")
        expect(log.lastRecord?.reportedDeviceName == "Kestrel Laptop Air", "and keeps the reported name alongside")
        await media.stop()
        print("PASS: the ask-first prompt, the live indicator and the session record name the chosen name")
    }

    do {
        // Session records written before the reported name was kept decode
        // unchanged, and a record with none writes no extra key.
        let logURL = temporaryURL("host-screen-sessions-old-shape")
        defer { try? FileManager.default.removeItem(at: logURL) }
        let oldJSON = """
        [{"id":"\(UUID().uuidString)","deviceName":"Kestrel Laptop Pro","displayLabel":"Built-in Display","startedAt":0}]
        """
        try! oldJSON.write(to: logURL, atomically: true, encoding: .utf8)
        let log = HostScreenSessionLogStore(url: logURL)
        expect(log.records().count == 1, "an older session record still reads")
        expect(log.lastRecord?.deviceName == "Kestrel Laptop Pro", "with its device name as written")
        expect(log.lastRecord?.reportedDeviceName == nil, "and no reported name")
        print("PASS: older session records decode unchanged")
    }

    do {
        // Each paired row offers Rename beside Remove; pressing it asks for a
        // new name for exactly that row's machine, starting from the name it
        // shows, and the typed name is handed on for that same machine.
        let rowKey = Data([0xAB])
        var prompted: [String] = []
        var finishPrompt: ((String) -> Void)?
        var renamed: [(Data, String)] = []
        let controller = HostSetupWindowController(
            status: HostOperatorStatus(
                connection: .notHosting,
                permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
            ),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in },
            onRenamePairedDevice: { key, typed in renamed.append((key, typed)) },
            presentRenamePrompt: { _, currentName, onRename in
                prompted.append(currentName)
                finishPrompt = onRename
            }
        )
        controller.updatePairedMachines([
            HostScreenArmingPresentation.PairedMachineRow(
                devicePublicKey: Data([0x01]), deviceName: "Kestrel Laptop Air", isSharingRealScreen: false
            ),
            HostScreenArmingPresentation.PairedMachineRow(
                devicePublicKey: rowKey, deviceName: "Studio Laptop", isSharingRealScreen: true
            )
        ])
        let pairedMachines: NSView = field("pairedMachines", of: controller, as: NSView.self)
        let rowsStack: NSStackView = field("rowsStack", of: pairedMachines, as: NSStackView.self)
        let row = rowsStack.arrangedSubviews[1]
        let renameButton: NSButton = field("renameButton", of: row, as: NSButton.self)
        let removeButton: NSButton = field("removeButton", of: row, as: NSButton.self)
        expect(renameButton.attributedTitle.string == "Rename", "the row's button reads Rename")
        expect(renameButton.superview === removeButton.superview, "Rename sits on the same line as Remove")
        expect(
            renameButton.layer?.borderColor == removeButton.layer?.borderColor
                && renameButton.layer?.backgroundColor == removeButton.layer?.backgroundColor,
            "Rename is drawn the same way as Remove"
        )
        renameButton.performClick(nil)
        expect(prompted == ["Studio Laptop"], "Rename opens the prompt with this row's current name")
        finishPrompt?("Living Room")
        expect(
            renamed.count == 1 && renamed[0].0 == rowKey && renamed[0].1 == "Living Room",
            "the typed name is handed on for this row's machine"
        )
        print("PASS: each paired row offers Rename beside Remove, for exactly its own machine")
    }

    do {
        // A machine with no name shows "Unnamed machine" as its title. That
        // is not a name to keep, so Rename opens on an empty field, and
        // confirming it empty means "use the name the machine reports".
        var prompted: [String] = []
        let controller = HostSetupWindowController(
            status: HostOperatorStatus(
                connection: .notHosting,
                permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
            ),
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in },
            presentRenamePrompt: { _, currentName, _ in prompted.append(currentName) }
        )
        controller.updatePairedMachines(
            HostScreenArmingPresentation.pairedMachineRows(
                approvedDevices: [(Data([0x01, 0x02, 0x03, 0x04]), nil)],
                arming: HostScreenArming()
            )
        )
        let pairedMachines: NSView = field("pairedMachines", of: controller, as: NSView.self)
        let rowsStack: NSStackView = field("rowsStack", of: pairedMachines, as: NSStackView.self)
        let renameButton: NSButton = field("renameButton", of: rowsStack.arrangedSubviews[0], as: NSButton.self)
        renameButton.performClick(nil)
        expect(prompted == [""], "Rename on an unnamed machine opens on an empty field -- got \(prompted)")
        print("PASS: renaming an unnamed machine starts from an empty field, not the placeholder title")
    }

    do {
        // The rename sheet: prefilled, Rename on Return, Cancel on Escape.
        var confirmed: [String] = []
        var cancelled = 0
        let sheet = PairedMachineRenameView(
            currentName: "Studio Laptop",
            onRename: { confirmed.append($0) },
            onCancel: { cancelled += 1 }
        )
        let textField: NSTextField = field("nameField", of: sheet, as: NSTextField.self)
        let renameButton: NSButton = field("renameButton", of: sheet, as: NSButton.self)
        let cancelButton: NSButton = field("cancelButton", of: sheet, as: NSButton.self)
        expect(textField.stringValue == "Studio Laptop", "the field starts with the current name")
        expect(renameButton.title == "Rename" && renameButton.keyEquivalent == "\r", "Rename is the default, on Return")
        expect(cancelButton.title == "Cancel" && cancelButton.keyEquivalent == "\u{1b}", "Cancel answers Escape")

        textField.stringValue = "Living Room"
        renameButton.performClick(nil)
        expect(confirmed == ["Living Room"], "Rename hands back what was typed")
        cancelButton.performClick(nil)
        expect(cancelled == 1 && confirmed.count == 1, "Cancel hands back nothing")
        print("PASS: the rename sheet starts with the current name, confirms on Return and cancels on Escape")
    }
}

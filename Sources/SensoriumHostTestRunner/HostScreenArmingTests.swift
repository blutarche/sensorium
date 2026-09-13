import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

@MainActor
func runHostScreenArmingTests() async {
    do {
        // Round-trip through a temporary directory: a fresh store reads back
        // the empty default, arming and disarming both persist, and a
        // second store instance at the same URL sees what the first wrote.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-host-screen-arming-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostScreenArmingStore(url: url)
        expect(store.load() == HostScreenArming(), "a store with nothing written reads back as empty, not an error")

        let key = Data([0x01, 0x02, 0x03, 0x04])
        let device = HostScreenDeviceArming(
            devicePublicKey: key,
            deviceName: "Device 01020304",
            armedDisplays: [HostScreenDisplayIdentity(vendorNumber: 1552, modelNumber: 40)],
            credentialKind: .hardwareBound,
            minimumCredentialStrength: .hardwareBound,
            armedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        store.arm(device)
        let reopened = HostScreenArmingStore(url: url)
        expect(
            reopened.load() == HostScreenArming(devices: [device]),
            "a second store instance at the same URL reads back exactly what the first wrote"
        )

        store.arm(device)
        expect(
            store.load().devices.count == 1,
            "re-arming the same device key replaces its record instead of accumulating a second one"
        )

        store.disarm(devicePublicKey: key)
        expect(store.load() == HostScreenArming(), "disarming removes the device's own record and nothing else was ever added")
        store.disarm(devicePublicKey: key)
        expect(store.load() == HostScreenArming(), "disarming a device that is not armed is not an error")

        print("PASS: HostScreenArmingStore round-trips arm and disarm through a temporary directory, and re-arming replaces rather than duplicates")
    }

    do {
        // Host-set only (design §2.1): nothing about handling an ordinary
        // message can reach this store, because the controller is never
        // handed a reference to it in the first place. One instance of
        // every `SensoriumMessage` case is fed through a real controller;
        // the store's write count must never move.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-host-screen-arming-writecount-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostScreenArmingStore(url: url)
        let identity = try! DeviceIdentity.generate()
        let adapter = FakeVirtualDisplayAdapter()
        let session = VirtualDisplaySession(adapter: adapter)
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(session),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1,
            deviceName: "Probe",
            publicKey: identity.publicKey
        )
        let everyMessage: [SensoriumMessage] = [
            .hello(protocolVersion: 1, deviceName: "Probe"),
            .authenticatedHello(
                protocolVersion: 1,
                deviceName: "Probe",
                publicKey: identity.publicKey,
                signature: try! identity.sign(transcript)
            ),
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
            .canvasReady(displayID: 1, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil),
            .canvasRefused(reason: "test", surfaceID: nil),
            .input(.key(keyCode: 0, isDown: true, modifiers: CanvasModifierFlags()), surfaceID: nil),
            .goodbye(reason: "test"),
            .pairRequest(deviceName: "Probe", publicKey: identity.publicKey, code: "000000"),
            .pairApproved(hostPublicKey: identity.publicKey, tlsCertificateHash: nil, signature: nil),
            .pairRejected(reason: "test"),
            .timeSyncRequest(clientTimeNanoseconds: 0),
            .timeSyncReply(clientTimeNanoseconds: 0, hostTimeNanoseconds: 0),
            .viewerDrawableSize(pixelWidth: 1920, pixelHeight: 1200, surfaceID: nil, maximumScale: nil),
            .streamScalePreference(.automatic, surfaceID: nil),
            .displayCount(1),
            .viewerFocus(surfaceID: nil, hasViewerFocus: true),
            .telemetry(surfaces: []),
            .hostScreenList(displays: [], challenge: Data([0x01])),
            .hostScreenRequest(token: Data([0x02]), presence: .resumeTicket(Data([0x03]))),
            .hostScreenReady(
                geometry: SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1200, backingScale: 2.0),
                resumeTicket: Data([0x04])
            ),
            .hostScreenRefused(reason: "test"),
            .unrecognized(type: "future-message")
        ]
        for message in everyMessage {
            _ = try? controller.handle(message)
        }
        expect(
            store.writeCount == 0,
            "feeding one of every SensoriumMessage case through the session controller never writes the arming store -- it holds no reference to write through"
        )

        print("PASS: the arming store's write count stays zero no matter what a session controller does with a wire message")
    }

    do {
        // Design §2.2: removing a paired device removes its arming with it.
        // Same pattern `HostScreenArmingCoordinator.removePairedDevice`
        // uses in sensoriumd -- both calls, in order.
        let approvedURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-approved-devices-test-\(UUID().uuidString).json")
        let armingURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-host-screen-arming-remove-test-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: approvedURL)
            try? FileManager.default.removeItem(at: armingURL)
        }
        let approvedStore = FileApprovedDeviceStore(url: approvedURL)
        let armingStore = HostScreenArmingStore(url: armingURL)
        let key = Data([0x0A, 0x0B])
        let otherKey = Data([0x0C, 0x0D])
        approvedStore.save([key, otherKey])
        armingStore.arm(HostScreenDeviceArming(
            devicePublicKey: key,
            deviceName: "Device 0A0B",
            armedDisplays: [],
            armedAt: Date()
        ))
        armingStore.arm(HostScreenDeviceArming(
            devicePublicKey: otherKey,
            deviceName: "Device 0C0D",
            armedDisplays: [],
            armedAt: Date()
        ))

        approvedStore.remove(key)
        armingStore.revoke(devicePublicKey: key)

        expect(
            approvedStore.load() == [otherKey],
            "removing a paired device removes exactly that device's approval, not the other one"
        )
        expect(
            armingStore.load().devices.map(\.devicePublicKey) == [otherKey],
            "removing a paired device removes exactly that device's arming, not the other one"
        )

        print("PASS: removing a paired device removes its own approval and its own arming, and no other device's")
    }

    do {
        // `ApprovedDeviceStoring.remove` itself, in isolation: the gap
        // design §2.2 names, since there was no revocation API at all.
        let inMemory = InMemoryApprovedDeviceStore(keys: [Data([1]), Data([2])])
        inMemory.remove(Data([1]))
        expect(inMemory.load() == [Data([2])], "ApprovedDeviceStoring.remove removes exactly the named key")
        inMemory.remove(Data([9]))
        expect(inMemory.load() == [Data([2])], "removing a key that was never approved is not an error")

        print("PASS: ApprovedDeviceStoring gained a working remove(_:), the revocation API the design names as missing")
    }

    do {
        // The idle presentation: what the menu bar and the Host Setup
        // window both read to decide what to show, and the one place their
        // words come from.
        expect(
            HostScreenArmingPresentation.lines(for: HostScreenArming()).isEmpty,
            "nothing armed is nothing shown -- a host with no armed device looks exactly as it did before this feature existed"
        )

        let armed = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: Data([0xAB]),
                deviceName: "Kestrel MacBook Pro",
                armedDisplays: [HostScreenDisplayIdentity(vendorNumber: 1552, modelNumber: 40)],
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        let lines = HostScreenArmingPresentation.lines(for: armed)
        expect(
            lines.count == 1 && lines[0].deviceName == "Kestrel MacBook Pro"
                && lines[0].credentialSummary == "Presence key on Kestrel MacBook Pro: reported as hardware-held.",
            "the idle presentation names the armed device and says how its key is held in plain words, not a raw enum case"
        )
        let armedWithSoftwareKey = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: Data([0xAC]),
                deviceName: "Kestrel MacBook Air",
                armedDisplays: [HostScreenDisplayIdentity(vendorNumber: 1552, modelNumber: 40)],
                minimumCredentialStrength: .softwarePresence,
                armedAt: Date()
            )
        ])
        expect(
            HostScreenArmingPresentation.lines(for: armedWithSoftwareKey)[0].credentialSummary
                == "Presence key on Kestrel MacBook Air: reported as software-held.",
            "a key the operating system holds is told apart from one that cannot leave the device, and says what that costs"
        )

        let unregistered = HostScreenArmingPresentation.lines(for: HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: Data([0xCD]),
                deviceName: "Unregistered Device",
                armedDisplays: [],
                armedAt: Date()
            )
        ]))
        expect(
            unregistered[0].credentialSummary == nil,
            // Not the device's name and not an internal-state phrase glued
            // onto it -- `nil` is the honest report, and it is what the
            // window and the menu bar are what makes it plain words on the
            // caller's own line: see HostScreenArmingPresentation.noCredentialNotice.
            "a device armed before it has ever registered a presence credential reports no credential summary at all, not a blank string or a crash"
        )
        let unregisteredNotice = HostScreenArmingPresentation.noCredentialNotice(deviceName: "Unregistered Device")
        expect(
            !unregisteredNotice.contains("credential") && unregisteredNotice.contains("Unregistered Device"),
            "the shared notice names the device it is about, not \"This machine\" -- that word already means the host "
                + "everywhere else a row like this one appears -- and says what is missing in plain words, never "
                + "\"credential\" -- got: \(unregisteredNotice)"
        )
        expect(
            unregisteredNotice
                == "Pair Unregistered Device again to turn this on.",
            "the remedy names which machine to act from -- the unregistered device, not this one -- got: \(unregisteredNotice)"
        )

        print("PASS: the idle arming presentation names every armed device and its reported credential strength honestly, including before one is ever registered")
    }

    do {
        // The design's whole point here: the name a device gave at
        // pairing is what a person sees later, not a fingerprint of its key
        // -- see `ApprovedDeviceDisplayName`.
        let key = Data([0xAA, 0xBB, 0xCC, 0xDD])
        let inMemory = InMemoryApprovedDeviceStore(keys: [key])
        expect(
            inMemory.name(for: key) == nil,
            "a key approved with no name recorded reads back with none, not an empty string"
        )
        inMemory.setName("Kestrel MacBook Pro", for: key)
        expect(
            inMemory.name(for: key) == "Kestrel MacBook Pro",
            "a name set for a key reads back exactly as set"
        )
        expect(
            ApprovedDeviceDisplayName.resolve(for: key, in: inMemory) == "Kestrel MacBook Pro",
            "the resolved display name is the recorded one when there is one"
        )
        let unnamedKey = Data([0x5D, 0xB7, 0x42, 0xA2, 0x01])
        expect(
            ApprovedDeviceDisplayName.resolve(for: unnamedKey, in: inMemory) == "Machine 5DB742A2",
            "a key with no recorded name falls back to a short hex fingerprint of the key itself"
        )
        inMemory.remove(key)
        expect(
            inMemory.name(for: key) == nil,
            "removing a device's approval forgets its name too, so a later key reuse never resurrects a stale one"
        )

        print("PASS: ApprovedDeviceDisplayName resolves the name recorded at pairing, and falls back to a key fingerprint only when none was ever recorded")
    }

    do {
        // `FileApprovedDeviceStore`'s on-disk shape has a name field, but a
        // file without it -- a plain array of base64 keys -- must still
        // load, with every key reading back with no name, exactly as
        // `ApprovedDeviceDisplayName` then falls back on.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-approved-devices-legacy-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let key = Data([0x01, 0x02])
        let legacyJSON = "[\"\(key.base64EncodedString())\"]"
        try! legacyJSON.write(to: url, atomically: true, encoding: .utf8)

        let store = FileApprovedDeviceStore(url: url)
        expect(
            store.load() == [key],
            "a pre-existing key-only store file still loads its keys"
        )
        expect(
            store.name(for: key) == nil,
            "a key from a pre-existing store file has no recorded name"
        )

        store.setName("Kestrel MacBook Pro", for: key)
        let reopened = FileApprovedDeviceStore(url: url)
        expect(
            reopened.load() == [key] && reopened.name(for: key) == "Kestrel MacBook Pro",
            "setting a name on a legacy record upgrades the file in place, keeping the key and adding the name"
        )

        print("PASS: FileApprovedDeviceStore reads a pre-name store file as every key with no name, and can then record one")
    }

    do {
        // Security review: a registered presence credential's own public
        // key lives in this file (`StoredDevice.presenceCredential`) --
        // owner-only, the same as `HostScreenArmingStore`'s own file.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-approved-devices-permissions-test-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileApprovedDeviceStore(url: url)
        store.setName("Kestrel MacBook Pro", for: Data([0x01]))
        let attributes = try! FileManager.default.attributesOfItem(atPath: url.path)
        expect(
            (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            "the approved-devices file is written owner-read-write only, not group- or world-readable"
        )

        print("PASS: FileApprovedDeviceStore writes its file 0600")
    }

    do {
        // docs/ux-spec.md's "Paired machines": one row per approved device,
        // whether or not it is currently sharing a host screen -- unlike
        // `HostScreenArmingPresentation.lines`, which only ever names the
        // armed ones.
        let sharingKey = Data([0xAB])
        let unarmedKey = Data([0xCD])
        let approvedDevices: [(publicKey: Data, name: String?, credentialStrength: HostScreenCredentialStrength?)] = [
            (sharingKey, "Kestrel MacBook Pro", .hardwareBound),
            (unarmedKey, "Kestrel MacBook Air", nil)
        ]
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: sharingKey,
                deviceName: "Kestrel MacBook Pro",
                armedDisplays: [],
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        let rows = HostScreenArmingPresentation.pairedMachineRows(approvedDevices: approvedDevices, arming: arming)
        expect(
            rows.count == 2 && rows[0].deviceName == "Kestrel MacBook Pro" && rows[1].deviceName == "Kestrel MacBook Air",
            "every paired machine gets its own row, in the order it was given, whether or not it is sharing a host screen"
        )
        expect(
            rows[0].isSharingRealScreen && rows[0].blockedReason == nil
                && rows[0].credentialSummary == "Presence key on Kestrel MacBook Pro: reported as hardware-held.",
            "a device armed with a registered credential is shown as sharing, with nothing blocking it"
        )
        expect(
            !rows[1].isSharingRealScreen
                && rows[1].blockedReason == HostScreenArmingPresentation.noCredentialNotice(deviceName: "Kestrel MacBook Air"),
            "a paired device that has never registered a credential cannot be turned on yet, and the row says why, naming the paired device rather than \"This machine\""
        )

        let neverPaired = HostScreenArmingPresentation.pairedMachineRows(approvedDevices: [], arming: HostScreenArming())
        expect(neverPaired.isEmpty, "no paired machine is no rows, not a placeholder row")

        print("PASS: pairedMachineRows lists every paired machine with its own sharing state, credential summary, and why sharing is blocked when it is")
    }

    do {
        // The card title is the name a device gave, never a fingerprint of
        // its key -- and when a name is known, the key becomes a small
        // secondary line instead of disappearing, so two machines someone
        // named alike can still be told apart. A device with no recorded
        // name keeps the fingerprint as its title, exactly as
        // `ApprovedDeviceDisplayName` already falls back, and gets no
        // second line repeating the same fingerprint underneath it.
        let namedKey = Data([0x5D, 0xB7, 0x42, 0xA2, 0x01])
        let unnamedKey = Data([0x5D, 0xB7, 0x42, 0xA2, 0x02])
        expect(
            ApprovedDeviceDisplayName.hex(of: namedKey) == "5DB742A2",
            "hex(of:) is the bare key fingerprint, with no \u{201c}Device \u{201d} prefix"
        )
        expect(
            ApprovedDeviceDisplayName.fingerprint(of: namedKey) == "Machine " + ApprovedDeviceDisplayName.hex(of: namedKey),
            "fingerprint(of:) is still built from the same hex helper other callers can now use on its own"
        )
        let rows = HostScreenArmingPresentation.pairedMachineRows(
            approvedDevices: [
                (namedKey, "kestrel-mbp", nil),
                (unnamedKey, nil, nil)
            ],
            arming: HostScreenArming()
        )
        expect(
            rows[0].deviceName == "kestrel-mbp" && rows[0].keyFingerprintLine == "Key 5DB742A2",
            "a named device's title is the name it gave, with its key fingerprint on a small secondary line -- got title \(rows[0].deviceName), line \(rows[0].keyFingerprintLine ?? "nil")"
        )
        expect(
            rows[1].deviceName == "Machine 5DB742A2" && rows[1].keyFingerprintLine == nil,
            "a device with no recorded name keeps the fingerprint as its title, and gets no redundant second line -- got title \(rows[1].deviceName), line \(rows[1].keyFingerprintLine ?? "nil")"
        )

        print("PASS: a paired-machine row is titled by name with the fingerprint beneath, or by fingerprint alone when no name is known")
    }

    do {
        // An armed row carrying a strength snapshot: its own summary
        // reflects what was armed, never a stronger credential registered
        // afterward -- and a row without a snapshot reports why in words
        // that do not falsely claim no credential was ever registered.
        let armedKey = Data([0x11])
        let legacyKey = Data([0x22])
        let approvedDevices: [(publicKey: Data, name: String?, credentialStrength: HostScreenCredentialStrength?)] = [
            (armedKey, "Kestrel MacBook Pro", .softwarePresence),
            (legacyKey, "Kestrel iMac", .hardwareBound)
        ]
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: armedKey,
                deviceName: "Kestrel MacBook Pro",
                armedDisplays: [],
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            ),
            HostScreenDeviceArming(
                devicePublicKey: legacyKey,
                deviceName: "Kestrel iMac",
                armedDisplays: [],
                armedAt: Date()
            )
        ])
        let rows = HostScreenArmingPresentation.pairedMachineRows(approvedDevices: approvedDevices, arming: arming)
        expect(
            rows[0].isSharingRealScreen
                && rows[0].blockedReason == nil
                && rows[0].credentialSummary == "Presence key on Kestrel MacBook Pro: reported as hardware-held.",
            "an armed row reports the strength it was armed at, not whatever is registered live now (here, a weaker one)"
        )
        expect(
            rows[1].isSharingRealScreen
                && rows[1].credentialSummary == nil
                && rows[1].blockedReason == HostScreenArmingPresentation.needsRearmingNotice,
            "a row armed before the snapshot existed reports needsRearmingNotice, not noCredentialNotice -- it did register something, this machine just never captured it"
        )
        expect(
            HostScreenArmingPresentation.needsRearmingNotice
                == "How this machine holds its presence key was not recorded when it paired. Turn Share host screen off and on again to record it.",
            "needsRearmingNotice says what happened and what to do about it in plain words -- not "
                + "\u{201c}This machine\u{2019}s credential was recorded before this machine tracked how it is held,\u{201d} "
                + "which uses \u{201c}this machine\u{201d} for two different machines in the same sentence -- "
                + "got: \(HostScreenArmingPresentation.needsRearmingNotice)"
        )

        print("PASS: an armed row summarises the strength snapshotted at arm time, and a row without one asks for re-arming")
    }

    do {
        // Item 5, decided without a picker: the row shows what the
        // person already granted -- naming the displays an armed
        // device may capture, matched against this machine's own
        // currently active displays for their human labels. Never
        // shown for a row that is not sharing.
        let builtin = DisplaySnapshot(
            id: 1, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            builtin: true, main: true, vendorNumber: 0x01, modelNumber: 0x01
        )
        let external = DisplaySnapshot(
            id: 2, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            builtin: false, main: false, vendorNumber: 0x02, modelNumber: 0x02
        )
        let secondExternal = DisplaySnapshot(
            id: 3, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            builtin: false, main: false, vendorNumber: 0x03, modelNumber: 0x03
        )
        let unplugged = DisplaySnapshot(
            id: 4, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            builtin: false, main: false, vendorNumber: 0x99, modelNumber: 0x99
        )

        func row(armedDisplays: [HostScreenDisplayIdentity], activeDisplays: [DisplaySnapshot]) -> HostScreenArmingPresentation.PairedMachineRow {
            let key = Data([0xEE])
            let arming = HostScreenArming(devices: [
                HostScreenDeviceArming(
                    devicePublicKey: key,
                    deviceName: "Kestrel MacBook Pro",
                    armedDisplays: armedDisplays,
                    minimumCredentialStrength: .hardwareBound,
                    armedAt: Date()
                )
            ])
            let rows = HostScreenArmingPresentation.pairedMachineRows(
                approvedDevices: [(key, "Kestrel MacBook Pro", .hardwareBound)],
                arming: arming,
                activeDisplays: activeDisplays
            )
            return rows[0]
        }

        expect(
            row(armedDisplays: [HostScreenDisplayIdentity(builtin)], activeDisplays: [builtin]).sharedDisplaysLine
                == "May share Built-in Display.",
            "one armed display reads as a single-item sentence, not a list of one -- and as permission, not as a "
                + "live share, since this row shows whether or not a machine is connected"
        )
        expect(
            row(armedDisplays: [HostScreenDisplayIdentity(builtin), HostScreenDisplayIdentity(external)], activeDisplays: [builtin, external]).sharedDisplaysLine
                == "May share Built-in Display and External Display.",
            "two armed displays join with a plain \u{201c}and\u{201d}, no Oxford comma yet"
        )
        expect(
            row(
                armedDisplays: [HostScreenDisplayIdentity(builtin), HostScreenDisplayIdentity(external), HostScreenDisplayIdentity(secondExternal)],
                activeDisplays: [builtin, external, secondExternal]
            ).sharedDisplaysLine == "May share Built-in Display, External Display (2), and External Display (3).",
            "three or more armed displays read as an Oxford-style list, and the two same-named externals here (identical size, identical position) fall back to telling them apart by id"
        )
        expect(
            row(armedDisplays: [], activeDisplays: []).sharedDisplaysLine == nil,
            "a device armed for no display shows no line rather than an empty sentence"
        )
        expect(
            row(armedDisplays: [HostScreenDisplayIdentity(unplugged)], activeDisplays: [builtin]).sharedDisplaysLine == nil,
            "an armed display this machine cannot currently see is left out rather than guessed at, and an empty result hides the line entirely"
        )

        let unarmed = HostScreenArmingPresentation.pairedMachineRows(
            approvedDevices: [(Data([0xFF]), "Kestrel MacBook Air", nil)],
            arming: HostScreenArming(),
            activeDisplays: [builtin]
        )
        expect(
            unarmed[0].sharedDisplaysLine == nil,
            "a row that is not sharing never shows a shared-displays line, whatever displays are currently active"
        )

        print("PASS: an armed row names the displays it may capture among the active ones, and an unshared row shows none")
    }

    do {
        // Two displays sharing this machine's own generic name ("External
        // Display" for both) must still be told apart in the sentence that
        // names them -- design order: pixel size first, then where the
        // display sits relative to the main display, and only when both of
        // those tie as well, the display's own id.
        let mainDisplay = DisplaySnapshot(
            id: 1, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
            modePixelWidth: 1920, modePixelHeight: 1080, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            online: true, builtin: true, main: true, vendorNumber: 0x01, modelNumber: 0x01
        )
        let fourK = DisplaySnapshot(
            id: 2, pixelWidth: 3840, pixelHeight: 2160, modeWidth: 3840, modeHeight: 2160,
            modePixelWidth: 3840, modePixelHeight: 2160, bounds: CGRect(x: 1920, y: 0, width: 3840, height: 2160),
            online: true, builtin: false, main: false, vendorNumber: 0x02, modelNumber: 0x02
        )
        let fullHD = DisplaySnapshot(
            id: 3, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
            modePixelWidth: 1920, modePixelHeight: 1080, bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            online: true, builtin: false, main: false, vendorNumber: 0x03, modelNumber: 0x03
        )
        let leftExternal = DisplaySnapshot(
            id: 4, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
            modePixelWidth: 1920, modePixelHeight: 1080, bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
            online: true, builtin: false, main: false, vendorNumber: 0x04, modelNumber: 0x04
        )
        let rightExternal = DisplaySnapshot(
            id: 5, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
            modePixelWidth: 1920, modePixelHeight: 1080, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            online: true, builtin: false, main: false, vendorNumber: 0x05, modelNumber: 0x05
        )
        let stackedA = DisplaySnapshot(
            id: 6, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
            modePixelWidth: 1920, modePixelHeight: 1080, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            online: true, builtin: false, main: false, vendorNumber: 0x06, modelNumber: 0x06
        )
        let stackedB = DisplaySnapshot(
            id: 7, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
            modePixelWidth: 1920, modePixelHeight: 1080, bounds: CGRect(x: 1920, y: 0, width: 1920, height: 1080),
            online: true, builtin: false, main: false, vendorNumber: 0x07, modelNumber: 0x07
        )

        func sharingRow(armedDisplays: [DisplaySnapshot], activeDisplays: [DisplaySnapshot]) -> HostScreenArmingPresentation.PairedMachineRow {
            let key = Data([0xFA])
            let arming = HostScreenArming(devices: [
                HostScreenDeviceArming(
                    devicePublicKey: key,
                    deviceName: "Kestrel MacBook Pro",
                    armedDisplays: armedDisplays.map(HostScreenDisplayIdentity.init),
                    minimumCredentialStrength: .hardwareBound,
                    armedAt: Date()
                )
            ])
            return HostScreenArmingPresentation.pairedMachineRows(
                approvedDevices: [(key, "Kestrel MacBook Pro", .hardwareBound)],
                arming: arming,
                activeDisplays: activeDisplays
            )[0]
        }

        expect(
            sharingRow(armedDisplays: [fourK, fullHD], activeDisplays: [mainDisplay, fourK, fullHD]).sharedDisplaysLine
                == "May share External Display (3840\u{00d7}2160) and External Display (1920\u{00d7}1080).",
            "two same-named displays of different pixel size are told apart by size first"
        )
        expect(
            sharingRow(armedDisplays: [leftExternal, rightExternal], activeDisplays: [mainDisplay, leftExternal, rightExternal]).sharedDisplaysLine
                == "May share External Display (left) and External Display (right).",
            "two same-named, same-size displays are told apart by where they sit relative to the main display"
        )
        expect(
            sharingRow(armedDisplays: [stackedA, stackedB], activeDisplays: [mainDisplay, stackedA, stackedB]).sharedDisplaysLine
                == "May share External Display (6) and External Display (7).",
            "two same-named, same-size, same-position displays are told apart by id as a last resort"
        )
        expect(
            sharingRow(armedDisplays: [fourK], activeDisplays: [mainDisplay, fourK]).sharedDisplaysLine
                == "May share External Display.",
            "a display whose name nothing else shares keeps the plain sentence, with no disambiguator appended"
        )

        print("PASS: sharedDisplaysLine tells two identically-named displays apart by pixel size, then position, then id, leaving a lone display's name alone")
    }

    do {
        // The pairing ceremony already records the name a device gives.
        // This closes the remaining gap: a device approved before its name
        // was ever recorded, or one whose owner renamed it
        // afterward, gets its stored name written or corrected the moment
        // it proves it holds that key again on an ordinary authenticated
        // hello -- never from an unproven claim, only after
        // `HostSessionController` has already verified the signature.
        let hostIdentity = try! DeviceIdentity.generate()
        let device = try! DeviceIdentity.generate()
        let approvedStore = InMemoryApprovedDeviceStore(keys: [device.publicKey])
        let pairing = HostPairingService(hostIdentity: hostIdentity, approvedStore: approvedStore)
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            pairing: pairing,
            keyConfinement: .unconfined
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1,
            deviceName: "Kestrel MacBook Pro",
            publicKey: device.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1,
            deviceName: "Kestrel MacBook Pro",
            publicKey: device.publicKey,
            signature: try! device.sign(transcript)
        ))
        expect(
            approvedStore.name(for: device.publicKey) == "Kestrel MacBook Pro",
            "an already-approved device with no recorded name gets one the moment it authenticates, not only at the pairing ceremony"
        )

        let renameStore = InMemoryApprovedDeviceStore(keys: [device.publicKey])
        renameStore.setName("Old Name", for: device.publicKey)
        let renamePairing = HostPairingService(hostIdentity: hostIdentity, approvedStore: renameStore)
        let renameController = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            pairing: renamePairing,
            keyConfinement: .unconfined
        )
        let renameTranscript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1,
            deviceName: "New Name",
            publicKey: device.publicKey
        )
        _ = try! renameController.handle(.authenticatedHello(
            protocolVersion: 1,
            deviceName: "New Name",
            publicKey: device.publicKey,
            signature: try! device.sign(renameTranscript)
        ))
        expect(
            renameStore.name(for: device.publicKey) == "New Name",
            "a later authenticated hello with a different name updates the stored one"
        )

        print("PASS: authenticatedHello records or corrects an already-approved device's stored name")
    }

    do {
        // macOS's own name for a display (`NSScreen.localizedName`, read
        // into `DisplaySnapshot.name` by `DisplayInventory`) replaces the
        // generic kind label wherever this machine names one, so two
        // external monitors of different models read as themselves in both
        // the Share host screen rows and the viewer's Screen menu -- not
        // both as "External Display."
        let named = DisplaySnapshot(
            id: 10, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            builtin: false, main: false, vendorNumber: 0x0A, modelNumber: 0x0A,
            name: "MPG321UX OLED"
        )
        let unnamedExternal = DisplaySnapshot(
            id: 11, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            builtin: false, main: false, vendorNumber: 0x0B, modelNumber: 0x0B
        )
        expect(
            HostScreenArmingPresentation.displayLabel(for: named) == "MPG321UX OLED",
            "a display macOS named reads by that name, not by its kind"
        )
        expect(
            HostScreenArmingPresentation.displayLabel(for: unnamedExternal) == "External Display",
            "a display macOS could not name still falls back to its kind, unchanged"
        )

        let firstOfSameModel = DisplaySnapshot(
            id: 12, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            builtin: false, main: false, vendorNumber: 0x0C, modelNumber: 0x0C,
            name: "LS27A800U"
        )
        let secondOfSameModel = DisplaySnapshot(
            id: 13, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            builtin: false, main: false, vendorNumber: 0x0D, modelNumber: 0x0D,
            name: "LS27A800U"
        )
        expect(
            HostScreenArmingPresentation.displayLabels(for: [firstOfSameModel, secondOfSameModel])
                == ["LS27A800U", "LS27A800U (2)"],
            "two displays macOS gave the identical name are told apart by offer order, the first plain and the second suffixed -- never by size or position, which a name collision may share too"
        )
        expect(
            HostScreenArmingPresentation.displayLabels(for: [named, unnamedExternal])
                == ["MPG321UX OLED", "External Display"],
            "a named display never collides with an unnamed one's generic kind label"
        )

        let key = Data([0xFB])
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: key,
                deviceName: "Kestrel MacBook Pro",
                armedDisplays: [firstOfSameModel, secondOfSameModel].map(HostScreenDisplayIdentity.init),
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        let rows = HostScreenArmingPresentation.pairedMachineRows(
            approvedDevices: [(key, "Kestrel MacBook Pro", .hardwareBound)],
            arming: arming,
            activeDisplays: [firstOfSameModel, secondOfSameModel]
        )
        expect(
            rows[0].sharedDisplaysLine == "May share LS27A800U and LS27A800U (2).",
            "the Share host screen row's own sentence carries the same name-collision suffix"
        )

        print("PASS: displayLabel and displayLabels name a display by what macOS calls it, told apart by offer order when two share that name")
    }

    do {
        // Per-machine "ask me first": arming a machine is itself the
        // consent this feature needs, so the prompt defaults off,
        // including for a record without this field.
        let key = Data([0x01, 0x02, 0x03, 0x04])
        let legacyJSON = """
        {"devices":[{"devicePublicKey":"\(key.base64EncodedString())",\
        "deviceName":"Kestrel MacBook Pro","armedDisplays":[],"armedAt":719000000}]}
        """
        let decoded = try! JSONDecoder().decode(HostScreenArming.self, from: legacyJSON.data(using: .utf8)!)
        expect(
            decoded.devices[0].asksWhenSomeoneIsUsingThisMachine == false,
            "a record written before this field existed decodes with the prompt off, not a decoding error"
        )

        let device = HostScreenDeviceArming(
            devicePublicKey: key,
            deviceName: "Kestrel MacBook Pro",
            armedDisplays: [],
            armedAt: Date(timeIntervalSince1970: 1_700_000_000),
            asksWhenSomeoneIsUsingThisMachine: true
        )
        let encoded = try! JSONEncoder().encode(HostScreenArming(devices: [device]))
        let roundTripped = try! JSONDecoder().decode(HostScreenArming.self, from: encoded)
        expect(
            roundTripped.devices[0].asksWhenSomeoneIsUsingThisMachine == true,
            "a record armed with the prompt on round-trips through encode and decode with it still on"
        )

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-host-screen-arming-asks-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostScreenArmingStore(url: url)
        store.arm(HostScreenDeviceArming(devicePublicKey: key, deviceName: "Kestrel MacBook Pro", armedDisplays: [], armedAt: Date()))
        let writesBefore = store.writeCount
        store.setAsksWhenInUse(devicePublicKey: key, true)
        expect(
            store.load().devices[0].asksWhenSomeoneIsUsingThisMachine == true,
            "the store setter persists the flag against the one existing record"
        )
        expect(store.writeCount == writesBefore + 1, "the store setter bumps writeCount, the same as arm and disarm")

        let fingerprintOff = HostScreenArmingFingerprint(HostScreenDeviceArming(
            devicePublicKey: key, deviceName: "Kestrel MacBook Pro", armedDisplays: [],
            armedAt: Date(timeIntervalSince1970: 1_700_000_000), asksWhenSomeoneIsUsingThisMachine: false
        ))
        let fingerprintOn = HostScreenArmingFingerprint(HostScreenDeviceArming(
            devicePublicKey: key, deviceName: "Kestrel MacBook Pro", armedDisplays: [],
            armedAt: Date(timeIntervalSince1970: 1_700_000_000), asksWhenSomeoneIsUsingThisMachine: true
        ))
        expect(
            fingerprintOff != fingerprintOn,
            "a resume ticket minted under one setting of the flag is refused once the flag changes, the same as every other arming field"
        )

        print("PASS: the ask-first flag defaults off, round-trips through the store, and is part of the resume ticket's fingerprint")
    }

    do {
        // PairedMachineRow carries the flag and the shared checkbox
        // label an armed row's own sharing state reads from.
        let key = Data([0xEE, 0x01])
        let approvedDevices: [(publicKey: Data, name: String?, credentialStrength: HostScreenCredentialStrength?)] = [
            (key, "Kestrel MacBook Pro", .hardwareBound)
        ]
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: key,
                deviceName: "Kestrel MacBook Pro",
                armedDisplays: [],
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date(),
                asksWhenSomeoneIsUsingThisMachine: true
            )
        ])
        let rows = HostScreenArmingPresentation.pairedMachineRows(approvedDevices: approvedDevices, arming: arming)
        expect(rows[0].asksWhenInUse, "an armed row carries the arming record's own ask-first flag")
        expect(
            HostScreenArmingPresentation.asksWhenInUseLabel == "Ask me first if this machine is in use",
            "the checkbox label is shared so the Host Setup window and a test read the exact same words"
        )

        print("PASS: pairedMachineRows carries each armed row's own ask-first flag, and the checkbox label is a single shared constant")
    }

    do {
        // A row with nothing to share says why, on its own line, the same
        // reason `offerHostScreenList` would log for the same display --
        // never a second window, and never shown alongside a real
        // sharedDisplaysLine, since there is nothing left unexplained then.
        let mirrored = DisplaySnapshot(
            id: 1, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            builtin: false, main: false, vendorNumber: 0x50, modelNumber: 0x50
        )
        let absentIdentity = HostScreenDisplayIdentity(vendorNumber: 0x99, modelNumber: 0x99)
        let key = Data([0xFC])
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: key,
                deviceName: "Kestrel MacBook Pro",
                armedDisplays: [absentIdentity],
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ])
        let rows = HostScreenArmingPresentation.pairedMachineRows(
            approvedDevices: [(key, "Kestrel MacBook Pro", .hardwareBound)],
            arming: arming,
            activeDisplays: [mirrored]
        )
        expect(rows[0].sharedDisplaysLine == nil, "nothing armed matches an active display, so there is still no shared-displays line")
        expect(
            rows[0].notOfferedReason
                == "Cannot currently share Display \(absentIdentity.wireStableIdentifier): not online.",
            "the row explains the gap in the same words offerHostScreenList would log -- got: \(rows[0].notOfferedReason ?? "nil")"
        )

        let actuallyMirrored = DisplaySnapshot(
            id: 5, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            mirrorsDisplay: 7, builtin: false, main: false, vendorNumber: 0x52, modelNumber: 0x52
        )
        let mirroredRow = HostScreenArmingPresentation.pairedMachineRows(
            approvedDevices: [(Data([0xFB]), "Kestrel MacBook Air", .hardwareBound)],
            arming: HostScreenArming(devices: [
                HostScreenDeviceArming(
                    devicePublicKey: Data([0xFB]),
                    deviceName: "Kestrel MacBook Air",
                    armedDisplays: [HostScreenDisplayIdentity(actuallyMirrored)],
                    minimumCredentialStrength: .hardwareBound,
                    armedAt: Date()
                )
            ]),
            activeDisplays: [actuallyMirrored]
        )[0]
        expect(mirroredRow.sharedDisplaysLine == nil, "a mirror secondary is never actually shareable, so the row shows no shared-displays line for it")
        expect(
            mirroredRow.notOfferedReason == "Cannot currently share External Display: mirrored.",
            "an armed display that is now a mirror secondary reads as mirrored, not as merely gone -- got: \(mirroredRow.notOfferedReason ?? "nil")"
        )

        let actuallyAsleep = DisplaySnapshot(
            id: 6, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            asleep: true, builtin: false, main: false, vendorNumber: 0x53, modelNumber: 0x53
        )
        let sleepingRow = HostScreenArmingPresentation.pairedMachineRows(
            approvedDevices: [(Data([0xFA]), "Kestrel Studio Display", .hardwareBound)],
            arming: HostScreenArming(devices: [
                HostScreenDeviceArming(
                    devicePublicKey: Data([0xFA]),
                    deviceName: "Kestrel Studio Display",
                    armedDisplays: [HostScreenDisplayIdentity(actuallyAsleep)],
                    minimumCredentialStrength: .hardwareBound,
                    armedAt: Date()
                )
            ]),
            activeDisplays: [actuallyAsleep]
        )[0]
        expect(sleepingRow.sharedDisplaysLine == nil, "a sleeping display is never actually shareable, so the row shows no shared-displays line for it")
        expect(
            sleepingRow.notOfferedReason == "Cannot currently share External Display: asleep.",
            "an armed display that is only asleep right now reads as asleep, not as merely gone -- got: \(sleepingRow.notOfferedReason ?? "nil")"
        )

        let sharingRow = HostScreenArmingPresentation.pairedMachineRows(
            approvedDevices: [(Data([0xFD]), "Kestrel MacBook Air", .hardwareBound)],
            arming: HostScreenArming(devices: [
                HostScreenDeviceArming(
                    devicePublicKey: Data([0xFD]),
                    deviceName: "Kestrel MacBook Air",
                    armedDisplays: [HostScreenDisplayIdentity(mirrored)],
                    minimumCredentialStrength: .hardwareBound,
                    armedAt: Date()
                )
            ]),
            activeDisplays: [mirrored]
        )[0]
        expect(
            sharingRow.sharedDisplaysLine != nil && sharingRow.notOfferedReason == nil,
            "a row with something real to share never also carries a not-offered reason"
        )

        let unarmedRow = HostScreenArmingPresentation.pairedMachineRows(
            approvedDevices: [(Data([0xFE]), "Kestrel iMac", nil)],
            arming: HostScreenArming(),
            activeDisplays: [mirrored]
        )[0]
        expect(unarmedRow.notOfferedReason == nil, "a row that is not sharing carries no not-offered reason either")

        print("PASS: a row with nothing shareable names the same reason offerHostScreenList would log, only when it is sharing and armed for something")
    }

    do {
        // The owner's decision: pairing itself arms host screen, when the
        // pairing device registered a presence credential, for every
        // display present at that moment that Sensorium did not create.
        // `HostScreenArmingCoordinator.toggle(isOn: true)` in `sensoriumd`
        // builds through this exact function, so the two paths cannot
        // drift.
        let key = Data([0x77])
        let approvedStore = InMemoryApprovedDeviceStore(keys: [key])
        approvedStore.setName("Kestrel MacBook Pro", for: key)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let builtin = DisplaySnapshot(
            id: 1, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            builtin: true, main: true, vendorNumber: 0x01, modelNumber: 0x01
        )
        let canvas = DisplaySnapshot(
            id: 2, pixelWidth: 1, pixelHeight: 1, modeWidth: 1, modeHeight: 1,
            modePixelWidth: 1, modePixelHeight: 1, bounds: .zero, online: true,
            builtin: false, main: false, vendorNumber: CanvasDisplayIdentity.vendorID, modelNumber: 0x02
        )

        expect(
            HostScreenDeviceArming.onPairing(
                devicePublicKey: key, approvedStore: approvedStore, displays: [builtin, canvas], now: now
            ) == nil,
            "a device with no registered presence credential is not armed at pairing -- it may still pair and use a session canvas"
        )

        approvedStore.setPresenceCredential(
            PresenceCredentialRecord(
                credentialID: Data([0x01]),
                publicKey: Data([0x02]),
                credentialFormat: "test-format",
                strength: .hardwareBound
            ),
            for: key
        )
        let armed = HostScreenDeviceArming.onPairing(
            devicePublicKey: key, approvedStore: approvedStore, displays: [builtin, canvas], now: now
        )
        expect(
            armed?.armedDisplays == [HostScreenDisplayIdentity(builtin)],
            "a device with a registered presence credential is armed for every display present at pairing that Sensorium did not create -- got \(armed?.armedDisplays ?? [])"
        )
        expect(
            armed?.deviceName == "Kestrel MacBook Pro" && armed?.minimumCredentialStrength == .hardwareBound
                && armed?.asksWhenSomeoneIsUsingThisMachine == false && armed?.armedAt == now,
            "the built record names the device by the name it gave at pairing, snapshots the strength it registered, defaults asking-first off, and stamps the moment it was armed -- got \(String(describing: armed))"
        )

        print("PASS: HostScreenDeviceArming.onPairing arms a device for every non-Sensorium display present at pairing, only when it registered a presence credential")
    }
}

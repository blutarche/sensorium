import Dispatch
import Foundation
import SensoriumCore
import SensoriumHost

/// The approved-devices store is written from the connection thread (a
/// hello's reported name), the pairing ceremony and the host window (rename,
/// remove) at once. No write may undo another, and nothing but pairing may
/// put a key on the list.
@MainActor
func runApprovedDeviceStoreSafetyTests() async {
    func temporaryURL(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-\(label)-\(UUID().uuidString).json")
    }

    func pair(
        _ device: DeviceIdentity,
        as deviceName: String,
        with pairing: HostPairingService,
        code: String
    ) -> SensoriumMessage {
        pairing.issueCode(code: code)
        let signature = try! device.sign(SensoriumFrameCodec.pairRequestTranscript(
            deviceName: deviceName, clientPublicKey: device.publicKey, code: code
        ))
        return pairing.handlePairRequest(
            deviceName: deviceName, publicKey: device.publicKey, code: code, signature: signature
        )
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
        // A reported name and a chosen name written at the same moment from
        // different threads both land.
        for round in 0..<5 {
            let url = temporaryURL("approved-devices-concurrent-\(round)")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = FileApprovedDeviceStore(url: url)
            let keys = (0..<32).map { Data([0xC0, UInt8($0)]) }
            store.save(Set(keys))
            DispatchQueue.concurrentPerform(iterations: keys.count * 2) { index in
                let key = keys[index / 2]
                if index.isMultiple(of: 2) {
                    store.setName("Reported \(index / 2)", for: key)
                } else {
                    store.setCustomName("Chosen \(index / 2)", for: key)
                }
            }
            let reopened = FileApprovedDeviceStore(url: url)
            let lost = keys.enumerated().filter { offset, key in
                reopened.name(for: key) != "Reported \(offset)" || reopened.customName(for: key) != "Chosen \(offset)"
            }
            expect(
                lost.isEmpty && reopened.load() == Set(keys),
                "concurrent name writes all survive (round \(round)) -- \(lost.count) of \(keys.count) devices lost a name"
            )
        }
        print("PASS: concurrent reported-name and chosen-name writes lose neither update")
    }

    do {
        // Removing a device while its hello is still recording a name never
        // brings the key back.
        for round in 0..<5 {
            let url = temporaryURL("approved-devices-remove-race-\(round)")
            defer { try? FileManager.default.removeItem(at: url) }
            let store = FileApprovedDeviceStore(url: url)
            let key = Data([0xD0, UInt8(round)])
            let other = Data([0xD1])
            store.save([key, other])
            DispatchQueue.concurrentPerform(iterations: 64) { index in
                if index == 16 {
                    store.remove(key)
                } else {
                    store.setName("Kestrel Laptop \(index)", for: key)
                }
            }
            let reopened = FileApprovedDeviceStore(url: url)
            expect(
                reopened.load() == [other],
                "a removed key stays removed under concurrent name writes (round \(round)) -- got \(reopened.load().count) keys"
            )
            expect(reopened.name(for: key) == nil, "and keeps no name (round \(round))")
        }
        print("PASS: a device removed while its name is being written stays removed")
    }

    do {
        // Only pairing adds a key: a name for a key not on the list writes
        // nothing, in either store.
        let url = temporaryURL("approved-devices-unknown-name")
        defer { try? FileManager.default.removeItem(at: url) }
        let known = Data([0xE0])
        let stranger = Data([0xE1])
        for store in [InMemoryApprovedDeviceStore(keys: [known]), FileApprovedDeviceStore(url: url)] as [any ApprovedDeviceStoring] {
            store.save([known])
            store.setName("Stranger", for: stranger)
            store.setCustomName("Stranger", for: stranger)
            expect(store.load() == [known], "\(type(of: store)): naming an unknown key adds no key")
            expect(
                store.name(for: stranger) == nil && store.customName(for: stranger) == nil,
                "\(type(of: store)): and records no name for it"
            )
        }
        let reopened = FileApprovedDeviceStore(url: url)
        expect(reopened.load() == [known], "the file holds only the paired key")
        print("PASS: naming a key that is not paired adds nothing")
    }

    do {
        // Pairing still records the name a new device gives, on disk.
        let url = temporaryURL("approved-devices-pairing-name")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = FileApprovedDeviceStore(url: url)
        let pairing = HostPairingService(hostIdentity: try! DeviceIdentity.generate(), approvedStore: store)
        let device = try! DeviceIdentity.generate()
        guard case .pairApproved = pair(device, as: "Kestrel Laptop Pro", with: pairing, code: "424242") else {
            fatalError("the fixture's own pairing was refused")
        }
        let reopened = FileApprovedDeviceStore(url: url)
        expect(reopened.load() == [device.publicKey], "pairing records the key")
        expect(reopened.name(for: device.publicKey) == "Kestrel Laptop Pro", "pairing records the name the device gave")
        print("PASS: pairing a new device still records its name")
    }

    do {
        // A reported name is cleaned before it is stored or shown; one with
        // nothing left after cleaning is refused at pairing.
        let store = InMemoryApprovedDeviceStore()
        var approvals: [PairingApproval] = []
        let pairing = HostPairingService(
            hostIdentity: try! DeviceIdentity.generate(),
            approvedStore: store,
            onDeviceApproved: { approvals.append($0) }
        )
        let blank = try! DeviceIdentity.generate()
        let refused = pair(blank, as: "\u{202E}\u{200B}\u{0007}", with: pairing, code: "111111")
        expect(
            refused == .pairRejected(reason: "invalid-request"),
            "a name of only control and format characters is refused at pairing -- got \(refused)"
        )
        expect(store.load().isEmpty && approvals.isEmpty, "and pairs nothing")

        let device = try! DeviceIdentity.generate()
        let hostile = "Kestrel\u{202E}\n" + String(repeating: "x", count: 10_000)
        guard case .pairApproved = pair(device, as: hostile, with: pairing, code: "222222") else {
            fatalError("a long name with a bidi override was refused instead of cleaned")
        }
        let cleaned = DeviceName.sanitized(hostile)
        expect(cleaned?.count == 64 && cleaned?.hasPrefix("Kestrel x") == true, "the fixture's cleaned name is capped")
        expect(store.name(for: device.publicKey) == cleaned, "pairing stores the cleaned name")
        expect(approvals.last?.deviceName == cleaned, "the pairing status shows the cleaned name")

        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            pairing: pairing,
            keyConfinement: .unconfined
        )
        _ = try! controller.handle(signedHello(device, deviceName: "Kestrel\u{2066}\tAir"))
        expect(
            store.name(for: device.publicKey) == "Kestrel Air",
            "a hello stores its cleaned name -- got \(store.name(for: device.publicKey) ?? "nil")"
        )

        let second = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            pairing: pairing,
            keyConfinement: .unconfined
        )
        var helloError: Error?
        do {
            _ = try second.handle(signedHello(device, deviceName: "\u{202E}\u{200B}"))
        } catch {
            helloError = error
        }
        expect(helloError == nil, "a hello whose name cleans to nothing still authenticates -- got \(String(describing: helloError))")
        expect(
            store.name(for: device.publicKey) == "Kestrel Air",
            "and keeps the name stored before it"
        )
        print("PASS: a reported name is cleaned at pairing and in a hello, and an empty one is refused or ignored")
    }

    do {
        // A hostile name already on disk is cleaned when it is read.
        let url = temporaryURL("approved-devices-hostile-on-disk")
        defer { try? FileManager.default.removeItem(at: url) }
        let key = Data([0xF0])
        let encodedName = "Kestrel\\u202E\\nLaptop" + String(repeating: "y", count: 200)
        let json = "[{\"publicKey\":\"\(key.base64EncodedString())\",\"name\":\"\(encodedName)\","
            + "\"customName\":\"Studio\\u200B\\u2066Mac\"}]"
        try! json.write(to: url, atomically: true, encoding: .utf8)
        let store = FileApprovedDeviceStore(url: url)
        let name = store.name(for: key)
        expect(
            name?.count == 64 && name?.hasPrefix("Kestrel Laptop") == true,
            "a stored reported name is cleaned on read -- got \(name ?? "nil")"
        )
        expect(store.customName(for: key) == "StudioMac", "a stored chosen name is cleaned on read")
        expect(
            ApprovedDeviceDisplayName.resolve(for: key, in: store) == "StudioMac",
            "and the host shows the cleaned name"
        )
        print("PASS: a hostile name already stored on disk is cleaned when read")
    }

    do {
        // A hostile name already in the arming record is cleaned when read.
        let url = temporaryURL("arming-hostile-on-disk")
        defer { try? FileManager.default.removeItem(at: url) }
        let keys = [Data([0xA1]), Data([0xA2]), Data([0xA3])]
        let names = [
            "Kestrel\\u202E\\nLaptop",
            String(repeating: "z", count: 10_000),
            "\\u202E\\u200B",
        ]
        let entries = zip(keys, names).map { key, name in
            "{\"devicePublicKey\":\"\(key.base64EncodedString())\",\"deviceName\":\"\(name)\","
                + "\"armedAt\":0,\"asksWhenSomeoneIsUsingThisMachine\":true}"
        }
        let json = "{\"devices\":[\(entries.joined(separator: ","))],\"everyPairedMachineArmed\":true}"
        try! json.write(to: url, atomically: true, encoding: .utf8)
        let loaded = HostScreenArmingStore(url: url).load()
        expect(loaded.devices.count == 3, "the hostile arming file still decodes -- got \(loaded.devices.count)")
        let read = loaded.devices.map(\.deviceName)
        expect(read.first == "Kestrel Laptop", "a bidi override and newline are cleaned on read -- got \(read.first ?? "nil")")
        expect(read.dropFirst().first == String(repeating: "z", count: 64), "a 10 000 character name is capped on read")
        expect(
            read.last == ApprovedDeviceDisplayName.fingerprint(of: keys[2]),
            "a name that cleans to nothing falls back to the key fingerprint -- got \(read.last ?? "nil")"
        )
        expect(loaded.devices.allSatisfy(\.asksWhenSomeoneIsUsingThisMachine), "other fields are untouched")
        print("PASS: a hostile name already in the arming record is cleaned when read")
    }

    do {
        // The host's own rename goes through the same rule.
        expect(
            PairedDeviceName.normalized("Studio\u{202E}\nMac") == "Studio Mac",
            "a typed host-side name is cleaned the same way"
        )
        expect(PairedDeviceName.maximumLength == DeviceName.maximumLength, "the host shares the one cap")
        print("PASS: a host-side rename uses the shared name rule")
    }
}

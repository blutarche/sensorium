import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// `HostConnectionSessionFactory` is what `sensoriumd` actually constructs
/// once per process and shares across every connection -- these two tests
/// exercise its own host-screen pass-through, built the same way `sensoriumd`
/// builds it (a real `HostScreenArmingStore` reading a real file, a real
/// `HostScreenResumeTicketStore`, and no presence-proof verifier), rather
/// than `HostSessionController`'s constructor directly, so a regression in
/// the factory's forwarding is caught here even if `HostSessionController`'s
/// own admission tests stay green.
private final class FakeProductionWiringLocalActivitySignal: HostLocalActivitySignal, @unchecked Sendable {
    var reading: HostLocalActivityReading = .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    func currentReading() -> HostLocalActivityReading { reading }
}

@MainActor
private func wiringTestDisplay(id: UInt32) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 5120,
        pixelHeight: 2880,
        modeWidth: 2560,
        modeHeight: 1440,
        modePixelWidth: 5120,
        modePixelHeight: 2880,
        bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

@MainActor
private func temporaryArmingStoreURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-host-screen-wiring-test-\(UUID().uuidString).json")
}

@MainActor
private func temporaryApprovedDeviceStoreURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-approved-devices-wiring-test-\(UUID().uuidString).json")
}

/// Stands in for `HostScreenBadgeWindowController`: records `show`/`hide`
/// without ever opening a real `NSPanel`, so every test below can assert
/// the badge was genuinely shown and hidden -- not just that `badgeState`
/// happens to be non-`nil` -- while staying exactly as window-server-free
/// as `HostScreenIndicationTests.swift`'s own "construct, never show()"
/// boundary already is.
@MainActor
private final class FakeHostScreenBadgeDisplaying: HostScreenBadgeDisplaying {
    private(set) var showCount = 0
    private(set) var hideCount = 0

    func show() { showCount += 1 }
    func hide() { hideCount += 1 }
}

@MainActor
private func temporaryHostScreenSessionLogURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-host-screen-session-log-wiring-test-\(UUID().uuidString).json")
}

/// Registers `signingKey`'s public half for `devicePublicKey` the only way
/// this codebase ever writes one -- through `HostPairingService`'s own
/// pairing ceremony (design §6.3/CLAUDE.md: "a new credential ... can only
/// ever reach this host through the pairing ceremony"), not by writing to
/// `approvedDeviceStore` directly.
@MainActor
private func registerThroughPairing(
    approvedDeviceStore: FileApprovedDeviceStore,
    devicePublicKey: Data,
    deviceName: String,
    credentialID: Data,
    signingKey: P256.Signing.PrivateKey,
    strength: HostScreenCredentialStrength
) {
    let hostIdentity = try! DeviceIdentity.generate()
    let pairing = HostPairingService(hostIdentity: hostIdentity, approvedStore: approvedDeviceStore)
    let code = pairing.issueCode()
    let reply = pairing.handlePairRequest(
        deviceName: deviceName,
        publicKey: devicePublicKey,
        code: code,
        presenceCredential: PresenceCredentialRegistration(
            credentialID: credentialID,
            publicKey: signingKey.publicKey.rawRepresentation,
            credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
            strength: strength.rawValue
        )
    )
    guard case .pairApproved = reply else {
        expect(false, "pairing with a freshly issued code and a well-formed credential registration approves")
        return
    }
}

/// Mirrors `HostScreenArmingCoordinator.toggle(isOn: true)`'s own snapshot
/// line exactly (`Sources/sensoriumd/main.swift`) -- that type is `private`
/// inside an executable target and cannot be imported here, so this is the
/// closest thing to exercising it directly: the same one-line read from
/// `approvedStore.presenceCredential(for:)?.strength`, written into
/// `minimumCredentialStrength` at arm time rather than left `nil`.
@MainActor
private func armThroughCoordinator(
    armingStore: HostScreenArmingStore,
    approvedStore: any ApprovedDeviceStoring,
    devicePublicKey: Data,
    deviceName: String,
    armedDisplays: [HostScreenDisplayIdentity]
) {
    armingStore.arm(HostScreenDeviceArming(
        devicePublicKey: devicePublicKey,
        deviceName: deviceName,
        armedDisplays: armedDisplays,
        minimumCredentialStrength: approvedStore.presenceCredential(for: devicePublicKey)?.strength,
        armedAt: Date()
    ))
}

@MainActor
func runHostScreenProductionWiringTests() async {
    do {
        // A fresh launch, nothing ever armed, wired exactly as
        // sensoriumd wires it.
        let armingURL = temporaryArmingStoreURL()
        defer { try? FileManager.default.removeItem(at: armingURL) }
        let armingStore = HostScreenArmingStore(url: armingURL)
        let resumeTicketStore = HostScreenResumeTicketStore()
        let signal = FakeProductionWiringLocalActivitySignal()
        let display = wiringTestDisplay(id: 21)
        let injectorFactory = FakeInputInjectorFactory()
        let identity = try! DeviceIdentity.generate()

        let factory = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: injectorFactory,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { armingStore.load() },
            hostScreenPreSessionSnapshotProvider: { [display] },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: nil,
            hostScreenResumeTicketStore: resumeTicketStore,
            hostScreenLocalActivitySignal: signal
        )
        let controller = factory.makeController()
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))
        let response = try! controller.handle(.hostScreenRequest(
            token: Data([0x01]),
            presence: .signed(credentialID: Data([0x02]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x03]))
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-not-allowed"),
            "a fresh HostConnectionSessionFactory backed by an empty arming store refuses a host-screen request, exactly as a fresh sensoriumd launch with nothing ever armed would"
        )
        expect(injectorFactory.requestedDisplayIDs.isEmpty, "no arming record: no injector is ever built")
        expect(injectorFactory.injector.events.isEmpty, "no arming record: nothing is ever asked of the display")

        print("PASS: an empty arming store refuses a host-screen request and creates no injector, as a fresh launch would")
    }

    do {
        // An armed device, but no presence-proof verifier: refuses,
        // and the refusal names the verifier, not the arming.
        let armingURL = temporaryArmingStoreURL()
        defer { try? FileManager.default.removeItem(at: armingURL) }
        let armingStore = HostScreenArmingStore(url: armingURL)
        let display = wiringTestDisplay(id: 22)
        let identity = try! DeviceIdentity.generate()
        armingStore.arm(HostScreenDeviceArming(
            devicePublicKey: identity.publicKey,
            deviceName: "Kestrel MacBook Pro",
            armedDisplays: [HostScreenDisplayIdentity(display)],
            armedAt: Date()
        ))
        let resumeTicketStore = HostScreenResumeTicketStore()
        let signal = FakeProductionWiringLocalActivitySignal()
        let injectorFactory = FakeInputInjectorFactory()

        let factory = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: injectorFactory,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { armingStore.load() },
            hostScreenPreSessionSnapshotProvider: { [display] },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: nil,
            hostScreenResumeTicketStore: resumeTicketStore,
            hostScreenLocalActivitySignal: signal
        )
        let controller = factory.makeController()
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))
        guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList(), let entry = displays.first else {
            expect(false, "an armed device with an eligible display offers at least one entry")
            return
        }
        let response = try! controller.handle(.hostScreenRequest(
            token: entry.opaqueToken,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-credential-unknown"),
            "an armed device with every obligation held except the verifier refuses on the verifier's own absence, not on the arming record it genuinely has"
        )
        expect(injectorFactory.requestedDisplayIDs.isEmpty, "verifier absent: no injector is ever built")

        print("PASS: an armed device with no presence-proof verifier configured is refused on the verifier, not the arming")
    }

    do {
        // The real verifier, over the real credential a real pairing
        // ceremony registered: a genuine signature is admitted.
        let approvedDeviceStore = FileApprovedDeviceStore(url: temporaryApprovedDeviceStoreURL())
        let armingStore = HostScreenArmingStore(url: temporaryArmingStoreURL())
        let display = wiringTestDisplay(id: 23)
        let deviceIdentity = try! DeviceIdentity.generate()
        let credentialID = Data([0x07])
        let signingKey = P256.Signing.PrivateKey()
        registerThroughPairing(
            approvedDeviceStore: approvedDeviceStore,
            devicePublicKey: deviceIdentity.publicKey,
            deviceName: "Kestrel MacBook Pro",
            credentialID: credentialID,
            signingKey: signingKey,
            strength: .hardwareBound
        )
        // Armed at or below what was actually registered -- design §6.3's
        // own minimum check, satisfied rather than sidestepped.
        armingStore.arm(HostScreenDeviceArming(
            devicePublicKey: deviceIdentity.publicKey,
            deviceName: "Kestrel MacBook Pro",
            armedDisplays: [HostScreenDisplayIdentity(display)],
            minimumCredentialStrength: .hardwareBound,
            armedAt: Date()
        ))

        let factory = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [deviceIdentity.publicKey],
            requireAuthentication: true,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { armingStore.load() },
            hostScreenPreSessionSnapshotProvider: { [display] },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: PresenceCredentialVerifier(approvedDeviceStore: approvedDeviceStore),
            hostScreenResumeTicketStore: HostScreenResumeTicketStore(),
            hostScreenLocalActivitySignal: FakeProductionWiringLocalActivitySignal()
        )
        let controller = factory.makeController()
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Kestrel MacBook Pro", publicKey: deviceIdentity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Kestrel MacBook Pro", publicKey: deviceIdentity.publicKey,
            signature: try! deviceIdentity.sign(transcript)
        ))
        guard case let .hostScreenList(displays, challenge) = try! controller.offerHostScreenList(), let entry = displays.first else {
            expect(false, "an armed, credentialed device with an eligible display offers at least one entry")
            return
        }
        let genuineSignature = try! signingKey.signature(for: challenge)
        let admitted = try! controller.handle(.hostScreenRequest(
            token: entry.opaqueToken,
            presence: .signed(credentialID: credentialID, credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat, signature: genuineSignature.rawRepresentation)
        ))
        expect(
            { if case .hostScreenReady = admitted { return true } else { return false } }(),
            "a device paired with a credential registered the only way this codebase ever registers one -- through HostPairingService itself -- and signing the minted challenge with the matching private key, is admitted through the exact objects sensoriumd constructs"
        )

        print("PASS: a credential registered at pairing, signed over the minted challenge, is admitted end to end")
    }

    do {
        // The same device and arming, but the challenge is signed
        // with a different private key: refused, and the cause
        // names the verifier, not the arming or the display.
        let approvedDeviceStore = FileApprovedDeviceStore(url: temporaryApprovedDeviceStoreURL())
        let armingStore = HostScreenArmingStore(url: temporaryArmingStoreURL())
        let display = wiringTestDisplay(id: 24)
        let deviceIdentity = try! DeviceIdentity.generate()
        let credentialID = Data([0x08])
        let registeredKey = P256.Signing.PrivateKey()
        let impostorKey = P256.Signing.PrivateKey()
        registerThroughPairing(
            approvedDeviceStore: approvedDeviceStore,
            devicePublicKey: deviceIdentity.publicKey,
            deviceName: "Kestrel MacBook Pro",
            credentialID: credentialID,
            signingKey: registeredKey,
            strength: .hardwareBound
        )
        armingStore.arm(HostScreenDeviceArming(
            devicePublicKey: deviceIdentity.publicKey,
            deviceName: "Kestrel MacBook Pro",
            armedDisplays: [HostScreenDisplayIdentity(display)],
            minimumCredentialStrength: .hardwareBound,
            armedAt: Date()
        ))

        let factory = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [deviceIdentity.publicKey],
            requireAuthentication: true,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { armingStore.load() },
            hostScreenPreSessionSnapshotProvider: { [display] },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: PresenceCredentialVerifier(approvedDeviceStore: approvedDeviceStore),
            hostScreenResumeTicketStore: HostScreenResumeTicketStore(),
            hostScreenLocalActivitySignal: FakeProductionWiringLocalActivitySignal()
        )
        let controller = factory.makeController()
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Kestrel MacBook Pro", publicKey: deviceIdentity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Kestrel MacBook Pro", publicKey: deviceIdentity.publicKey,
            signature: try! deviceIdentity.sign(transcript)
        ))
        guard case let .hostScreenList(displays, challenge) = try! controller.offerHostScreenList(), let entry = displays.first else {
            expect(false, "an armed, credentialed device with an eligible display offers at least one entry")
            return
        }
        let impostorSignature = try! impostorKey.signature(for: challenge)
        let refused = try! controller.handle(.hostScreenRequest(
            token: entry.opaqueToken,
            presence: .signed(credentialID: credentialID, credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat, signature: impostorSignature.rawRepresentation)
        ))
        expect(
            refused == .hostScreenRefused(reason: "host-screen-credential-unknown"),
            "a signature from a key other than the one this device actually registered at pairing is refused with the verifier's own cause, not the arming record or the display, both of which are genuinely fine"
        )

        print("PASS: a request signed with a key other than the one registered at pairing is refused end to end as host-screen-credential-unknown")
    }

    do {
        // Arming snapshots the registered strength, the way the
        // real coordinator's own toggle(isOn: true) does.
        let approvedDeviceStore = FileApprovedDeviceStore(url: temporaryApprovedDeviceStoreURL())
        let armingStore = HostScreenArmingStore(url: temporaryArmingStoreURL())
        let display = wiringTestDisplay(id: 25)
        let deviceIdentity = try! DeviceIdentity.generate()
        let credentialID = Data([0x09])
        let signingKey = P256.Signing.PrivateKey()
        registerThroughPairing(
            approvedDeviceStore: approvedDeviceStore,
            devicePublicKey: deviceIdentity.publicKey,
            deviceName: "Kestrel MacBook Pro",
            credentialID: credentialID,
            signingKey: signingKey,
            strength: .softwarePresence
        )
        armThroughCoordinator(
            armingStore: armingStore,
            approvedStore: approvedDeviceStore,
            devicePublicKey: deviceIdentity.publicKey,
            deviceName: "Kestrel MacBook Pro",
            armedDisplays: [HostScreenDisplayIdentity(display)]
        )
        let armedRecord = armingStore.load().devices.first { $0.devicePublicKey == deviceIdentity.publicKey }
        expect(
            armedRecord?.minimumCredentialStrength == .softwarePresence,
            "arming snapshots the strength actually registered at pairing (software-presence here) into minimumCredentialStrength, rather than leaving it nil"
        )

        let factory = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [deviceIdentity.publicKey],
            requireAuthentication: true,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { armingStore.load() },
            hostScreenPreSessionSnapshotProvider: { [display] },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: PresenceCredentialVerifier(approvedDeviceStore: approvedDeviceStore),
            hostScreenResumeTicketStore: HostScreenResumeTicketStore(),
            hostScreenLocalActivitySignal: FakeProductionWiringLocalActivitySignal()
        )
        let controller = factory.makeController()
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Kestrel MacBook Pro", publicKey: deviceIdentity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Kestrel MacBook Pro", publicKey: deviceIdentity.publicKey,
            signature: try! deviceIdentity.sign(transcript)
        ))
        guard case let .hostScreenList(displays, challenge) = try! controller.offerHostScreenList(), let entry = displays.first else {
            expect(false, "a device armed through the coordinator's own snapshot logic, with an eligible display, offers at least one entry")
            return
        }
        let genuineSignature = try! signingKey.signature(for: challenge)
        let admitted = try! controller.handle(.hostScreenRequest(
            token: entry.opaqueToken,
            presence: .signed(credentialID: credentialID, credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat, signature: genuineSignature.rawRepresentation)
        ))
        expect(
            { if case .hostScreenReady = admitted { return true } else { return false } }(),
            "a genuine signature from the key registered at pairing is admitted once arming has snapshotted that same strength as its own minimum -- the coordinator's write and the verifier's check agree"
        )

        print("PASS: arming snapshots the strength actually registered at pairing, and a genuine signed request against that snapshot is admitted")
    }

    do {
        // HostScreenAccountableMedia: no capture object exists, and
        // no frame can ever flow, until makeMedia has already begun
        // the log record and shown the badge.
        let logURL = temporaryHostScreenSessionLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let sessionLog = HostScreenSessionLogStore(url: logURL)
        var rawFactoryCallCount = 0
        let badge = FakeHostScreenBadgeDisplaying()
        let media = HostScreenAccountableMedia(
            rawFactory: { _, _ in
                rawFactoryCallCount += 1
                return FakeCanvasMedia()
            },
            sessionLog: sessionLog,
            deviceName: { "Kestrel MacBook Pro" },
            displayLabel: { "Built-in Display" },
            onBadgeStop: {},
            badgeFactory: { _ in badge }
        )
        expect(sessionLog.records().isEmpty, "before makeMedia runs, no log record exists yet")
        expect(media.badgeState == nil, "before makeMedia runs, no badge exists yet")
        expect(badge.showCount == 0, "before makeMedia runs, the badge is never shown")

        do {
            try await media.start(canvasDisplayID: 1) { _ in true }
            expect(false, "start() before makeMedia has ever run must throw, never silently no-op")
        } catch HostScreenAccountableMediaError.startedBeforeMakeMedia {
            // expected
        } catch {
            expect(false, "start() before makeMedia threw \(error), not HostScreenAccountableMediaError.startedBeforeMakeMedia")
        }
        expect(rawFactoryCallCount == 0, "start() without makeMedia having run first touches no raw factory -- no capture object is ever created")
        expect(sessionLog.records().isEmpty, "start() without makeMedia having run first writes no log record")
        expect(media.badgeState == nil, "start() without makeMedia having run first shows no badge")
        expect(badge.showCount == 0, "start() without makeMedia having run first never shows the badge")

        print("PASS: HostScreenAccountableMedia.start() before makeMedia has ever run throws, creating no capture object, no log record, and no badge")
    }

    do {
        // makeMedia begins the log record and the badge before
        // streaming can start, and the badge names the device by
        // its paired name, not a value the caller invented
        // separately.
        let logURL = temporaryHostScreenSessionLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let sessionLog = HostScreenSessionLogStore(url: logURL)
        var innerMedia: FakeCanvasMedia?
        let badge = FakeHostScreenBadgeDisplaying()
        let media = HostScreenAccountableMedia(
            rawFactory: { _, _ in
                let fake = FakeCanvasMedia()
                innerMedia = fake
                return fake
            },
            sessionLog: sessionLog,
            deviceName: { "Kestrel MacBook Pro" },
            displayLabel: { "Built-in Display" },
            onBadgeStop: {},
            badgeFactory: { _ in badge }
        )

        let produced = media.makeMedia(.remoteDefault)
        expect(
            sessionLog.records().count == 1 && sessionLog.records().first?.outcome == nil,
            "makeMedia writes exactly one open log record before returning media to stream with"
        )
        expect(media.badgeState != nil, "makeMedia shows a badge before returning media to stream with")
        expect(badge.showCount == 1, "makeMedia actually shows the badge -- not only sets badgeState -- exactly once, before returning media to stream with")
        expect(
            media.badgeState?.content == HostScreenBadgeContent(deviceName: "Kestrel MacBook Pro", displayLabel: "Built-in Display"),
            "the badge names the connected machine by the device name the arming record gave it, not a value the caller derives separately"
        )
        expect((produced as? HostScreenAccountableMedia) === media, "the media makeMedia returns is the accountable wrapper itself, not a bare handle to the raw capture object")

        try! await produced.start(canvasDisplayID: 7) { _ in true }
        expect(innerMedia?.startedDisplayIDs == [7], "once makeMedia has already begun the log record and the badge, start() reaches the real capture object")

        print("PASS: HostScreenAccountableMedia.makeMedia begins a log record and a badge, naming the device by its paired name, before streaming can start")
    }

    do {
        // A clean stop ends both the log record and the badge.
        let logURL = temporaryHostScreenSessionLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let sessionLog = HostScreenSessionLogStore(url: logURL)
        let badge = FakeHostScreenBadgeDisplaying()
        let media = HostScreenAccountableMedia(
            rawFactory: { _, _ in FakeCanvasMedia() },
            sessionLog: sessionLog,
            deviceName: { "Kestrel MacBook Pro" },
            displayLabel: { "Built-in Display" },
            onBadgeStop: {},
            badgeFactory: { _ in badge }
        )
        _ = media.makeMedia(.remoteDefault)
        await media.stop()

        expect(
            { if case .stopped = sessionLog.records().first?.outcome { return true } else { return false } }(),
            "stop() ends the log record with a stopped outcome, not left open"
        )
        expect(media.badgeState == nil, "stop() ends the badge")
        expect(badge.hideCount == 1, "stop() actually hides the badge -- not only clears badgeState -- exactly once")

        print("PASS: HostScreenAccountableMedia.stop() ends both the log record and the badge -- the clean-stop exit path")
    }

    do {
        // The inner media's own start() throwing -- capture that
        // never actually began streaming a frame -- is still an
        // exit path: nothing else would ever call stop() on it.
        let logURL = temporaryHostScreenSessionLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let sessionLog = HostScreenSessionLogStore(url: logURL)
        let badge = FakeHostScreenBadgeDisplaying()
        let media = HostScreenAccountableMedia(
            rawFactory: { _, _ in FailingCanvasMedia() },
            sessionLog: sessionLog,
            deviceName: { "Kestrel MacBook Pro" },
            displayLabel: { "Built-in Display" },
            onBadgeStop: {},
            badgeFactory: { _ in badge }
        )
        _ = media.makeMedia(.remoteDefault)
        do {
            try await media.start(canvasDisplayID: 1) { _ in true }
            expect(false, "FailingCanvasMedia.start() always throws")
        } catch {
            // expected
        }

        expect(
            { if case .stopped = sessionLog.records().first?.outcome { return true } else { return false } }(),
            "a capture object whose own start() threw still ends the log record -- nothing else would ever call stop() on it"
        )
        expect(media.badgeState == nil, "a capture object whose own start() threw still ends the badge")
        expect(badge.hideCount == 1, "a capture object whose own start() threw still actually hides the badge, exactly once")

        print("PASS: HostScreenAccountableMedia ends the log record and the badge even when the inner capture object's start() throws")
    }

    do {
        // The badge's own Stop control invokes the caller's
        // teardown immediately -- synchronously, not deferred to a
        // later run-loop turn or queued behind anything else.
        let logURL = temporaryHostScreenSessionLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let sessionLog = HostScreenSessionLogStore(url: logURL)
        var stopRequestCount = 0
        let badge = FakeHostScreenBadgeDisplaying()
        let media = HostScreenAccountableMedia(
            rawFactory: { _, _ in FakeCanvasMedia() },
            sessionLog: sessionLog,
            deviceName: { "Kestrel MacBook Pro" },
            displayLabel: { "Built-in Display" },
            onBadgeStop: { stopRequestCount += 1 },
            badgeFactory: { _ in badge }
        )
        _ = media.makeMedia(.remoteDefault)

        media.badgeState?.stopTapped()
        expect(stopRequestCount == 1, "tapping the badge's Stop invokes the caller's teardown immediately, once")
        expect(media.badgeState?.hasStopped == true, "the badge's own state reflects Stop having run immediately, not only the caller's closure")
        expect(badge.hideCount == 0, "tapping Stop alone does not itself hide the badge -- only the caller's own teardown, eventually calling stop(), ends the accounting")

        media.badgeState?.stopTapped()
        expect(stopRequestCount == 1, "a second tap does not invoke the caller's teardown twice")

        print("PASS: the badge's Stop control ends the session immediately, and is idempotent against a second tap")
    }

    do {
        // The video packet sequence must survive a capture rebuild:
        // a display-mode change discards the whole capture object --
        // and with it the packetizer that used to own the sequence --
        // but the client's VideoFrameIngress discards an entire
        // restarted stream whose numbers are not newer than the last
        // one it admitted, so the sequence itself must never restart.
        let logURL = temporaryHostScreenSessionLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let sessionLog = HostScreenSessionLogStore(url: logURL)
        let badge = FakeHostScreenBadgeDisplaying()
        var sequencersSeen: [VideoPacketSequencer] = []
        var sequenceNumbersProduced: [UInt64] = []
        let media = HostScreenAccountableMedia(
            rawFactory: { _, sequencer in
                sequencersSeen.append(sequencer)
                // Stands in for `HostScreenCaptureMedia`, which numbers
                // every frame of its capture from exactly this injected
                // sequencer via its own `H264SampleBufferPacketizer`.
                let packet = sequencer.packet(
                    presentationTimeNanoseconds: 0, isKeyFrame: true, codecConfiguration: nil, payload: Data()
                )
                sequenceNumbersProduced.append(packet.sequence)
                return FakeCanvasMedia()
            },
            sessionLog: sessionLog,
            deviceName: { "Kestrel MacBook Pro" },
            displayLabel: { "Built-in Display" },
            onBadgeStop: {},
            badgeFactory: { _ in badge }
        )
        _ = media.makeMedia(.remoteDefault)
        await media.replaceCapture(with: .remoteDefault, note: "mode changed to 1920x1080")
        await media.replaceCapture(with: .remoteDefault, note: "mode changed to 2560x1440")

        expect(
            sequencersSeen.count == 3,
            "makeMedia and each of the two replaceCapture calls all build a new capture object, so the factory runs three times -- got \(sequencersSeen.count)"
        )
        expect(
            sequencersSeen[0] === sequencersSeen[1] && sequencersSeen[1] === sequencersSeen[2],
            "every capture this session ever builds is handed the same VideoPacketSequencer instance, never a fresh one"
        )
        expect(
            sequenceNumbersProduced == [0, 1, 2],
            "numbering a packet from the shared sequencer right after each rebuild continues where the previous capture left off, rather than restarting at zero -- got \(sequenceNumbersProduced)"
        )

        print("PASS: accountable media threads one sequencer through every capture, so a replaced capture continues the sequence")
    }
}

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
/// builds it (a real `HostScreenArmingStore` reading a real file and a real
/// `HostScreenResumeTicketStore`), rather
/// than `HostSessionController`'s constructor directly, so a regression in
/// the factory's forwarding is caught here even if `HostSessionController`'s
/// own admission tests stay green.
private final class FakeProductionWiringLocalActivitySignal: HostLocalActivitySignal, @unchecked Sendable {
    var reading: HostLocalActivityReading = .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    func currentReading() -> HostLocalActivityReading { reading }
}

/// A fixed reading of this host's own last hid-tap post, standing in for
/// `MutableHostInjectedHIDActivity` the same way
/// `SelfPostDiscountingLocalActivitySignalTests.swift`'s own fake does.
private final class FakeProductionWiringHIDActivity: HostInjectedHIDActivity, @unchecked Sendable {
    private let seconds: TimeInterval?
    init(secondsSinceLastPost seconds: TimeInterval?) { self.seconds = seconds }
    func recordPost() {}
    func secondsSinceLastPost() -> TimeInterval? { seconds }
    func sampleBeforePost() {}
    func secondsSinceProvenHardwareActivity() -> TimeInterval? { nil }
}

/// Stands in for `HostScreenPresenceGate`: records every ask, the same way
/// `HostScreenSessionControllerAdmissionTests.swift`'s own fake does -- kept
/// as its own copy since that one is private to its file.
private final class FakeProductionWiringPresenceGate: HostScreenPresenceGating, @unchecked Sendable {
    private(set) var calls: [HostScreenBadgeContent] = []
    func ask(content: HostScreenBadgeContent) -> HostScreenPresenceOutcome {
        calls.append(content)
        return .proceed
    }
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
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenResumeTicketStore: resumeTicketStore,
            hostScreenPresenceActivitySignal: signal
        )
        let controller = factory.makeController()
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey,
            hostCertificateHash: nil
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))
        let response = try! controller.handle(.hostScreenRequest(
            token: Data([0x01]),
            resumeTicket: nil
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
        // An armed device is admitted, through the exact objects
        // sensoriumd constructs: pairing armed it, and nothing else
        // is asked of it.
        let armingURL = temporaryArmingStoreURL()
        defer { try? FileManager.default.removeItem(at: armingURL) }
        let armingStore = HostScreenArmingStore(url: armingURL)
        let display = wiringTestDisplay(id: 22)
        let identity = try! DeviceIdentity.generate()
        armingStore.arm(HostScreenDeviceArming(
            devicePublicKey: identity.publicKey,
            deviceName: "Kestrel Laptop Pro",
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
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenResumeTicketStore: resumeTicketStore,
            hostScreenPresenceActivitySignal: signal
        )
        let controller = factory.makeController()
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey,
            hostCertificateHash: nil
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))
        guard case let .hostScreenList(displays) = try! controller.offerHostScreenList(), let entry = displays.first else {
            expect(false, "an armed device with an eligible display offers at least one entry")
            return
        }
        let response = try! controller.handle(.hostScreenRequest(
            token: entry.opaqueToken,
            resumeTicket: nil
        ))
        expect(
            { if case .hostScreenReady = response { return true } else { return false } }(),
            "an armed device asking for a display this host offers is admitted through the factory sensoriumd itself builds"
        )
        expect(
            injectorFactory.requestedDisplayIDs == [display.id],
            "the admitted session builds an injector for exactly the display it was admitted on"
        )
        expect(
            injectorFactory.requestedSessionKinds == [.hostScreen],
            "a host-screen session builds a host-screen injector"
        )

        print("PASS: an armed device is admitted end to end through the objects sensoriumd constructs")
    }

    do {
        // The split that matters: the ask-first gate must read the raw
        // signal even while a `SelfPostDiscountingLocalActivitySignal` built
        // from the very same raw reading and the very same `ownActivity` --
        // this host's own most recent post -- would read the discount as no
        // activity at all. Discounting the gate's own reading the way the
        // relock decision's does would let a viewer's continuously
        // forwarded input hide a real person at the machine from it, the
        // unsafe direction -- see `HostScreenActivitySignals`.
        let armingURL = temporaryArmingStoreURL()
        defer { try? FileManager.default.removeItem(at: armingURL) }
        let armingStore = HostScreenArmingStore(url: armingURL)
        let display = wiringTestDisplay(id: 23)
        let identity = try! DeviceIdentity.generate()
        armingStore.arm(HostScreenDeviceArming(
            devicePublicKey: identity.publicKey,
            deviceName: "Kestrel Laptop Pro",
            armedAt: Date(),
            asksWhenSomeoneIsUsingThisMachine: true
        ))
        let resumeTicketStore = HostScreenResumeTicketStore()
        let rawSignal = FakeProductionWiringLocalActivitySignal()
        rawSignal.reading = .idleFor(0)
        let ownActivity = FakeProductionWiringHIDActivity(secondsSinceLastPost: 0)
        let signals = HostScreenActivitySignals(raw: rawSignal, ownActivity: ownActivity)
        let gate = FakeProductionWiringPresenceGate()

        let factory = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [identity.publicKey],
            requireAuthentication: true,
            inputInjectorFactory: FakeInputInjectorFactory(),
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { armingStore.load() },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenResumeTicketStore: resumeTicketStore,
            hostScreenPresenceActivitySignal: signals.presence,
            hostScreenPresenceGate: gate
        )
        let controller = factory.makeController()
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey,
            hostCertificateHash: nil
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))
        guard case let .hostScreenList(displays) = try! controller.offerHostScreenList(), let entry = displays.first else {
            expect(false, "an armed device with an eligible display offers at least one entry")
            return
        }
        _ = try! controller.handle(.hostScreenRequest(token: entry.opaqueToken, resumeTicket: nil))
        expect(
            gate.calls.count == 1,
            "the ask-first gate is asked even though a self-post-discounted reading of this same raw signal and ownActivity would have read as no activity at all"
        )
        expect(
            signals.relock.currentReading() == .idleFor(.infinity),
            "the relock decision reads the same raw signal discounted instead, and still discounts this host's own recorded post"
        )

        print("PASS: the ask-first gate reads the raw signal, never the self-post discount the relock decision reads instead")
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
            deviceName: { "Kestrel Laptop Pro" },
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
            deviceName: { "Kestrel Laptop Pro" },
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
            media.badgeState?.content == HostScreenBadgeContent(deviceName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"),
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
            deviceName: { "Kestrel Laptop Pro" },
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
            deviceName: { "Kestrel Laptop Pro" },
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
            deviceName: { "Kestrel Laptop Pro" },
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
            deviceName: { "Kestrel Laptop Pro" },
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

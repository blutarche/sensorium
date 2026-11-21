import Foundation
import SensoriumCore
import SensoriumHost

/// The host-screen gates that live in shared code, proved without any
/// platform implementation behind them: a badge that cannot be shown, a
/// capture permission that is not granted, media with no indicator and no
/// session record behind it, and a platform that supplies no screen-lock
/// reader each stop the host screen before a frame can exist.

private struct GateTestBadgeError: Error {}

@MainActor
private final class GateTestBadge: HostScreenBadgeDisplaying {
    private(set) var showCount = 0
    private(set) var hideCount = 0
    let failsToShow: Bool

    init(failsToShow: Bool) {
        self.failsToShow = failsToShow
    }

    func show() throws {
        showCount += 1
        if failsToShow { throw GateTestBadgeError() }
    }

    func hide() { hideCount += 1 }
}

private final class GateTestIdleSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading { .idleFor(10_000) }
}

private func gateTestDisplay() -> DisplaySnapshot {
    DisplaySnapshot(
        id: 7,
        pixelWidth: 2560,
        pixelHeight: 1440,
        modeWidth: 1280,
        modeHeight: 720,
        modePixelWidth: 2560,
        modePixelHeight: 1440,
        bounds: CGRect(x: 0, y: 0, width: 1280, height: 720),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

private func gateTestLogURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-gate-enforcement-log-\(UUID().uuidString).json")
}

/// One armed, authenticated connection whose coordinator streams the host
/// screen through `hostScreenMediaFactory`, with each gate input chosen by
/// the test.
@MainActor
private func makeGateFixture(
    controllerLockReader: (any ScreenLockStateReading)? = FakeScreenLockState(locked: false),
    coordinatorLockReader: (any ScreenLockStateReading)? = FakeScreenLockState(locked: false),
    requiresAccountableMedia: Bool,
    hostScreenMediaFactory: @escaping (VideoEncoderConfiguration, UInt32) throws -> any CanvasMediaStreaming
) -> (coordinator: HostSessionCoordinator, controller: HostSessionController) {
    let identity = try! DeviceIdentity.generate()
    let display = gateTestDisplay()
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: identity.publicKey,
            deviceName: "Kestrel Laptop Pro",
            armedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    ])
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [identity.publicKey],
        requireAuthentication: true,
        inputInjectorFactory: FakeInputInjectorFactory(),
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenPresenceActivitySignal: GateTestIdleSignal(),
        hostScreenLockStateReader: controllerLockReader
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey,
        hostCertificateHash: nil
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
    ))
    let coordinator = HostSessionCoordinator(
        controller: controller,
        media: CanvasSurfaceSlots { _ in FakeCanvasMedia() },
        videoSink: FakeVideoSink(),
        hostScreenMediaFactory: hostScreenMediaFactory,
        requiresAccountableHostScreenMedia: requiresAccountableMedia,
        lockStateReader: coordinatorLockReader
    )
    return (coordinator, controller)
}

@MainActor
private func gateTestToken(_ controller: HostSessionController) -> Data? {
    guard case let .hostScreenList(displays, _) = try? controller.offerHostScreenList(),
          let entry = displays.first else {
        return nil
    }
    return entry.opaqueToken
}

@MainActor
func runHostScreenGateEnforcementTests() async {
    do {
        // The indicator is part of the gate: when it cannot be shown the
        // session refuses, closes the record it opened, and never builds the
        // capture.
        let logURL = gateTestLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let sessionLog = HostScreenSessionLogStore(url: logURL)
        let badge = GateTestBadge(failsToShow: true)
        var rawFactoryCalls = 0
        let accountable = HostScreenAccountableMedia(
            capturePermission: grantedScreenCapturePermission(),
            rawFactory: { _, _ in
                rawFactoryCalls += 1
                return FakeCanvasMedia()
            },
            sessionLog: sessionLog,
            deviceName: { "Kestrel Laptop Pro" },
            displayLabel: { "Test Display" },
            onBadgeStop: {},
            badgeFactory: { _, _ in badge }
        )
        let fixture = makeGateFixture(requiresAccountableMedia: true) { try accountable.makeMedia($0, displayID: $1) }
        guard let token = gateTestToken(fixture.controller) else {
            expect(false, "the gate fixture offers its one display")
            return
        }
        var refusedByBadge = false
        do {
            _ = try await fixture.coordinator.handleWritingResponse(.hostScreenRequest(token: token, resumeTicket: nil))
        } catch is GateTestBadgeError {
            refusedByBadge = true
        } catch {
            expect(false, "a badge that cannot be shown refuses with its own error, not \(error)")
        }
        expect(refusedByBadge, "a host-screen session whose indicator cannot be shown is refused")
        expect(rawFactoryCalls == 0, "no capture is built for a session whose indicator failed")
        expect(
            sessionLog.records().allSatisfy { $0.outcome != nil },
            "the record opened for that session is closed again, so no session is left looking live"
        )
        print("PASS: a host-screen indicator that cannot be shown refuses the session before any capture exists")
    }

    do {
        // Capture permission is asked on every build and gates the record,
        // the indicator and the capture alike.
        let logURL = gateTestLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let sessionLog = HostScreenSessionLogStore(url: logURL)
        let badge = GateTestBadge(failsToShow: false)
        var rawFactoryCalls = 0
        let denied = ScreenCapturePermissionGate(checker: ScriptedScreenCaptureChecker(isGranted: false))
        let accountable = HostScreenAccountableMedia(
            capturePermission: denied,
            rawFactory: { _, _ in
                rawFactoryCalls += 1
                return FakeCanvasMedia()
            },
            sessionLog: sessionLog,
            deviceName: { "Kestrel Laptop Pro" },
            displayLabel: { "Test Display" },
            onBadgeStop: {},
            badgeFactory: { _, _ in badge }
        )
        let fixture = makeGateFixture(requiresAccountableMedia: true) { try accountable.makeMedia($0, displayID: $1) }
        guard let token = gateTestToken(fixture.controller) else {
            expect(false, "the gate fixture offers its one display")
            return
        }
        var refusedForPermission = false
        do {
            _ = try await fixture.coordinator.handleWritingResponse(.hostScreenRequest(token: token, resumeTicket: nil))
        } catch HostScreenAccountableMediaError.screenCapturePermissionNotGranted {
            refusedForPermission = true
        } catch {
            expect(false, "an ungranted capture permission refuses with its own error, not \(error)")
        }
        expect(refusedForPermission, "a host-screen session is refused while screen capture is not permitted")
        expect(
            rawFactoryCalls == 0 && badge.showCount == 0 && sessionLog.records().isEmpty,
            "an ungranted permission opens no record, shows no indicator and builds no capture"
        )
        print("PASS: an ungranted screen-capture permission refuses the session before a record, an indicator or a capture exists")
    }

    do {
        // Media that is not the accountable wrapper has no indicator and no
        // session record behind it, so a platform that requires the wrapper
        // refuses it and stops it unstarted.
        let bare = FakeCanvasMedia()
        let fixture = makeGateFixture(requiresAccountableMedia: true) { _, _ in bare }
        guard let token = gateTestToken(fixture.controller) else {
            expect(false, "the gate fixture offers its one display")
            return
        }
        var refusedAsUnaccountable = false
        do {
            _ = try await fixture.coordinator.handleWritingResponse(.hostScreenRequest(token: token, resumeTicket: nil))
        } catch HostScreenBringUpError.mediaNotAccountable {
            refusedAsUnaccountable = true
        } catch {
            expect(false, "unaccountable media is refused as such, not with \(error)")
        }
        expect(refusedAsUnaccountable, "host-screen media with no indicator and no record behind it is refused")
        expect(
            bare.startedDisplayIDs.isEmpty && bare.stopCount == 1,
            "and that media was never started, and was stopped"
        )
        print("PASS: host-screen media that is not the accountable wrapper is refused where the platform requires one")
    }

    do {
        // With no screen-lock reader the host cannot say what a viewer's
        // input would reach, so the controller offers no host screen at all.
        let fixture = makeGateFixture(
            controllerLockReader: nil,
            requiresAccountableMedia: false
        ) { _, _ in FakeCanvasMedia() }
        expect(
            gateTestToken(fixture.controller) == nil,
            "a controller with no screen-lock reader offers no host screen"
        )
        print("PASS: a controller with no screen-lock reader offers no host screen")
    }

    do {
        // The coordinator refuses on its own too, whatever a controller
        // admitted.
        let bare = FakeCanvasMedia()
        let fixture = makeGateFixture(
            coordinatorLockReader: nil,
            requiresAccountableMedia: false
        ) { _, _ in bare }
        guard let token = gateTestToken(fixture.controller) else {
            expect(false, "the gate fixture offers its one display")
            return
        }
        var refused = false
        do {
            _ = try await fixture.coordinator.handleWritingResponse(.hostScreenRequest(token: token, resumeTicket: nil))
        } catch HostScreenBringUpError.screenLockStateUnavailable {
            refused = true
        } catch {
            expect(false, "a coordinator with no screen-lock reader refuses with its own error, not \(error)")
        }
        expect(refused && bare.startedDisplayIDs.isEmpty, "a coordinator with no screen-lock reader streams no host screen")
        print("PASS: a coordinator with no screen-lock reader refuses to stream a host screen")
    }
}

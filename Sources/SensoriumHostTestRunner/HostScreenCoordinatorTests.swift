import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Design §12, the coordinator fork: given a host-screen request
/// `HostSessionController` already admitted, `HostSessionCoordinator`
/// must bring capture up with none of the canvas path's own assumptions --
/// no workspace, no display release at teardown, an encoder sized from the
/// real display's own geometry rather than the session canvas's compiled-in
/// constant -- while leaving the canvas path itself byte-identical, which
/// `HostScreenResumeTicket*Tests.swift` and every other existing coordinator
/// test already re-prove by continuing to pass unmodified.
@MainActor
private func hostScreenTestDisplay(
    id: UInt32 = 7,
    modeWidth: Int = 2560,
    modeHeight: Int = 1440,
    modePixelWidth: Int = 5120,
    modePixelHeight: Int = 2880
) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: modePixelWidth,
        pixelHeight: modePixelHeight,
        modeWidth: modeWidth,
        modeHeight: modeHeight,
        modePixelWidth: modePixelWidth,
        modePixelHeight: modePixelHeight,
        bounds: CGRect(x: 0, y: 0, width: modeWidth, height: modeHeight),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

private final class AlwaysApprovingVerifier: HostScreenPresenceProofVerifying, @unchecked Sendable {
    func verify(proof: HostScreenPresenceProof, devicePublicKey: Data, minimumStrength: HostScreenCredentialStrength?, challenge: Data) -> Bool {
        true
    }
}

private final class AlwaysIdleSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

private final class NeverIdleSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading { .idleFor(0) }
}

/// Stands in for `HostScreenPresenceGate` here the same way
/// `HostScreenSessionControllerAdmissionTests.swift`'s own fake does --
/// kept as its own copy since that one is private to its file.
private final class FakeHostScreenPresenceGate: HostScreenPresenceGating, @unchecked Sendable {
    var outcome: HostScreenPresenceOutcome = .proceed
    func ask(content: HostScreenBadgeContent) -> HostScreenPresenceOutcome { outcome }
}

/// A controller already admitted for host-screen use, and the coordinator
/// wrapping it -- everything a bring-up test needs, broken by exactly one
/// thing per test the way `HostScreenSessionControllerAdmissionTests.swift`'s
/// own fixture already is.
@MainActor
private func makeHostScreenFixture(
    display: DisplaySnapshot,
    onEvent: (@Sendable (String) -> Void)? = nil,
    onSessionEnded: (@Sendable () -> Void)? = nil,
    modeController: FakeHostScreenModeController? = nil,
    localActivitySignal: (any HostLocalActivitySignal)? = nil,
    presenceGate: (any HostScreenPresenceGating)? = nil,
    hostScreenMediaFactory: @escaping (VideoEncoderConfiguration) -> any CanvasMediaStreaming
) -> (
    coordinator: HostSessionCoordinator,
    controller: HostSessionController,
    injectorFactory: FakeInputInjectorFactory,
    canvasMedia: FakeCanvasMedia,
    canvasWorkspaces: CanvasSurfaceSlots<FakeCanvasWorkspace>
) {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: deviceKey,
            deviceName: "Kestrel Laptop Pro",
            minimumCredentialStrength: .hardwareBound,
            armedAt: Date(timeIntervalSince1970: 1_700_000_000),
            // This fixture is broken by exactly one thing per test, including
            // by the localActivitySignal/presenceGate pair above; the
            // ask-first setting they depend on is turned on explicitly since
            // it now defaults off (HostScreenArmingTests.swift covers that
            // default on its own).
            asksWhenSomeoneIsUsingThisMachine: true
        )
    ])
    let injectorFactory = FakeInputInjectorFactory()
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        inputInjectorFactory: injectorFactory,
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenPresenceProofVerifier: AlwaysApprovingVerifier(),
        hostScreenLocalActivitySignal: localActivitySignal ?? AlwaysIdleSignal(),
        hostScreenPresenceGate: presenceGate,
        hostScreenModeController: modeController
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))

    let canvasMedia = FakeCanvasMedia()
    let canvasWorkspaces = CanvasSurfaceSlots { _ in FakeCanvasWorkspace() }
    let coordinator = HostSessionCoordinator(
        controller: controller,
        media: CanvasSurfaceSlots { _ in canvasMedia },
        videoSink: FakeVideoSink(),
        workspaces: CanvasSurfaceSlots { surface in canvasWorkspaces[surface] },
        onEvent: onEvent,
        onSessionEnded: onSessionEnded,
        hostScreenMediaFactory: hostScreenMediaFactory
    )
    return (coordinator, controller, injectorFactory, canvasMedia, canvasWorkspaces)
}

@MainActor
private func offerAndExtractToken(_ controller: HostSessionController) -> Data {
    guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList(), let entry = displays.first else {
        expect(false, "the fixture's offer names at least one display")
        return Data()
    }
    return entry.opaqueToken
}

@MainActor
func runHostScreenCoordinatorTests() async {
    do {
        // Bring-up: no workspace, encoder sized from real geometry
        let display = hostScreenTestDisplay()
        var capturedConfiguration: VideoEncoderConfiguration?
        let hostScreenMedia = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let fixture = makeHostScreenFixture(
            display: display,
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { configuration in
                capturedConfiguration = configuration
                return hostScreenMedia
            }
        )
        let token = offerAndExtractToken(fixture.controller)
        let response = try! await fixture.coordinator.handleFirstResponse(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        guard case .hostScreenReady = response else {
            expect(false, "an admissible host-screen request is answered with hostScreenReady")
            return
        }
        expect(
            hostScreenMedia.startedDisplayIDs == [7],
            "capture actually starts, against the real resolved display ID"
        )
        expect(
            capturedConfiguration?.width == 2560 && capturedConfiguration?.height == 1440,
            "the encoder's own base dimensions come from the real display's logical size, not the session canvas's 1920x1200"
        )
        expect(
            capturedConfiguration?.encodeWidth == 2560 && capturedConfiguration?.encodeHeight == 1440,
            "a display well under the hardware encoder's limit is encoded at its own native logical size, unclamped"
        )
        for surface in CanvasSurfaceID.allCases {
            expect(
                fixture.canvasWorkspaces[surface].startedDisplayIDs.isEmpty,
                "host-screen bring-up starts no workspace on either canvas slot -- design §3.2: no workspace window at all"
            )
        }
        expect(
            fixture.canvasMedia.startedDisplayIDs.isEmpty,
            "host-screen bring-up never touches the canvas media pipelines"
        )
        expect(
            events.messages.contains { $0.contains("host-screen capture started") && $0.contains("2560x1440") },
            "the encoded-size log names the real dimensions truthfully"
        )

        print("PASS: a host-screen bring-up starts no workspace and sizes the encoder from the real display's own geometry")
    }

    do {
        // A display exceeding the hardware encoder's own limit is clamped, and the clamp is reported
        let hugeDisplay = hostScreenTestDisplay(modeWidth: 6016, modeHeight: 3384, modePixelWidth: 6016, modePixelHeight: 3384)
        var capturedConfiguration: VideoEncoderConfiguration?
        let hostScreenMedia = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let fixture = makeHostScreenFixture(
            display: hugeDisplay,
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { configuration in
                capturedConfiguration = configuration
                return hostScreenMedia
            }
        )
        let token = offerAndExtractToken(fixture.controller)
        _ = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            capturedConfiguration.map { max($0.encodeWidth, $0.encodeHeight) <= VideoEncoderConfiguration.hardwareH264MaxDimension } == true,
            "a display exceeding the hardware encoder's own dimension limit on either axis is capped rather than handed straight to VideoToolbox, which would fail encoder creation outright"
        )
        expect(
            capturedConfiguration.map { Double($0.encodeWidth) / Double($0.encodeHeight) }.map { ($0 - 6016.0 / 3384.0).magnitude < 0.001 } == true,
            "the display's own aspect ratio survives the clamp -- both axes are capped by the same factor"
        )
        expect(
            events.messages.contains { $0.contains("exceeds the hardware encoder\u{2019}s own limit") },
            "an encoder-dimension clamp is reported truthfully, the same way a sustainability clamp already is"
        )

        print("PASS: a display exceeding the hardware H.264 encoder's own dimension limit is clamped, its aspect ratio preserved, and the clamp is reported")
    }

    do {
        // Teardown: capture stops, no display release, held input released, onSessionEnded fires once
        let display = hostScreenTestDisplay()
        let hostScreenMedia = FakeScalableCanvasMedia()
        let sessionEnded = DiagnosticsRecorder()
        let fixture = makeHostScreenFixture(
            display: display,
            onSessionEnded: { sessionEnded.record("ended") },
            hostScreenMediaFactory: { _ in hostScreenMedia }
        )
        let token = offerAndExtractToken(fixture.controller)
        _ = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        // A button held down on the real display when the session ends must
        // not stay stuck on the operator's own machine.
        _ = try! fixture.controller.handle(.input(.pointerButton(button: .left, isDown: true, x: 100, y: 100), surfaceID: nil))

        _ = try! await fixture.coordinator.handleWritingResponse(.goodbye(reason: "test teardown"))

        expect(hostScreenMedia.stopCount == 1, "teardown stops host-screen capture exactly once")
        expect(
            fixture.injectorFactory.injector.events.contains(.pointerButton(button: .left, isDown: false, x: 100, y: 100)),
            "teardown releases input this connection left held on the real display -- the same obligation canvas-mode teardown already meets"
        )
        expect(sessionEnded.messages == ["ended"], "onSessionEnded fires exactly once for a session that only ever streamed host screen, never canvas")
        // No display-owning object exists in this design for host-screen mode
        // to release in the first place (design §3.2: it is never created and
        // never released) -- `stop()` above is the only call `CanvasMediaStreaming`
        // exposes at all, and it is ScreenCaptureKit's own stream stop, not a
        // display-configuration operation. There is nothing further to assert
        // a "display source" fake would have recorded, because nothing else
        // is ever called.

        print("PASS: host-screen teardown stops capture, releases held input, and fires onSessionEnded exactly once, with nothing display-owning to release")
    }

    do {
        // No media factory configured refuses loudly, never a silent hostScreenReady with no video
        let display = hostScreenTestDisplay()
        let events = DiagnosticsRecorder()
        let identity = try! DeviceIdentity.generate()
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: "Probe",
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
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
            hostScreenPresenceProofVerifier: AlwaysApprovingVerifier(),
            hostScreenLocalActivitySignal: AlwaysIdleSignal()
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
        ))
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: CanvasSurfaceSlots { _ in FakeCanvasMedia() },
            videoSink: FakeVideoSink(),
            onEvent: { events.record($0) }
            // hostScreenMediaFactory deliberately omitted.
        )
        let token = offerAndExtractToken(controller)
        do {
            _ = try await coordinator.handleWritingResponse(.hostScreenRequest(
                token: token,
                presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
            ))
            expect(false, "a coordinator with no host-screen media factory must throw rather than silently answer hostScreenReady with no video to follow")
        } catch HostScreenBringUpError.noMediaFactoryConfigured {
        } catch {
            expect(false, "an unconfigured host-screen media factory reports noMediaFactoryConfigured, not \(error)")
        }

        print("PASS: a coordinator with no host-screen media factory refuses loudly rather than answering ready with nothing to follow")
    }

    do {
        // A host-screen refusal reaches the host operator log, naming
        // the reason and, since no device is admitted yet, the
        // generic machine phrase rather than any name or key.
        let display = hostScreenTestDisplay()
        let events = DiagnosticsRecorder()
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeHostScreenFixture(
            display: display,
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { _ in hostScreenMedia }
        )
        // A token this session never minted -- `offerHostScreenList` was
        // never called, so nothing is in `hostScreenMintedTokens` -- refuses
        // with the controller's own catch-all reason, before any device
        // name is ever resolved for this request.
        let response = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: Data([0xFF]),
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        guard case let .hostScreenRefused(reason) = response else {
            expect(false, "an unminted token is refused, not answered hostScreenReady -- got: \(String(describing: response))")
            return
        }
        expect(
            events.messages.contains("host screen refused for the connected machine: \(reason)"),
            "the host operator log names the refusal and its reason, falling back to the generic machine phrase since "
                + "no device was ever admitted for this request -- got: \(events.messages)"
        )

        print("PASS: a refused host-screen request reaches the host operator log, naming the reason and the generic machine phrase")
    }

    do {
        // A host-screen grant reaches the host operator log too,
        // naming the device the controller actually admitted.
        let display = hostScreenTestDisplay()
        let events = DiagnosticsRecorder()
        let hostScreenMedia = FakeScalableCanvasMedia()
        let fixture = makeHostScreenFixture(
            display: display,
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { _ in hostScreenMedia }
        )
        let token = offerAndExtractToken(fixture.controller)
        let response = try! await fixture.coordinator.handleFirstResponse(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        guard case .hostScreenReady = response else {
            expect(false, "an admissible host-screen request is answered with hostScreenReady -- got: \(String(describing: response))")
            return
        }
        expect(
            events.messages.contains("host screen started for Kestrel Laptop Pro"),
            "the host operator log names the device the controller actually admitted, read off its own armed "
                + "record rather than the wire's own claim -- got: \(events.messages)"
        )

        print("PASS: a granted host-screen request reaches the host operator log, naming the admitted device")
    }

    do {
        // A request that needed to ask a person at this machine
        // leaves its own log line, before the outcome it reached.
        let display = hostScreenTestDisplay()
        let events = DiagnosticsRecorder()
        let hostScreenMedia = FakeScalableCanvasMedia()
        let gate = FakeHostScreenPresenceGate()
        gate.outcome = .refused(reason: HostScreenPresenceRule.declinedReason)
        let fixture = makeHostScreenFixture(
            display: display,
            onEvent: { events.record($0) },
            localActivitySignal: NeverIdleSignal(),
            presenceGate: gate,
            hostScreenMediaFactory: { _ in hostScreenMedia }
        )
        let token = offerAndExtractToken(fixture.controller)
        let response = try! await fixture.coordinator.handleFirstResponse(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        expect(
            response == .hostScreenRefused(reason: "host-screen-presence-declined"),
            "a decline reaches the wire with its own reason -- got: \(String(describing: response))"
        )
        expect(
            events.messages.contains(
                "asking the person at this machine whether Kestrel Laptop Pro may see "
                    + "\(HostScreenArmingPresentation.displayLabel(for: display))"
            ),
            "the host operator log records that a prompt was put up at all, naming the device and display it "
                + "asked about -- got: \(events.messages)"
        )
        expect(
            events.messages.contains("host screen refused for the connected machine: host-screen-presence-declined"),
            "the refusal itself still logs, after the asking line -- got: \(events.messages)"
        )

        print("PASS: a request needing to ask leaves its own host operator log line naming the device and display it asked about")
    }

    do {
        // Admission succeeding is not the same as capture starting:
        // a factory whose stream refuses to start must never leave
        // the false "host screen started" line standing.
        let display = hostScreenTestDisplay()
        let events = DiagnosticsRecorder()
        let fixture = makeHostScreenFixture(
            display: display,
            onEvent: { events.record($0) },
            hostScreenMediaFactory: { _ in FailingCanvasMedia() }
        )
        let token = offerAndExtractToken(fixture.controller)
        do {
            _ = try await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
                token: token,
                presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
            ))
            expect(false, "a host-screen capture stream that refuses to start must throw, not answer as if it were streaming")
        } catch {
            // Expected: FailingCanvasMedia always throws.
        }
        expect(
            events.messages.contains { $0.contains("Could not start host-screen capture") },
            "the capture failure itself reaches the host operator log -- got: \(events.messages)"
        )
        expect(
            !events.messages.contains { $0.hasPrefix("host screen started for") },
            "admission succeeding is not capture starting -- no \u{2018}host screen started\u{2019} line may stand when the "
                + "stream that follows never actually came up -- got: \(events.messages)"
        )

        print("PASS: a host-screen request whose capture fails to start after admission logs the failure, never a false \u{2018}started\u{2019} line")
    }
}

/// The display modes of the fixture's own 2560x1440 host screen: the one it
/// starts on, and a readable one a person on a small viewer would pick.
private let fixtureCurrentMode = HostScreenModeEntry(
    modeID: "5120x2880@2560x1440@60",
    width: 2560,
    height: 1440,
    pixelWidth: 5120,
    pixelHeight: 2880,
    refreshRate: 60,
    isHiDPI: true
)

private let fixtureReadableMode = HostScreenModeEntry(
    modeID: "3840x2160@1920x1080@60",
    width: 1920,
    height: 1080,
    pixelWidth: 3840,
    pixelHeight: 2160,
    refreshRate: 60,
    isHiDPI: true
)

/// A third mode, between the other two, so a test can tell "the mode this
/// session started on" apart from "the mode it was on a moment ago".
private let fixtureMiddleMode = HostScreenModeEntry(
    modeID: "4096x2304@2048x1152@60",
    width: 2048,
    height: 1152,
    pixelWidth: 4096,
    pixelHeight: 2304,
    refreshRate: 60,
    isHiDPI: true
)

/// Host-screen media whose capture rebuild does not finish until a test says
/// so. That gap is where the transport can die: the session is already over
/// by the time the rebuild returns, and what the coordinator does next is
/// the whole point of the test that uses this.
@MainActor
private final class GatedReplaceHostScreenMedia: HostScreenCaptureReplacing {
    private(set) var startedDisplayIDs: [UInt32] = []
    private(set) var stopCount = 0
    private(set) var replacedConfigurations: [VideoEncoderConfiguration] = []
    private var pendingReplace: CheckedContinuation<Void, Never>?
    var currentStreamScale = 1.0

    /// True while a rebuild is waiting on `finishReplace()`.
    var isReplacingCapture: Bool { pendingReplace != nil }

    func start(
        canvasDisplayID: UInt32,
        onPacket: @escaping @Sendable (EncodedVideoFramePacket) -> Bool
    ) async throws {
        startedDisplayIDs.append(canvasDisplayID)
    }

    func stop() async { stopCount += 1 }

    func replaceCapture(with configuration: VideoEncoderConfiguration, note: String) async {
        replacedConfigurations.append(configuration)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            pendingReplace = continuation
        }
    }

    func finishReplace() {
        guard let continuation = pendingReplace else { return }
        pendingReplace = nil
        continuation.resume()
    }

    func reconfigure(streamScale: Double) async throws {}
    func apply(framesPerSecond: Int) async throws {}
    func apply(qualityScale: Double) async throws {}
    func requestKeyFrame() async {}
    func refreshStillPicture() async throws -> Int? { nil }
    var currentFramesPerSecond: Int {
        get async { VideoEncoderConfiguration.remoteDefault.framesPerSecond }
    }
    var currentQualityScale: Double { get async { 1.0 } }
    var frameCounts: HostFrameCounts {
        get async { HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0) }
    }
}

@MainActor
private func makeModeController(displayID: UInt32) -> FakeHostScreenModeController {
    let modes = FakeHostScreenModeController()
    modes.modesByDisplay[displayID] = [fixtureCurrentMode, fixtureMiddleMode, fixtureReadableMode]
    modes.currentModeIDByDisplay[displayID] = fixtureCurrentMode.modeID
    return modes
}

/// The coordinator's half of the host screen's display mode: the list the
/// viewer is handed unprompted, and what a pick actually costs -- capture
/// restarted at the new size before the viewer is told anything, and the
/// display put back if it cannot be.
@MainActor
func runHostScreenModeCoordinatorTests() async {
    do {
        // The mode list follows hostScreenReady unprompted
        let display = hostScreenTestDisplay()
        let modes = makeModeController(displayID: display.id)
        let written = DiagnosticsRecorder()
        var writtenMessages: [SensoriumMessage] = []
        let fixture = makeHostScreenFixture(
            display: display,
            modeController: modes,
            hostScreenMediaFactory: { _ in FakeScalableCanvasMedia() }
        )
        let token = offerAndExtractToken(fixture.controller)
        _ = try! await fixture.coordinator.handle(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        )) { message in
            writtenMessages.append(message)
            written.record("\(message)")
        }
        guard writtenMessages.count == 3 else {
            expect(false, "a host-screen bring-up writes the ready reply, then the mode list, then the lock-state notice -- got: \(writtenMessages)")
            return
        }
        guard case .hostScreenReady = writtenMessages[0] else {
            expect(false, "the ready reply is still written first, before anything about modes")
            return
        }
        guard case let .hostScreenModeList(listed, currentModeID) = writtenMessages[1] else {
            expect(false, "the mode list follows it unprompted -- got: \(writtenMessages[1])")
            return
        }
        guard case .hostScreenLockState = writtenMessages[2] else {
            expect(false, "the lock-state notice follows the mode list so the viewer knows whether to offer the unlock prompt -- got: \(writtenMessages[2])")
            return
        }
        expect(
            listed == [fixtureCurrentMode, fixtureMiddleMode, fixtureReadableMode]
                && currentModeID == fixtureCurrentMode.modeID,
            "and it carries this display's own modes and the one it is on, so the viewer never has to ask"
        )
        print("PASS: a host-screen session is handed its display's mode list right after it is told the screen is ready")
    }

    do {
        // A pick restarts capture at the new size, then answers
        let display = hostScreenTestDisplay()
        let modes = makeModeController(displayID: display.id)
        var configurations: [VideoEncoderConfiguration] = []
        let firstMedia = FakeScalableCanvasMedia()
        let secondMedia = FakeScalableCanvasMedia()
        let fixture = makeHostScreenFixture(
            display: display,
            modeController: modes,
            hostScreenMediaFactory: { configuration in
                configurations.append(configuration)
                return configurations.count == 1 ? firstMedia : secondMedia
            }
        )
        let token = offerAndExtractToken(fixture.controller)
        _ = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        var writtenMessages: [SensoriumMessage] = []
        _ = try! await fixture.coordinator.handle(.hostScreenModeRequest(modeID: fixtureReadableMode.modeID)) { message in
            writtenMessages.append(message)
        }
        expect(
            firstMedia.stopCount == 1 && secondMedia.startedDisplayIDs == [display.id],
            "the capture running at the old size is stopped and a new one started on the same display -- a stream sized for a resolution the display is no longer on has nothing to send"
        )
        expect(
            configurations.count == 2
                && configurations[1].width == 1920
                && configurations[1].height == 1080
                && configurations[1].encodeWidth == 1920,
            "and the new capture is sized from the mode that was just applied -- got: \(configurations.map { "\($0.width)x\($0.height)" })"
        )
        guard writtenMessages.count == 2 else {
            expect(false, "a mode change answers with what was applied and then the fresh list -- got: \(writtenMessages)")
            return
        }
        guard case let .hostScreenModeApplied(geometry, currentModeID) = writtenMessages[0] else {
            expect(false, "the applied reply comes first -- got: \(writtenMessages[0])")
            return
        }
        expect(
            geometry == SessionSurfaceGeometry(logicalWidth: 1920, logicalHeight: 1080, backingScale: 2.0)
                && currentModeID == fixtureReadableMode.modeID,
            "naming the geometry the viewer must now size its window to"
        )
        guard case let .hostScreenModeList(_, listedCurrent) = writtenMessages[1] else {
            expect(false, "and a fresh list follows it, so the checkmark moves -- got: \(writtenMessages[1])")
            return
        }
        expect(listedCurrent == fixtureReadableMode.modeID, "with the mode now current named as such")
        print("PASS: a viewer's mode pick restarts host-screen capture at the new size before the viewer is told it was applied")
    }

    do {
        // Capture that will not restart puts the display back
        let display = hostScreenTestDisplay()
        let modes = makeModeController(displayID: display.id)
        var configurations: [VideoEncoderConfiguration] = []
        let firstMedia = FakeScalableCanvasMedia()
        let recoveredMedia = FakeScalableCanvasMedia()
        let events = DiagnosticsRecorder()
        let fixture = makeHostScreenFixture(
            display: display,
            onEvent: { events.record($0) },
            modeController: modes,
            hostScreenMediaFactory: { configuration in
                configurations.append(configuration)
                switch configurations.count {
                case 1: return firstMedia
                case 2: return FailingCanvasMedia()
                default: return recoveredMedia
                }
            }
        )
        let token = offerAndExtractToken(fixture.controller)
        _ = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        var writtenMessages: [SensoriumMessage] = []
        _ = try! await fixture.coordinator.handle(.hostScreenModeRequest(modeID: fixtureReadableMode.modeID)) { message in
            writtenMessages.append(message)
        }
        expect(
            modes.restoredDisplayIDs == [display.id]
                && modes.currentModeIDByDisplay[display.id] == fixtureCurrentMode.modeID,
            "a mode the host cannot actually stream is not a mode the display is left on -- got: \(modes.restoredDisplayIDs)"
        )
        expect(
            writtenMessages == [.hostScreenModeRefused(reason: HostScreenModeRefusalReason.failed)],
            "and the viewer is told the change failed, not that it worked -- got: \(writtenMessages)"
        )
        expect(
            recoveredMedia.startedDisplayIDs == [display.id]
                && configurations.last.map { $0.width == 2560 && $0.height == 1440 } == true,
            "and the picture the session already had comes back, at the size the display is back on"
        )
        expect(
            events.messages.contains { $0.contains("host-screen capture could not restart") },
            "with the reason in the host log -- got: \(events.messages)"
        )
        print("PASS: a mode change whose capture will not restart puts the display back, keeps the session streaming, and refuses honestly")
    }

    do {
        // What is put back is where the session started, not the
        // mode it happened to be on a moment ago
        let display = hostScreenTestDisplay()
        let modes = makeModeController(displayID: display.id)
        var configurations: [VideoEncoderConfiguration] = []
        var captureCount = 0
        let recoveredMedia = FakeScalableCanvasMedia()
        let fixture = makeHostScreenFixture(
            display: display,
            modeController: modes,
            hostScreenMediaFactory: { configuration in
                configurations.append(configuration)
                captureCount += 1
                // The first two captures are the session's own and the one
                // the middle mode brought up; the third is the mode that
                // will not stream, and the fourth is the recovery.
                switch captureCount {
                case 3: return FailingCanvasMedia()
                case 4: return recoveredMedia
                default: return FakeScalableCanvasMedia()
                }
            }
        )
        let token = offerAndExtractToken(fixture.controller)
        _ = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        _ = try! await fixture.coordinator.handle(.hostScreenModeRequest(modeID: fixtureMiddleMode.modeID)) { _ in }
        var writtenMessages: [SensoriumMessage] = []
        _ = try! await fixture.coordinator.handle(.hostScreenModeRequest(modeID: fixtureReadableMode.modeID)) { message in
            writtenMessages.append(message)
        }

        expect(
            writtenMessages == [.hostScreenModeRefused(reason: HostScreenModeRefusalReason.failed)],
            "the second change is refused, since its capture would not run -- got: \(writtenMessages)"
        )
        expect(
            modes.currentModeIDByDisplay[display.id] == fixtureCurrentMode.modeID,
            "and the display goes back to the mode the session found it on, not the one it was on a moment ago -- got: \(String(describing: modes.currentModeIDByDisplay[display.id]))"
        )
        expect(
            recoveredMedia.startedDisplayIDs == [display.id]
                && configurations.last.map { $0.width == 2560 && $0.height == 1440 } == true,
            "so the picture comes back at 2560x1440, the size the session began at -- got: \(configurations.map { "\($0.width)x\($0.height)" })"
        )
        print("PASS: several changes in one session are undone to the mode that session started on, and capture comes back at that size")
    }

    do {
        // The viewer drops while the capture is being rebuilt
        let display = hostScreenTestDisplay()
        let modes = makeModeController(displayID: display.id)
        let media = GatedReplaceHostScreenMedia()
        var builtMediaCount = 0
        let fixture = makeHostScreenFixture(
            display: display,
            modeController: modes,
            hostScreenMediaFactory: { _ in
                builtMediaCount += 1
                return media
            }
        )
        let token = offerAndExtractToken(fixture.controller)
        _ = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        let coordinator = fixture.coordinator
        let modeChange = Task { @MainActor in
            _ = try? await coordinator.handle(.hostScreenModeRequest(modeID: fixtureReadableMode.modeID)) { _ in }
        }
        let rebuildStarted = await waitUntil(timeoutSeconds: 2) { media.isReplacingCapture }
        expect(rebuildStarted, "the mode change reaches the capture rebuild, which is where this test needs it to wait")
        // The transport dies here, in the gap the rebuild is sitting in.
        await coordinator.sessionDidEnd(reason: "transport-closed")
        media.finishReplace()
        await modeChange.value

        expect(
            media.startedDisplayIDs == [display.id],
            "no capture is started for a session that has already ended -- one that was, would stream a screen with no viewer, no badge, and no session record behind it -- got: \(media.startedDisplayIDs)"
        )
        expect(
            builtMediaCount == 1,
            "and no second media is built for it either -- got: \(builtMediaCount)"
        )
        expect(
            modes.restoredDisplayIDs == [display.id]
                && modes.currentModeIDByDisplay[display.id] == fixtureCurrentMode.modeID,
            "while the display still goes back to the mode the session found it on -- got: \(String(describing: modes.currentModeIDByDisplay[display.id]))"
        )
        print("PASS: a viewer dropping mid-rebuild leaves no capture running and the display back where it was")
    }
}

/// Stands in for the real badge window: records `show`/`hide` without ever
/// opening an `NSPanel`, so a test can assert the person at this machine never
/// stopped being told their screen was being watched.
@MainActor
private final class RecordingBadgeDisplay: HostScreenBadgeDisplaying {
    private(set) var showCount = 0
    private(set) var hideCount = 0

    func show() { showCount += 1 }
    func hide() { hideCount += 1 }
}

@MainActor
private func temporaryModeSessionLogURL() -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-host-screen-mode-session-log-\(UUID().uuidString).json")
}

/// What a mode change must cost the person at this machine: nothing. CLAUDE.md
/// requires a continuous indication naming the connected device for as long
/// as a host-screen session is live, and one record per session. A
/// resolution change restarts the capture, so these run the whole change
/// through `HostScreenAccountableMedia` -- the wrapper production actually
/// uses -- rather than a bare fake, because the wrapper is where a restart
/// could end the record and drop the badge.
@MainActor
func runHostScreenModeAccountabilityTests() async {
    do {
        // A change restarts the capture inside the same session
        let display = hostScreenTestDisplay()
        let modes = makeModeController(displayID: display.id)
        let logURL = temporaryModeSessionLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let sessionLog = HostScreenSessionLogStore(url: logURL)
        let badge = RecordingBadgeDisplay()
        var captureConfigurations: [VideoEncoderConfiguration] = []
        var captures: [FakeScalableCanvasMedia] = []
        let accountable = HostScreenAccountableMedia(
            rawFactory: { configuration, _ in
                captureConfigurations.append(configuration)
                let capture = FakeScalableCanvasMedia()
                captures.append(capture)
                return capture
            },
            sessionLog: sessionLog,
            deviceName: { "Kestrel Laptop Pro" },
            displayLabel: { "Built-in Display" },
            onBadgeStop: {},
            badgeFactory: { _ in badge }
        )
        let fixture = makeHostScreenFixture(
            display: display,
            modeController: modes,
            hostScreenMediaFactory: { accountable.makeMedia($0) }
        )
        let token = offerAndExtractToken(fixture.controller)
        _ = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        _ = try! await fixture.coordinator.handle(.hostScreenModeRequest(modeID: fixtureReadableMode.modeID)) { _ in }

        expect(
            sessionLog.records().count == 1,
            "a resolution change is the same session to the person at this machine, so it leaves one record, not two -- got \(sessionLog.records().count)"
        )
        expect(
            sessionLog.records().first?.outcome == nil,
            "and that record is still open, because the session has not ended"
        )
        expect(
            badge.showCount == 1 && badge.hideCount == 0,
            "the badge naming the connected device never goes away mid-session -- shown \(badge.showCount), hidden \(badge.hideCount)"
        )
        expect(
            captures.count == 2 && captures[0].stopCount == 1 && captures[1].startedDisplayIDs == [display.id],
            "only the capture itself stops and starts again, sized for the new mode"
        )
        expect(
            captureConfigurations.count == 2 && captureConfigurations[1].width == 1920,
            "and the new capture is the one sized for the mode just applied -- got: \(captureConfigurations.map { "\($0.width)x\($0.height)" })"
        )
        expect(
            sessionLog.records().first?.displayModeChanges == ["mode changed to 1920x1080"],
            "the record says the screen's resolution changed while it ran, since that is part of what happened -- got: \(String(describing: sessionLog.records().first?.displayModeChanges))"
        )
        print("PASS: a host-screen resolution change restarts only the capture, leaving one session record open and the badge up throughout")
    }

    do {
        // And so does the recovery from a change that would not run
        let display = hostScreenTestDisplay()
        let modes = makeModeController(displayID: display.id)
        let logURL = temporaryModeSessionLogURL()
        defer { try? FileManager.default.removeItem(at: logURL) }
        let sessionLog = HostScreenSessionLogStore(url: logURL)
        let badge = RecordingBadgeDisplay()
        var captureCount = 0
        let recovered = FakeScalableCanvasMedia()
        let accountable = HostScreenAccountableMedia(
            rawFactory: { _, _ in
                captureCount += 1
                switch captureCount {
                case 1: return FakeScalableCanvasMedia()
                case 2: return FailingCanvasMedia()
                default: return recovered
                }
            },
            sessionLog: sessionLog,
            deviceName: { "Kestrel Laptop Pro" },
            displayLabel: { "Built-in Display" },
            onBadgeStop: {},
            badgeFactory: { _ in badge }
        )
        let fixture = makeHostScreenFixture(
            display: display,
            modeController: modes,
            hostScreenMediaFactory: { accountable.makeMedia($0) }
        )
        let token = offerAndExtractToken(fixture.controller)
        _ = try! await fixture.coordinator.handleWritingResponse(.hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ))
        var writtenMessages: [SensoriumMessage] = []
        _ = try! await fixture.coordinator.handle(.hostScreenModeRequest(modeID: fixtureReadableMode.modeID)) { message in
            writtenMessages.append(message)
        }

        expect(
            writtenMessages == [.hostScreenModeRefused(reason: HostScreenModeRefusalReason.failed)],
            "the change is still refused honestly -- got: \(writtenMessages)"
        )
        expect(
            recovered.startedDisplayIDs == [display.id],
            "and the session still gets its picture back at the mode the display was put back on"
        )
        expect(
            sessionLog.records().count == 1 && sessionLog.records().first?.outcome == nil,
            "a change that failed and was undone is still one session, still running -- got \(sessionLog.records().count) record(s)"
        )
        expect(
            badge.showCount == 1 && badge.hideCount == 0,
            "and the badge never blinked while the capture was rebuilt twice -- shown \(badge.showCount), hidden \(badge.hideCount)"
        )
        print("PASS: a resolution change that will not stream, and the recovery from it, still leave one open record and one unbroken badge")
    }
}

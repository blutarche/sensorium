import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// A viewer whose decoder holds back Main-profile pictures asks for
/// Constrained Baseline. The host honours that only from an authenticated
/// connection, only before the session's target is requested, and only by
/// lowering the profile of the one connection that asked.
@MainActor
func runViewerDecoderPreferenceHostTests() async {
    let preference = SensoriumMessage.viewerDecoderPreference(h264Profile: .constrainedBaseline)

    do {
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            keyConfinement: .unconfined
        )
        expectThrows(
            HostSessionControllerError.authenticationRequired,
            { _ = try controller.handle(preference) },
            "an unauthenticated peer cannot choose the profile the host encodes at"
        )
        expect(controller.viewerRequestedProfileLevel == nil, "and a refused preference is not recorded")
    }

    do {
        let media = FakeCanvasMedia()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(media),
            videoSink: FakeVideoSink()
        )
        let reply = try! await coordinator.handleFirstResponse(preference)
        expect(reply == nil, "a decoder preference has no reply")
        expect(
            controller.viewerRequestedProfileLevel == .constrainedBaselineAutoLevel,
            "Constrained Baseline maps to the encoder's Constrained Baseline profile"
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
        )
        expect(media.startedDisplayIDs.count == 1, "the canvas starts streaming")
        expect(
            media.usedProfileLevels.map(\.profileLevel) == [.constrainedBaselineAutoLevel]
                && media.usedProfileLevels.allSatisfy { $0.startsBefore == 0 },
            "the canvas encoder is told to use Baseline before it starts -- got \(media.usedProfileLevels)"
        )

        _ = try! await coordinator.handleWritingResponse(preference)
        expect(
            media.usedProfileLevels.count == 1,
            "a preference arriving once the session is streaming changes nothing"
        )
    }

    do {
        let media = FakeCanvasMedia()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(media),
            videoSink: FakeVideoSink()
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
        )
        expect(media.usedProfileLevels.isEmpty, "a viewer that asks for nothing keeps the default profile")
        _ = try! await coordinator.handleWritingResponse(preference)
        expect(
            media.usedProfileLevels.isEmpty && controller.viewerRequestedProfileLevel == nil,
            "a preference sent after the target was requested is ignored"
        )
    }

    do {
        var baselineConfiguration: VideoEncoderConfiguration?
        let asked = makeHostScreenPreferenceFixture { configuration, _ in
            baselineConfiguration = configuration
            return FakeScalableCanvasMedia()
        }
        _ = try! await asked.coordinator.handleWritingResponse(preference)
        _ = try! await asked.coordinator.handleWritingResponse(
            .hostScreenRequest(token: hostScreenPreferenceToken(asked.controller), resumeTicket: nil)
        )
        expect(
            baselineConfiguration?.profileLevel == .constrainedBaselineAutoLevel,
            "a host-screen encoder is built at Baseline for a viewer that asked -- got \(String(describing: baselineConfiguration?.profileLevel))"
        )

        var defaultConfiguration: VideoEncoderConfiguration?
        let silent = makeHostScreenPreferenceFixture { configuration, _ in
            defaultConfiguration = configuration
            return FakeScalableCanvasMedia()
        }
        _ = try! await silent.coordinator.handleWritingResponse(
            .hostScreenRequest(token: hostScreenPreferenceToken(silent.controller), resumeTicket: nil)
        )
        expect(
            defaultConfiguration?.profileLevel == VideoEncoderConfiguration.remoteDefault.profileLevel,
            "and at the default profile for a viewer that did not"
        )
        expect(
            asked.controller.viewerRequestedProfileLevel == .constrainedBaselineAutoLevel
                && silent.controller.viewerRequestedProfileLevel == nil,
            "only the viewer that asked has its preference recorded"
        )
    }

    do {
        var configurations: [VideoEncoderConfiguration] = []
        let media = ScreenCaptureCanvasMedia(
            surface: CanvasSurfaceID.allCases[0],
            admissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(
                capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity
            ),
            pipelineFactory: { _, _, configuration, _, _, _, _, _, _, _, _ in
                configurations.append(configuration)
                return ProfileRecordingPipeline()
            },
            contentFilterProvider: { _ in SCContentFilter() }
        )
        media.use(profileLevel: .constrainedBaselineAutoLevel)
        try! await media.start(canvasDisplayID: 42, onPacket: { _ in true })
        try? await media.reconfigure(streamScale: 1.5)
        expect(
            configurations.count == 2 && configurations.allSatisfy { $0.profileLevel == .constrainedBaselineAutoLevel },
            "the capture media builds every pipeline at the profile it was told to use -- got \(configurations.map(\.profileLevel))"
        )
    }

    print("PASS: a viewer's Constrained Baseline preference applies only to its own connection, and only before the target is requested")
}

@MainActor
private final class ProfileRecordingPipeline: CanvasMediaPipelining {
    func start() async throws {}
    func stop() async throws {}
    func apply(framesPerSecond: Int) async throws {}
    func apply(qualityScale: Double) throws {}
    func requestKeyFrame() {}
    func refreshStillPicture() async throws -> Int? { nil }
}

private final class IdlePreferenceSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

@MainActor
func makeHostScreenPreferenceFixture(
    videoSink: any CanvasVideoSending = FakeVideoSink(),
    onEvent: (@Sendable (String) -> Void)? = nil,
    hostScreenMediaFactory: @escaping (VideoEncoderConfiguration, CGDirectDisplayID) -> any CanvasMediaStreaming
) -> (coordinator: HostSessionCoordinator, controller: HostSessionController) {
    let display = DisplaySnapshot(
        id: 7,
        pixelWidth: 3840,
        pixelHeight: 2400,
        modeWidth: 1920,
        modeHeight: 1200,
        modePixelWidth: 3840,
        modePixelHeight: 2400,
        bounds: CGRect(x: 0, y: 0, width: 1920, height: 1200),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
    let identity = try! DeviceIdentity.generate()
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
        hostScreenPresenceActivitySignal: IdlePreferenceSignal()
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, hostCertificateHash: nil
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
    ))
    let coordinator = HostSessionCoordinator(
        controller: controller,
        media: CanvasSurfaceSlots { _ in FakeCanvasMedia() },
        videoSink: videoSink,
        onEvent: onEvent,
        hostScreenMediaFactory: hostScreenMediaFactory
    )
    return (coordinator, controller)
}

@MainActor
func hostScreenPreferenceToken(_ controller: HostSessionController) -> Data {
    guard case let .hostScreenList(displays, _) = try! controller.offerHostScreenList(), let entry = displays.first else {
        expect(false, "the fixture offers one display")
        return Data()
    }
    return entry.opaqueToken
}

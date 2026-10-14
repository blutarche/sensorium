import Foundation
import SensoriumClient
import SensoriumCore

/// A viewer whose H.264 decoder is OpenH264 asks the host for Constrained
/// Baseline, because OpenH264 holds every picture of any other profile back
/// until the next one arrives. Every other decoder keeps the host's default.
@MainActor
func testViewerDecoderPreferenceTests() async {
    expect(
        ViewerDecoderSelection.requestedProfile(forDecoderNamed: "libopenh264") == .constrainedBaseline,
        "a viewer decoding with OpenH264 asks for Constrained Baseline"
    )
    for name in ["h264", "h264_v4l2m2m", nil] as [String?] {
        expect(
            ViewerDecoderSelection.requestedProfile(forDecoderNamed: name) == nil,
            "a viewer decoding with \(String(describing: name)) asks for nothing"
        )
    }
    #if !canImport(CAVCodec)
    expect(
        ViewerDecoderSelection.platformRequestedProfile == nil,
        "a viewer whose platform decoder is not libavcodec never asks"
    )
    #endif

    expect(
        ViewerDecoderSelection.decodesInHardware(decoderName: "h264", driverOffersH264: true),
        "libavcodec's own H.264 decoder uses a driver that offers H.264"
    )
    expect(
        !ViewerDecoderSelection.decodesInHardware(decoderName: "libopenh264", driverOffersH264: true),
        "OpenH264 decodes on the CPU whatever the driver offers"
    )
    expect(
        !ViewerDecoderSelection.decodesInHardware(decoderName: "h264", driverOffersH264: false),
        "no driver, no hardware decode"
    )
    expect(
        !ViewerDecoderSelection.decodesInHardware(decoderName: nil, driverOffersH264: true),
        "no decoder at all is not hardware decode"
    )

    let identity = try! DeviceIdentity.generate()
    let asking = ScriptedClientTransport(responses: [
        .hostScreenRefused(reason: "host-screen-not-allowed"),
        .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
    ])
    _ = try! await ClientSessionController(
        transport: asking,
        identity: identity,
        decoderPreference: .constrainedBaseline
    ).connect(deviceName: "Laptop")
    let askingSent = await asking.sent
    expect(
        askingSent.count >= 4,
        "the connect sent a hello, a preference, its key-frame declaration and a target request -- got \(askingSent)"
    )
    if askingSent.count >= 4 {
        guard case .authenticatedHello = askingSent[0],
              askingSent[1] == .viewerDecoderPreference(h264Profile: .constrainedBaseline),
              case .canvasRequest = askingSent[3] else {
            expect(false, "the preference follows the hello and precedes the target request -- got \(askingSent)")
            return
        }
    }

    let silent = ScriptedClientTransport(responses: [
        .hostScreenRefused(reason: "host-screen-not-allowed"),
        .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
    ])
    _ = try! await ClientSessionController(transport: silent, identity: identity).connect(deviceName: "Laptop")
    expect(
        await !silent.sent.contains { if case .viewerDecoderPreference = $0 { return true } else { return false } },
        "a viewer with no preference sends none"
    )

    let unauthenticated = ScriptedClientTransport(responses: [
        .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
    ])
    _ = try! await ClientSessionController(
        transport: unauthenticated,
        decoderPreference: .constrainedBaseline
    ).connect(deviceName: "Laptop")
    expect(
        await !unauthenticated.sent.contains { if case .viewerDecoderPreference = $0 { return true } else { return false } },
        "an unauthenticated connect sends no preference, which the host would refuse"
    )

    print("PASS: a viewer decoding with OpenH264 asks for Constrained Baseline right after its hello, and no other viewer asks")
}

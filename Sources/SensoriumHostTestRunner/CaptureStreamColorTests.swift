import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit
import SensoriumHost

/// The picture reaches the encoder as two-plane video-range YCbCr, converted
/// with the high-definition matrix, because the encoded stream says nothing
/// about its own colour: VideoToolbox writes no colour description into the
/// H.264 headers for a video-range source, whatever the source buffer is
/// tagged with. Both viewers then read an untagged stream as video range
/// with the high-definition matrix. A capture converting with any other
/// matrix, or in full range, would shift hues or crush blacks on the viewer
/// with nothing in the stream to warn it.
@available(macOS 13.0, *)
func runCaptureStreamColorTests() async {
    let configuration = CaptureStreamConfigurationFixture.make()

    expect(
        configuration.pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        "capture asks for video-range two-plane YCbCr, which the hardware encoder takes without converting colour itself"
    )
    expect(
        (configuration.colorMatrix as String?) == (CGDisplayStream.yCbCrMatrix_ITU_R_709_2 as String),
        "capture converts to YCbCr with the high-definition matrix, the one a viewer assumes for a stream that names none"
    )
    expect(
        configuration.colorSpaceName == nil,
        "capture keeps the display's own colour space, so the red, green and blue handed to the matrix are the ones a packed capture carried"
    )

    let primingFrame = HostMediaPipeline.blankFrame(width: 64, height: 32)
    expect(
        primingFrame.flatMap(CMSampleBufferGetImageBuffer).map(CVPixelBufferGetPixelFormatType) == configuration.pixelFormat,
        "the motion encoder is primed with a frame in the format capture delivers, so priming warms the path real frames take"
    )

    print("PASS: capture asks for video-range 4:2:0 with the high-definition matrix and leaves the colour space alone")
}

@available(macOS 13.0, *)
private enum CaptureStreamConfigurationFixture {
    static func make() -> SCStreamConfiguration {
        ScreenCaptureSession.streamConfiguration(
            configuration: .remoteDefault,
            captureTarget: .hostScreen
        )
    }
}

import CoreMedia
import CoreVideo
import Foundation
import SensoriumHost

/// The Constrained Baseline profile a viewer can ask for is only worth offering if this
/// machine's hardware encoder produces it at the sizes the host streams. Runs
/// real `VTCompressionSession`s on generated frames; no display is involved.
@MainActor
func runBaselineEncoderHardwareTests() async {
    let configurations: [(name: String, configuration: VideoEncoderConfiguration)] = [
        ("1920x1200", VideoEncoderConfiguration.remoteDefault.with(profileLevel: .constrainedBaselineAutoLevel)),
        ("3840x2400", VideoEncoderConfiguration.fullHiDPI.with(profileLevel: .constrainedBaselineAutoLevel))
    ]
    for (name, configuration) in configurations {
        expect(configuration.requiresHardwareAcceleration, "\(name) is the host's hardware-only configuration")
        let frames = BaselineEncodedFrames()
        let encoder: VideoToolboxEncoder
        do {
            encoder = try VideoToolboxEncoder(configuration: configuration) { outcome in
                if case let .encoded(sampleBuffer) = outcome {
                    frames.record(sampleBuffer)
                }
            }
        } catch {
            expect(false, "the hardware encoder opens a Constrained Baseline session at \(name) -- got \(error)")
            continue
        }
        for index in 0..<3 {
            try? encoder.encode(flatSampleBuffer(
                width: configuration.encodeWidth,
                height: configuration.encodeHeight,
                shade: UInt8(40 * index),
                frameIndex: index
            ))
        }
        for _ in 0..<50 where frames.first == nil {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let streamProfile = frames.first.flatMap(sequenceParameterSetProfile)
        expect(
            streamProfile.map(isConstrainedBaseline) == true,
            "the stream encoder's \(name) output is Constrained Baseline, profile_idc 66 with constraint_set1_flag -- got \(String(describing: streamProfile))"
        )

        let still = try? StillFrameEncoder.encodeKeyFrame(
            imageBuffer: flatPixelBuffer(width: configuration.encodeWidth, height: configuration.encodeHeight, shade: 200),
            configuration: configuration,
            presentationTimeNanoseconds: 1_000_000_000
        )
        let stillProfile = still.flatMap(sequenceParameterSetProfile)
        expect(
            stillProfile.map(isConstrainedBaseline) == true,
            "the still-refresh encoder's \(name) output is Constrained Baseline too -- got \(String(describing: stillProfile))"
        )
        print("PASS: the hardware encoder produces Constrained Baseline at \(name)")
    }
}

private final class BaselineEncodedFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [CMSampleBuffer] = []

    func record(_ sampleBuffer: CMSampleBuffer) {
        lock.lock()
        buffers.append(sampleBuffer)
        lock.unlock()
    }

    var first: CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffers.first
    }
}

/// constraint_set1_flag is the second most significant bit of the byte after
/// profile_idc.
private func isConstrainedBaseline(_ profile: (profileIndication: UInt8, constraintFlags: UInt8)) -> Bool {
    profile.profileIndication == 66 && profile.constraintFlags & 0x40 != 0
}

private func sequenceParameterSetProfile(_ sampleBuffer: CMSampleBuffer) -> (profileIndication: UInt8, constraintFlags: UInt8)? {
    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
    var pointer: UnsafePointer<UInt8>?
    var size = 0
    let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
        format,
        parameterSetIndex: 0,
        parameterSetPointerOut: &pointer,
        parameterSetSizeOut: &size,
        parameterSetCountOut: nil,
        nalUnitHeaderLengthOut: nil
    )
    guard status == noErr, let pointer, size >= 3 else { return nil }
    return (pointer[1], pointer[2])
}

private func flatPixelBuffer(width: Int, height: Int, shade: UInt8) -> CVPixelBuffer {
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attributes as CFDictionary, &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        print("FAIL: a test pixel buffer could not be created, status \(status)")
        Foundation.exit(1)
    }
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
        memset(base, Int32(shade), CVPixelBufferGetBytesPerRow(pixelBuffer) * height)
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}

private func flatSampleBuffer(width: Int, height: Int, shade: UInt8, frameIndex: Int) -> CMSampleBuffer {
    let pixelBuffer = flatPixelBuffer(width: width, height: height, shade: shade)
    var formatDescription: CMVideoFormatDescription?
    CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription
    )
    var timing = CMSampleTimingInfo(
        duration: CMTime(value: 1, timescale: 60),
        presentationTimeStamp: CMTime(value: Int64(frameIndex), timescale: 60),
        decodeTimeStamp: .invalid
    )
    var sampleBuffer: CMSampleBuffer?
    guard let formatDescription,
          CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
          ) == noErr,
          let sampleBuffer else {
        print("FAIL: a test sample buffer could not be created")
        Foundation.exit(1)
    }
    return sampleBuffer
}

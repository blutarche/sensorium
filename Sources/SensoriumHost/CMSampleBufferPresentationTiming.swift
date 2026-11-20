#if os(macOS)
import CoreMedia

/// The same presentation-time-to-nanoseconds conversion `H264SampleBufferPacketizer`
/// uses, so a capture/encode timestamp and a packet's `presentationTimeNanoseconds`
/// are directly comparable keys.
@available(macOS 13.0, *)
enum CMSampleBufferPresentationTiming {
    static func nanoseconds(_ sampleBuffer: CMSampleBuffer) -> Int64? {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid else { return nil }
        let scaledTime = CMTimeConvertScale(presentationTime, timescale: 1_000_000_000, method: .default)
        guard scaledTime.value >= 0 else { return nil }
        return scaledTime.value
    }
}
#endif

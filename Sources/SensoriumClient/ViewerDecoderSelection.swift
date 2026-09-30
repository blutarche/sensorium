#if canImport(CAVCodec)
import CAVCodec
#endif
import SensoriumCore

/// What the H.264 decoder this viewer will actually open means for the
/// session: which profile to ask the host for, and whether decoding can
/// happen in hardware. Decided from the decoder's libavcodec name, so the
/// rules are checked on any platform.
public enum ViewerDecoderSelection {
    /// OpenH264 releases a picture of any profile but Baseline only when the
    /// next access unit arrives. A host sends nothing while its screen is
    /// still, so the last change would wait on screen until something else
    /// moved. Every other decoder shows each picture as it is decoded.
    public static func requestedProfile(forDecoderNamed name: String?) -> ViewerH264Profile? {
        name == openH264DecoderName ? .constrainedBaseline : nil
    }

    /// Only libavcodec's own H.264 decoder hands work to a VA-API device.
    /// A wrapped external decoder ignores the device and decodes on the CPU,
    /// however capable the driver is.
    public static func decodesInHardware(decoderName: String?, driverOffersH264: Bool) -> Bool {
        decoderName == nativeDecoderName && driverOffersH264
    }

    /// The profile this viewer asks every host for. `nil` where the platform
    /// decoder is not libavcodec.
    public static var platformRequestedProfile: ViewerH264Profile? {
        requestedProfile(forDecoderNamed: platformDecoderName)
    }

    /// The name of the decoder libavcodec opens for H.264 on this machine,
    /// or `nil` where libavcodec is not the viewer's decoder.
    public static var platformDecoderName: String? {
        #if canImport(CAVCodec)
        guard let codec = avcodec_find_decoder(AV_CODEC_ID_H264) else { return nil }
        return String(cString: codec.pointee.name)
        #else
        return nil
        #endif
    }

    static let nativeDecoderName = "h264"
    static let openH264DecoderName = "libopenh264"
}

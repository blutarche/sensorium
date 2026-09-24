#if canImport(CAVCodec)
import CAVCodec
import Foundation

/// One frame this machine draws for itself, in the same two-plane layout a
/// software decode produces.
///
/// It exists so the viewer's window, presenter and colour conversion can be
/// checked on a machine with no host to dial: a picture whose every value is
/// known here appears on the screen, or something along that path is wrong.
public enum SyntheticNV12Frame {
    /// A grey ramp beside solid red, green and blue, coded for BT.709 limited
    /// range. The ramp shows the luma plane's stride and the three bands show
    /// the chroma plane's, since each is wrong in a different, visible way.
    ///
    /// Dimensions are rounded down to even numbers: a chroma sample of this
    /// layout covers two pixels in each direction.
    public static func bands(width requestedWidth: Int, height requestedHeight: Int) -> DecodedFrame? {
        let width = max(requestedWidth - requestedWidth % 2, 2)
        let height = max(requestedHeight - requestedHeight % 2, 2)
        guard let frame = av_frame_alloc() else { return nil }
        frame.pointee.format = AV_PIX_FMT_NV12.rawValue
        frame.pointee.width = Int32(width)
        frame.pointee.height = Int32(height)
        frame.pointee.color_range = AVCOL_RANGE_MPEG
        frame.pointee.colorspace = AVCOL_SPC_BT709
        var allocated: UnsafeMutablePointer<AVFrame>? = frame
        guard av_frame_get_buffer(frame, 0) == 0,
              let luma = frame.pointee.data.0,
              let chroma = frame.pointee.data.1 else {
            av_frame_free(&allocated)
            return nil
        }
        let lumaStride = Int(frame.pointee.linesize.0)
        let chromaStride = Int(frame.pointee.linesize.1)
        for y in 0..<height {
            for x in 0..<width {
                let band = min(x * bandCount / width, bandCount - 1)
                let ramp = UInt8(16 + (219 * x * bandCount / width).clampedToRamp)
                luma[y * lumaStride + x] = band == 0 ? ramp : bandLuma[band]
            }
        }
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let band = min(x * bandCount / width, bandCount - 1)
                let offset = (y / 2) * chromaStride + x
                chroma[offset] = bandBlueChroma[band]
                chroma[offset + 1] = bandRedChroma[band]
            }
        }
        guard let box = AVFrameBox(referencing: frame, deviceReference: nil, vaDisplay: nil) else {
            av_frame_free(&allocated)
            return nil
        }
        av_frame_free(&allocated)
        return DecodedFrame(payload: box, width: width, height: height)
    }

    private static let bandCount = 4
    /// The BT.709 limited-range codings of neutral grey, and of full red,
    /// green and blue. The grey band's luma is the ramp instead.
    private static let bandLuma: [UInt8] = [126, 63, 173, 32]
    private static let bandBlueChroma: [UInt8] = [128, 102, 42, 240]
    private static let bandRedChroma: [UInt8] = [128, 240, 26, 118]
}

private extension Int {
    /// Keeps the ramp inside the range limited-range luma is coded in, since
    /// the last band's own width can push the last step past it.
    var clampedToRamp: Int { Swift.min(Swift.max(self, 0), 219) }
}
#endif

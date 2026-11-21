import Foundation

@available(macOS 13.0, *)
public enum StillFrameEncoderError: Error, Equatable {
    case sessionCreationFailed(Int32)
    case propertyUpdateFailed(Int32)
    case frameSubmissionFailed(Int32)
    /// VideoToolbox accepted the frame, finished, and produced nothing. Named
    /// rather than reported as a submission failure: there is a picture to
    /// send and no frame carrying it, which is a different thing from the
    /// encoder having refused it.
    case noEncodedFrame
    /// Every quality this picture was allowed to try still produced more bytes
    /// than the wire format accepts. Reported rather than returned: the write
    /// would refuse it, and by then the frame has already been counted and
    /// logged as the picture that went out.
    case frameExceedsTransportLimit(bytes: Int)
}

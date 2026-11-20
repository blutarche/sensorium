#if os(Linux)
import Foundation
import SensoriumCore

public enum LinuxVideoEncoderError: Error, Equatable {
    /// Odd or tiny dimensions, or a frame rate or key-frame interval that is
    /// not positive.
    case invalidConfiguration
    /// Neither the requested encoder nor any fallback opened.
    case noEncoderAvailable
    /// libavcodec refused to open or configure the encoder. Carries its
    /// error code.
    case sessionCreationFailed(Int32)
    /// An encoder option libavcodec does not recognise.
    case optionRejected(String)
    case frameSubmissionFailed(Int32)
    /// The frame is not the size the encoder was built for, or its buffer is
    /// smaller than its own geometry says.
    case invalidFrame
    /// The encoder was shut down.
    case shutDown
    /// DMA-BUF input is not built yet.
    case dmaBufInputNotSupported
}

/// One frame's fate. Mirrors the macOS host's `VideoEncodeOutcome`: every
/// frame an encoder accepts gets exactly one, whether it encoded, was
/// dropped, or failed.
public enum LinuxVideoEncodeOutcome: Equatable, Sendable {
    /// The frame encoded. The packet is in the form the viewer decodes:
    /// length-prefixed NAL units, and on a key frame the parameter sets in
    /// `codecConfiguration`.
    case encoded(EncodedVideoFramePacket)
    /// The encoder chose to send nothing for this frame.
    case dropped
    /// The encoder failed on this frame. Carries a libavcodec error code.
    case failed(Int32)
}

/// The submission half of an encoder, with the semantics of the macOS host's
/// `VideoFrameEncoding` over a portable frame type.
public protocol LinuxVideoFrameEncoding: AnyObject {
    func encode(_ frame: LinuxVideoFrame) throws
    /// Makes the next frame submitted a key frame. Safe from any thread.
    func requestKeyFrame()
}

/// A frame as a Linux compositor shares it by DMA-BUF: file descriptors for
/// each plane rather than bytes. The entry point for a future zero-copy path;
/// no encoder accepts it yet.
public struct LinuxDMABufFrame: Sendable {
    public struct Plane: Sendable {
        public let fileDescriptor: Int32
        public let offset: Int
        public let bytesPerRow: Int

        public init(fileDescriptor: Int32, offset: Int, bytesPerRow: Int) {
            self.fileDescriptor = fileDescriptor
            self.offset = offset
            self.bytesPerRow = bytesPerRow
        }
    }

    public let width: Int
    public let height: Int
    /// A DRM fourcc code.
    public let drmFormat: UInt32
    public let drmModifier: UInt64
    public let planes: [Plane]
    public let presentationTimeNanoseconds: UInt64

    public init(
        width: Int,
        height: Int,
        drmFormat: UInt32,
        drmModifier: UInt64,
        planes: [Plane],
        presentationTimeNanoseconds: UInt64
    ) {
        self.width = width
        self.height = height
        self.drmFormat = drmFormat
        self.drmModifier = drmModifier
        self.planes = planes
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
    }
}

/// How long the stages of the last frame took, in nanoseconds.
public struct LinuxEncodeTimings: Equatable, Sendable {
    /// BGRx to YCbCr on the CPU.
    public var conversion: UInt64 = 0
    /// Copying the picture into a GPU surface. Zero for the software encoder.
    public var upload: UInt64 = 0
    /// Submitting the frame and waiting for its packet.
    public var encode: UInt64 = 0
}

/// Numbers encoder output, so the viewer's ingress, which discards any packet
/// not newer than the last it admitted, never sees the counter go back. Shared
/// by every encoder a session builds in turn.
public final class LinuxVideoPacketSequencer: @unchecked Sendable {
    private let lock = NSLock()
    private var nextSequence: UInt64 = 0

    public init() {}

    func packet(
        presentationTimeNanoseconds: UInt64,
        isKeyFrame: Bool,
        codecConfiguration: Data?,
        payload: Data
    ) -> EncodedVideoFramePacket {
        lock.lock()
        defer { lock.unlock() }
        let sequence = nextSequence
        nextSequence &+= 1
        return EncodedVideoFramePacket(
            sequence: sequence,
            presentationTimeNanoseconds: presentationTimeNanoseconds,
            isKeyFrame: isKeyFrame,
            codecConfiguration: isKeyFrame ? codecConfiguration : nil,
            payload: payload
        )
    }
}
#endif

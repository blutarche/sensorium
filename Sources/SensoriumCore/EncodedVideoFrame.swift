import Foundation

public struct EncodedVideoFramePacket: Equatable, Sendable {
    public let sequence: UInt64
    public let presentationTimeNanoseconds: UInt64
    public let isKeyFrame: Bool
    /// Codec-specific decoder configuration. For H.264 this carries the
    /// SPS/PPS payload on a recovery keyframe.
    public let codecConfiguration: Data?
    public let payload: Data

    public init(
        sequence: UInt64,
        presentationTimeNanoseconds: UInt64,
        isKeyFrame: Bool,
        codecConfiguration: Data? = nil,
        payload: Data
    ) {
        self.sequence = sequence
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.isKeyFrame = isKeyFrame
        self.codecConfiguration = codecConfiguration
        self.payload = payload
    }
}

public enum EncodedVideoFrameCodec {
    public static let maximumPayloadLength = 4 * 1024 * 1024
    public static let maximumCodecConfigurationLength = 64 * 1024
    private static let magic: UInt32 = 0x434C5646
    private static let headerLength = 4 + 8 + 8 + 1 + 4 + 4

    public static func encode(_ packet: EncodedVideoFramePacket) throws -> Data {
        let codecConfiguration = packet.codecConfiguration ?? Data()
        guard codecConfiguration.count <= maximumCodecConfigurationLength,
              packet.payload.count <= maximumPayloadLength - codecConfiguration.count else {
            throw SensoriumProtocolError.frameTooLarge
        }
        var output = Data()
        append(UInt32(magic), to: &output)
        append(packet.sequence, to: &output)
        append(packet.presentationTimeNanoseconds, to: &output)
        output.append(packet.isKeyFrame ? 1 : 0)
        append(UInt32(codecConfiguration.count), to: &output)
        append(UInt32(packet.payload.count), to: &output)
        output.append(codecConfiguration)
        output.append(packet.payload)
        return output
    }

    public static func decode(_ data: Data) throws -> EncodedVideoFramePacket {
        guard data.count >= headerLength else {
            throw SensoriumProtocolError.frameTooShort
        }
        guard readUInt32(data, at: 0) == magic else {
            throw SensoriumProtocolError.malformedMessage
        }
        let codecConfigurationLength = Int(readUInt32(data, at: 21))
        let payloadLength = Int(readUInt32(data, at: 25))
        guard codecConfigurationLength <= maximumCodecConfigurationLength,
              payloadLength <= maximumPayloadLength - codecConfigurationLength else {
            throw SensoriumProtocolError.frameTooLarge
        }
        guard data.count == headerLength + codecConfigurationLength + payloadLength else {
            throw SensoriumProtocolError.frameLengthMismatch
        }
        let flags = data[20]
        guard flags & ~UInt8(1) == 0 else {
            throw SensoriumProtocolError.malformedMessage
        }
        // A presentation time is a monotonic nanosecond count, so nothing a
        // host sends reaches the top bit. A viewer expresses the field as a
        // signed `CMTime` value, which a number past `Int64.max` does not fit
        // in at all, so it is refused here rather than carried further as a
        // timestamp nothing can use.
        let presentationTimeNanoseconds = readUInt64(data, at: 12)
        guard presentationTimeNanoseconds <= UInt64(Int64.max) else {
            throw SensoriumProtocolError.malformedMessage
        }
        return EncodedVideoFramePacket(
            sequence: readUInt64(data, at: 4),
            presentationTimeNanoseconds: presentationTimeNanoseconds,
            isKeyFrame: flags == 1,
            codecConfiguration: codecConfigurationLength == 0
                ? nil
                : Data(data[headerLength..<(headerLength + codecConfigurationLength)]),
            payload: Data(data.dropFirst(headerLength + codecConfigurationLength))
        )
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { bytes in
            UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
        }
    }

    private static func readUInt64(_ data: Data, at offset: Int) -> UInt64 {
        data.withUnsafeBytes { bytes in
            UInt64(bigEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt64.self))
        }
    }
}

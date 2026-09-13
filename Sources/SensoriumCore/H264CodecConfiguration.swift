import Foundation

public struct H264CodecConfiguration: Equatable, Sendable {
    public let sequenceParameterSet: Data
    public let pictureParameterSet: Data

    public init(sequenceParameterSet: Data, pictureParameterSet: Data) {
        self.sequenceParameterSet = sequenceParameterSet
        self.pictureParameterSet = pictureParameterSet
    }
}

public enum H264CodecConfigurationCodec {
    public static func encode(_ configuration: H264CodecConfiguration) throws -> Data {
        guard !configuration.sequenceParameterSet.isEmpty,
              !configuration.pictureParameterSet.isEmpty,
              configuration.sequenceParameterSet.count <= EncodedVideoFrameCodec.maximumCodecConfigurationLength,
              configuration.pictureParameterSet.count <= EncodedVideoFrameCodec.maximumCodecConfigurationLength - configuration.sequenceParameterSet.count else {
            throw SensoriumProtocolError.frameTooLarge
        }
        var output = Data()
        append(UInt32(configuration.sequenceParameterSet.count), to: &output)
        output.append(configuration.sequenceParameterSet)
        append(UInt32(configuration.pictureParameterSet.count), to: &output)
        output.append(configuration.pictureParameterSet)
        return output
    }

    public static func decode(_ data: Data) throws -> H264CodecConfiguration {
        guard data.count >= 8 else {
            throw SensoriumProtocolError.frameTooShort
        }
        let spsLength = Int(readUInt32(data, at: 0))
        guard spsLength > 0,
              spsLength <= EncodedVideoFrameCodec.maximumCodecConfigurationLength,
              data.count >= 4 + spsLength + 4 else {
            throw SensoriumProtocolError.malformedMessage
        }
        let ppsLengthOffset = 4 + spsLength
        let ppsLength = Int(readUInt32(data, at: ppsLengthOffset))
        guard ppsLength > 0,
              ppsLength <= EncodedVideoFrameCodec.maximumCodecConfigurationLength - spsLength,
              data.count == ppsLengthOffset + 4 + ppsLength else {
            throw SensoriumProtocolError.malformedMessage
        }
        return H264CodecConfiguration(
            sequenceParameterSet: Data(data[4..<(4 + spsLength)]),
            pictureParameterSet: Data(data[(ppsLengthOffset + 4)...])
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
}

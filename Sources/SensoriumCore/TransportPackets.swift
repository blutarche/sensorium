import Foundation

public enum SensoriumTransportPacket: Equatable, Sendable {
    case control(SensoriumMessage)
    case video(EncodedVideoFramePacket)
    /// Video for one of the (currently at most two) session-owned canvases.
    /// `surfaceID` must be 0 or 1: the cap is two, and an unbounded value
    /// would let a viewer key an unbounded map.
    case videoForSurface(surfaceID: UInt32, frame: EncodedVideoFramePacket)
    /// One machine's pasteboard, offered to the other. Session-scoped, not
    /// surface-scoped: there is one pasteboard per machine however many
    /// canvases the session opened, so this carries no `surfaceID`.
    case clipboard(ClipboardContent)
    /// A tag this build does not recognise, e.g. sent by a newer peer. The
    /// frame's length prefix makes it trivially skippable: carry the tag and
    /// payload through rather than treating an unknown tag as fatal.
    case unrecognized(tag: UInt8, payload: Data)
}

public enum SensoriumTransportPacketCodec {
    public static let maximumPayloadLength = EncodedVideoFrameCodec.maximumPayloadLength + 64

    public static func encode(_ packet: SensoriumTransportPacket) throws -> Data {
        let tag: UInt8
        let payload: Data
        switch packet {
        case let .control(message):
            tag = 0
            payload = try SensoriumFrameCodec.encode(message)
        case let .video(frame):
            tag = 1
            payload = try EncodedVideoFrameCodec.encode(frame)
        case let .videoForSurface(surfaceID, frame):
            guard surfaceID == 0 || surfaceID == 1 else {
                throw SensoriumProtocolError.malformedMessage
            }
            tag = 2
            var surfacePayload = Data()
            var surfaceIDBigEndian = surfaceID.bigEndian
            withUnsafeBytes(of: &surfaceIDBigEndian) { surfacePayload.append(contentsOf: $0) }
            surfacePayload.append(try EncodedVideoFrameCodec.encode(frame))
            payload = surfacePayload
        case let .clipboard(content):
            tag = 3
            payload = try ClipboardPacketCodec.encode(content)
        case let .unrecognized(unrecognizedTag, unrecognizedPayload):
            tag = unrecognizedTag
            payload = unrecognizedPayload
        }
        guard payload.count <= maximumPayloadLength else {
            throw SensoriumProtocolError.frameTooLarge
        }
        var output = Data([tag])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { output.append(contentsOf: $0) }
        output.append(payload)
        return output
    }

    public static func decode(_ data: Data) throws -> SensoriumTransportPacket {
        guard data.count >= 5 else {
            throw SensoriumProtocolError.frameTooShort
        }
        let payloadLength = Int(data.withUnsafeBytes { bytes in
            UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 1, as: UInt32.self))
        })
        guard payloadLength <= maximumPayloadLength else {
            throw SensoriumProtocolError.frameTooLarge
        }
        guard data.count == 5 + payloadLength else {
            throw SensoriumProtocolError.frameLengthMismatch
        }
        let payload = Data(data.dropFirst(5))
        // Indexed from `startIndex`, not from zero: `data` may be a slice of a
        // larger receive buffer, and `Data`'s subscript is absolute.
        let tag = data[data.startIndex]
        switch tag {
        case 0:
            return .control(try SensoriumFrameCodec.decode(payload))
        case 1:
            return .video(try EncodedVideoFrameCodec.decode(payload))
        case 2:
            guard payload.count >= 4 else {
                throw SensoriumProtocolError.frameTooShort
            }
            let surfaceID = payload.withUnsafeBytes { bytes in
                UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 0, as: UInt32.self))
            }
            guard surfaceID == 0 || surfaceID == 1 else {
                throw SensoriumProtocolError.malformedMessage
            }
            let framePayload = Data(payload.dropFirst(4))
            return .videoForSurface(surfaceID: surfaceID, frame: try EncodedVideoFrameCodec.decode(framePayload))
        case 3:
            return .clipboard(try ClipboardPacketCodec.decode(payload))
        default:
            return .unrecognized(tag: tag, payload: payload)
        }
    }
}

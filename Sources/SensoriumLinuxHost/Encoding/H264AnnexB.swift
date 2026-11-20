#if os(Linux)
import Foundation

/// One encoder output, re-framed the way the macOS host sends it.
public struct H264AccessUnit: Equatable, Sendable {
    /// The picture's NAL units, each preceded by its length as four bytes,
    /// big endian. Parameter sets and access-unit delimiters are not in it.
    public let payload: Data
    /// Raw NAL units, header byte included and no start code.
    public let sequenceParameterSet: Data?
    public let pictureParameterSet: Data?
    /// Whether the picture holds an IDR slice (NAL unit type 5).
    public let containsIDR: Bool
}

/// libavcodec's H.264 encoders emit Annex B: NAL units separated by three- or
/// four-byte start codes. The viewer reads length-prefixed units with the
/// parameter sets sent beside them, as VideoToolbox produces them, so every
/// output is re-framed here.
public enum H264AnnexB {
    public static func reframe(_ annexB: Data) -> H264AccessUnit {
        var payload = Data()
        var sps: Data?
        var pps: Data?
        var containsIDR = false
        for nal in nalUnits(in: annexB) {
            switch nal[nal.startIndex] & 0x1F {
            case 7:
                sps = nal
            case 8:
                pps = nal
            case 9:
                break
            case let type:
                containsIDR = containsIDR || type == 5
                var length = UInt32(nal.count).bigEndian
                withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
                payload.append(nal)
            }
        }
        return H264AccessUnit(
            payload: payload,
            sequenceParameterSet: sps,
            pictureParameterSet: pps,
            containsIDR: containsIDR
        )
    }

    /// Splits an Annex B buffer into NAL units without their start codes.
    /// Zero bytes just before a start code are the next unit's lead-in, not
    /// part of this one: a NAL unit never ends in a zero byte.
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var starts: [(codeStart: Int, nalStart: Int)] = []
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                starts.append((index, index + 3))
                index += 3
            } else {
                index += 1
            }
        }
        var units: [Data] = []
        for (position, start) in starts.enumerated() {
            var end = position + 1 < starts.count ? starts[position + 1].codeStart : bytes.count
            while end > start.nalStart, bytes[end - 1] == 0 {
                end -= 1
            }
            if end > start.nalStart {
                units.append(Data(bytes[start.nalStart..<end]))
            }
        }
        return units
    }
}
#endif

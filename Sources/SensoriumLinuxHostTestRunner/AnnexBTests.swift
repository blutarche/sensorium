#if os(Linux)
import Foundation
import SensoriumLinuxHost

func testAnnexBIsReframedAsLengthPrefixedWithoutParameterSets() {
    let delimiter = Data([0x09, 0xF0])
    let sps = Data([0x67, 0x42, 0xC0, 0x1E, 0xAA])
    let pps = Data([0x68, 0xCE, 0x3C, 0x80])
    let sei = Data([0x06, 0x05, 0x01, 0xFF])
    // An IDR slice that itself contains zero bytes, and one ending in a
    // trailing zero that belongs to the next start code, not to the slice.
    let idr = Data([0x65, 0x88, 0x00, 0x00, 0x03, 0x01, 0x42])
    let fourByte = Data([0, 0, 0, 1])
    let threeByte = Data([0, 0, 1])
    var stream = Data()
    stream.append(fourByte); stream.append(delimiter)
    stream.append(fourByte); stream.append(sps)
    stream.append(threeByte); stream.append(pps)
    stream.append(fourByte); stream.append(sei)
    stream.append(Data([0]))  // trailing_zero_8bits before the next start code
    stream.append(fourByte); stream.append(idr)
    let unit = H264AnnexB.reframe(stream)
    expect(unit.sequenceParameterSet == sps, "the SPS comes out raw, header byte included")
    expect(unit.pictureParameterSet == pps, "the PPS comes out raw, header byte included")
    expect(unit.containsIDR, "an IDR slice is recognised by its NAL unit type")
    var expected = Data()
    for nal in [sei, idr] {
        expected.append(contentsOf: withUnsafeBytes(of: UInt32(nal.count).bigEndian, Array.init))
        expected.append(nal)
    }
    expect(unit.payload == expected, "the payload is the SEI and slice, four-byte length prefixed, nothing else")
}

func testAnnexBNonIDRSliceCarriesNoKeyFlagOrParameterSets() {
    let slice = Data([0x41, 0x9A, 0x01, 0x02])
    var stream = Data([0, 0, 0, 1])
    stream.append(slice)
    let unit = H264AnnexB.reframe(stream)
    expect(!unit.containsIDR, "a P slice is not an IDR")
    expect(unit.sequenceParameterSet == nil && unit.pictureParameterSet == nil, "no parameter sets were in it")
    expect(unit.payload.count == 4 + slice.count, "the slice is the whole payload")
    expect(H264AnnexB.reframe(Data()).payload.isEmpty, "an empty buffer reframes to nothing")
}
#endif

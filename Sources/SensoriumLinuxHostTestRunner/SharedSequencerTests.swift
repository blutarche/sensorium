#if os(Linux)
import Foundation
import SensoriumCore
import SensoriumHost
import SensoriumLinuxHost

/// A host-screen session numbers every packet it sends from one shared
/// sequencer, across every encoder it builds in turn; the Linux encoder takes
/// that same sequencer, so its packets continue the session's count.
func testTheEncoderContinuesTheSessionsSharedSequence() throws {
    let sequencer = VideoPacketSequencer()
    for _ in 0..<3 {
        _ = sequencer.packet(presentationTimeNanoseconds: 0, isKeyFrame: false, codecConfiguration: nil, payload: Data())
    }
    let log = OutcomeLog()
    let encoder = try LinuxH264Encoder(
        configuration: LinuxEncoderConfiguration(width: 178, height: 98, backendPreference: .openH264),
        sequencer: sequencer,
        outcomeHandler: { log.append($0) }
    )
    for index in 0..<2 {
        try encoder.encode(syntheticFrame(index: index, width: 178, height: 98))
    }
    expect(log.packets.map(\.sequence) == [3, 4], "the encoder continued at 3, saw \(log.packets.map(\.sequence))")
}
#endif

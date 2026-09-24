import Foundation
import SensoriumClient
import SensoriumCore

/// A decoder that records what it was handed instead of decoding it. The
/// real conformer on macOS is `VideoToolboxDecoder`; a platform without
/// VideoToolbox supplies its own, which is what the seam exists for.
private final class FakeVideoDecoder: VideoDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private var packets: [EncodedVideoFramePacket] = []
    private var resets = 0
    private let reported: DecoderHardwareAccelerationStatus?

    init(reported: DecoderHardwareAccelerationStatus? = .softwareFallback) {
        self.reported = reported
    }

    func decode(_ packet: EncodedVideoFramePacket) throws {
        lock.lock()
        defer { lock.unlock() }
        packets.append(packet)
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        resets += 1
    }

    var hardwareAcceleration: DecoderHardwareAccelerationStatus? { reported }

    var decodedSequences: [UInt64] {
        lock.lock()
        defer { lock.unlock() }
        return packets.map(\.sequence)
    }

    var resetCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return resets
    }
}

private func makePacket(sequence: UInt64) -> EncodedVideoFramePacket {
    EncodedVideoFramePacket(
        sequence: sequence,
        presentationTimeNanoseconds: sequence * 16_666_667,
        isKeyFrame: sequence == 0,
        payload: Data([0x00, 0x01, UInt8(sequence & 0xFF)])
    )
}

/// Waits for the decode queue's own serial queue to catch up, rather than
/// assuming a submit already decoded.
private func waitFor(_ condition: @Sendable () -> Bool) async -> Bool {
    for _ in 0..<400 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
func testVideoDecodingSeamTests() async {
    do {
        let fake = FakeVideoDecoder()
        let receipts = FrameReceiptLedger()
        let seenReceipts = UncheckedFlag()
        let pipeline = VideoDecodePipeline(
            receipts: receipts,
            drops: nil,
            makeDecoder: { handedReceipts, _ in
                seenReceipts.set(handedReceipts === receipts)
                return fake
            },
            present: { _ in }
        )
        expect(pipeline.decoder === fake, "the pipeline holds the decoder its factory returned")
        expect(seenReceipts.value, "the factory is handed the receipt ledger the pipeline was built with")

        pipeline.decodeQueue.submit(makePacket(sequence: 0))
        pipeline.decodeQueue.submit(makePacket(sequence: 1))
        let decoded = await waitFor { fake.decodedSequences == [0, 1] }
        expect(decoded, "every submitted packet reaches the injected decoder -- got \(fake.decodedSequences)")
        print("PASS: the injected decoder is the one the decode path uses")
    }

    do {
        let fake = FakeVideoDecoder(reported: .hardwareAccelerated)
        let pipeline = VideoDecodePipeline(
            receipts: nil,
            drops: nil,
            makeDecoder: { _, _ in fake },
            present: { _ in }
        )
        expect(
            pipeline.decoder.hardwareAcceleration == .hardwareAccelerated,
            "the acceleration reading comes from the injected decoder"
        )
        pipeline.decoder.reset()
        expect(fake.resetCount == 1, "a reset reaches the injected decoder -- got \(fake.resetCount)")
        print("PASS: acceleration readings and resets go to the injected decoder")
    }
}

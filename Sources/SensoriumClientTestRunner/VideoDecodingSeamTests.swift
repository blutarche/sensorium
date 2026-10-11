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

/// A decoder that, like the real ones, reads each packet's receipt back out
/// of the ledger it was built with. The real decoders do that in their output
/// path; doing it on submission here sees the receipt exactly as the
/// pipeline left it for that path.
private final class ReceiptReadingDecoder: VideoDecoding, @unchecked Sendable {
    private let lock = NSLock()
    private let ledger: FrameReceiptLedger?
    private var taken: [FrameReceipt?] = []

    init(ledger: FrameReceiptLedger?) {
        self.ledger = ledger
    }

    func decode(_ packet: EncodedVideoFramePacket) throws {
        let receipt = ledger?.takeReceipt(
            forPresentationTimeNanoseconds: Int64(bitPattern: packet.presentationTimeNanoseconds)
        )
        lock.lock()
        defer { lock.unlock() }
        taken.append(receipt)
    }

    func reset() {}

    var hardwareAcceleration: DecoderHardwareAccelerationStatus? { nil }

    var receipts: [FrameReceipt?] {
        lock.lock()
        defer { lock.unlock() }
        return taken
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

    // The moment a packet is handed to the decoder is what splits its decode
    // time into the wait ahead of the decoder and the decoder itself, and the
    // receipt ledger is the only thing that reaches the decoder's output.
    do {
        let ledger = FrameReceiptLedger()
        let decoder = ReceiptReadingDecoder(ledger: ledger)
        let pipeline = VideoDecodePipeline(
            receipts: ledger,
            drops: nil,
            makeDecoder: { _, _ in decoder },
            now: { 7_500 },
            present: { _ in }
        )
        let packet = makePacket(sequence: 0)
        ledger.record(
            presentationTimeNanoseconds: Int64(bitPattern: packet.presentationTimeNanoseconds),
            receivedAtNanoseconds: 1_000
        )
        pipeline.decodeQueue.submit(packet)
        let decoded = await waitFor { decoder.receipts.count == 1 }
        expect(
            decoded && decoder.receipts == [FrameReceipt(receivedAtNanoseconds: 1_000, submittedAtNanoseconds: 7_500)],
            "the decoder finds the packet's submission time beside its receipt -- got \(decoder.receipts)"
        )

        // A packet whose receipt was never recorded, or has been evicted, has
        // no receipt to stamp: submitting it must not invent one.
        pipeline.decodeQueue.submit(makePacket(sequence: 1))
        let decodedUnreceipted = await waitFor { decoder.receipts.count == 2 }
        expect(
            decodedUnreceipted && decoder.receipts.last == .some(nil),
            "a packet with no receipt is decoded without one -- got \(decoder.receipts)"
        )
        expect(ledger.outstandingCount == 0, "stamping a submission never adds a receipt to the ledger")

        ledger.record(presentationTimeNanoseconds: 42, receivedAtNanoseconds: 2_000)
        expect(
            ledger.takeReceipt(forPresentationTimeNanoseconds: 42)
                == FrameReceipt(receivedAtNanoseconds: 2_000, submittedAtNanoseconds: nil),
            "a receipt that was never handed to a decoder carries no submission time"
        )
        print("PASS: the decode path stamps each packet's submission beside its receipt for the decoder's output")
    }
}

import Foundation

/// Carries the viewer-side receive time from the receive loop to the
/// VideoToolbox output callback, which runs on its own thread and is handed only
/// the presentation timestamp.
///
/// One ledger per window (`ClientCanvasWindowController` owns its own
/// instance, never shared) -- two displays sampled off the same host clock
/// can land on the same presentation timestamp, but that only matters within
/// one ledger, and a window never has two decoders feeding it. So the key is
/// presentation time alone.
///
/// Bounded: a decoder that swallows frames must not turn the ledger into a leak,
/// and an old receipt is worthless anyway.
public final class FrameReceiptLedger: @unchecked Sendable {
    public static let maximumOutstanding = 64

    private let lock = NSLock()
    private var order: [Int64] = []
    private var receipts: [Int64: Int64] = [:]

    public init() {}

    public var outstandingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return order.count
    }

    public func record(presentationTimeNanoseconds: Int64, receivedAtNanoseconds: Int64) {
        lock.lock()
        defer { lock.unlock() }
        if receipts.updateValue(receivedAtNanoseconds, forKey: presentationTimeNanoseconds) == nil {
            order.append(presentationTimeNanoseconds)
        }
        while order.count > Self.maximumOutstanding {
            receipts.removeValue(forKey: order.removeFirst())
        }
    }

    public func takeReceipt(forPresentationTimeNanoseconds presentationTime: Int64) -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        guard let receipt = receipts.removeValue(forKey: presentationTime) else {
            return nil
        }
        order.removeAll { $0 == presentationTime }
        return receipt
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        order = []
        receipts = [:]
    }
}

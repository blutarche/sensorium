import Foundation

public enum ControlChannelError: Error, Equatable {
    case closed
}

public actor InMemoryControlChannel: SensoriumControlTransport {
    private var queuedMessages: [SensoriumMessage] = []
    private var receivers: [CheckedContinuation<SensoriumMessage, Error>] = []
    private var isClosed = false
    public let deferredPackets = DeferredPacketQueue()

    public init() {}

    public func send(_ message: SensoriumMessage) throws {
        guard !isClosed else {
            throw ControlChannelError.closed
        }
        if let receiver = receivers.first {
            receivers.removeFirst()
            receiver.resume(returning: message)
        } else {
            queuedMessages.append(message)
        }
    }

    public func receiveWirePacket() async throws -> SensoriumTransportPacket {
        if let message = queuedMessages.first {
            queuedMessages.removeFirst()
            return .control(message)
        }
        guard !isClosed else {
            throw ControlChannelError.closed
        }
        return .control(try await withCheckedThrowingContinuation { continuation in
            receivers.append(continuation)
        })
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        let pendingReceivers = receivers
        receivers.removeAll()
        for receiver in pendingReceivers {
            receiver.resume(throwing: ControlChannelError.closed)
        }
    }
}

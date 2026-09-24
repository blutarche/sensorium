#if canImport(Network)
import Foundation
import Network
import SensoriumCore
import Security

/// NWConnection can report several terminal states; a continuation may only be
/// resumed once.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func resume(_ continuation: CheckedContinuation<Void, Error>, with error: Error?) {
        lock.lock()
        if done {
            lock.unlock()
            return
        }
        done = true
        lock.unlock()
        if let error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

public final class NetworkControlConnection: ClientControlConnection, @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "com.sensorium.control-connection")
    private let pinMismatchFlag = PinMismatchFlag()
    private let silenceWatchdog: SilenceWatchdog
    public let deferredPackets = DeferredPacketQueue()
    /// The certificate this link was pinned to, carried so the hello sent
    /// over it can name and sign the host it is actually talking to.
    public let pinnedHostCertificateHash: Data?

    public static let defaultHostSilenceTimeout = ClientControlDialing.defaultHostSilenceTimeout

    public typealias DialTermination = SensoriumClient.DialTermination

    /// `nil` is allowed only during the one-time pairing ceremony; the signed
    /// pairing approval binds the returned certificate hash to the host key.
    /// Every saved-host reconnect passes the persisted hash and rejects any
    /// different self-signed certificate.
    public init(
        host: NWEndpoint.Host,
        port: NWEndpoint.Port,
        tlsCertificateHash: Data? = nil,
        transport: ClientTransportKind = .quic
    ) {
        let nwConnection = NWConnection(
            host: host,
            port: port,
            using: Self.parameters(
                tlsCertificateHash: tlsCertificateHash,
                transport: transport,
                pinMismatchFlag: pinMismatchFlag
            )
        )
        connection = nwConnection
        pinnedHostCertificateHash = tlsCertificateHash
        silenceWatchdog = SilenceWatchdog(timeout: Self.defaultHostSilenceTimeout) {
            nwConnection.cancel()
        }
    }

    public static func certificatePinMatches(certificateDER: Data, expectedHash: Data) -> Bool {
        ClientControlDialing.certificatePinMatches(
            certificateDER: certificateDER,
            expectedHash: expectedHash
        )
    }

    public static func parameters(
        tlsCertificateHash: Data?,
        transport: ClientTransportKind = .quic
    ) -> NWParameters {
        parameters(tlsCertificateHash: tlsCertificateHash, transport: transport, pinMismatchFlag: nil)
    }

    private static func parameters(
        tlsCertificateHash: Data?,
        transport: ClientTransportKind,
        pinMismatchFlag: PinMismatchFlag?
    ) -> NWParameters {
        guard transport == .quic else {
            return .tcp
        }
        let quic = NWProtocolQUIC.Options()
        // The silence watchdog on this connection is what actually ends a
        // dead link: it does not wait on the OS to give up on the socket,
        // which in the field can run far longer than this value. This idle
        // timeout is only a backstop underneath it.
        quic.idleTimeout = 30_000
        sec_protocol_options_add_tls_application_protocol(
            quic.securityProtocolOptions,
            "com.sensorium.control-v1"
        )
        sec_protocol_options_set_verify_block(
            quic.securityProtocolOptions,
            { _, trust, complete in
                guard let tlsCertificateHash else {
                    // Safe only for the first pairing exchange: `pairApproved`
                    // is signed by the returned Ed25519 host identity and binds
                    // its certificate hash before it is persisted.
                    complete(true)
                    return
                }
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                guard let certificateChain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                      let certificate = certificateChain.first else {
                    complete(false)
                    return
                }
                let matches = certificatePinMatches(
                    certificateDER: SecCertificateCopyData(certificate) as Data,
                    expectedHash: tlsCertificateHash
                )
                if !matches {
                    pinMismatchFlag?.recordMismatch()
                }
                complete(matches)
            },
            DispatchQueue(label: "com.sensorium.tls-verify")
        )
        return NWParameters(quic: quic)
    }

    /// Dialling has its own deadline: a machine that accepts and then stalls, or a
    /// route that never completes, must surface as an error rather than a viewer
    /// that sits there printing nothing.
    public func start(timeout: TimeInterval = SessionTimeouts.remoteDefault.handshake) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                try await openConnection()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw NetworkControlConnectionError.timedOut
            }
            do {
                try await group.next()
                group.cancelAll()
            } catch {
                group.cancelAll()
                connection.cancel()
                let termination: DialTermination = (error as? NetworkControlConnectionError == .timedOut)
                    ? .timedOut
                    : .failed(error)
                throw Self.resolveDialError(termination, pinMismatchObserved: pinMismatchFlag.observed)
            }
        }
    }

    public static func resolveDialError(
        _ termination: DialTermination,
        pinMismatchObserved: Bool
    ) -> any Error {
        ClientControlDialing.resolveDialError(termination, pinMismatchObserved: pinMismatchObserved)
    }

    private func openConnection() async throws {
        let resumed = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    resumed.resume(continuation, with: nil)
                case let .failed(error):
                    resumed.resume(continuation, with: error)
                case .cancelled:
                    resumed.resume(continuation, with: NetworkControlConnectionError.peerFailed)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    /// Arms the silence watchdog. Never automatic: a connection sits ready
    /// but silent for as long as pairing's own retyped-digit flow or a
    /// session's pre-live handshake need, both already bounded by their own
    /// timeouts. `ClientSessionRunner` is the one caller, once a session is
    /// live and expected to hear from the host on its own schedule.
    /// Idempotent.
    public func beginHostSilenceWatch() {
        silenceWatchdog.start()
    }

    /// Disarms the silence watchdog. Idempotent, and safe to call on a
    /// connection that was never armed.
    public func endHostSilenceWatch() {
        silenceWatchdog.stop()
    }

    public func send(_ message: SensoriumMessage) async throws {
        try await sendRaw(try SensoriumTransportPacketCodec.encode(.control(message)))
    }

    public func send(_ packet: SensoriumTransportPacket) async throws {
        try await sendRaw(SensoriumTransportPacketCodec.encode(packet))
    }

    /// Hands `packet` to the connection before returning, so it goes out
    /// ahead of anything sent after this call, whichever task sends it. A
    /// packet that cannot be encoded, or a send that fails, is dropped: a
    /// dead connection is reported by the receive loop.
    public func enqueue(_ packet: SensoriumTransportPacket) {
        guard let frame = try? SensoriumTransportPacketCodec.encode(packet) else {
            return
        }
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    public func receiveWirePacket() async throws -> SensoriumTransportPacket {
        let header = try await receiveBytes(count: 5)
        let payloadLength = header.withUnsafeBytes { bytes in
            UInt32(bigEndian: bytes.loadUnaligned(fromByteOffset: 1, as: UInt32.self))
        }
        guard payloadLength <= SensoriumTransportPacketCodec.maximumPayloadLength else {
            throw SensoriumProtocolError.frameTooLarge
        }
        let payload = try await receiveBytes(count: Int(payloadLength))
        var packet = header
        packet.append(payload)
        return try SensoriumTransportPacketCodec.decode(packet)
    }

    private func sendRaw(_ frame: Data) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: frame, completion: .contentProcessed { error in
                if error == nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: NetworkControlConnectionError.closed)
                }
            })
        }
    }

    public func close() async {
        silenceWatchdog.stop()
        connection.cancel()
    }

    private func receiveBytes(count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        return try await withCheckedThrowingContinuation { continuation in
            connection.receive(
                minimumIncompleteLength: count,
                maximumLength: count
            ) { data, _, isComplete, error in
                if let data, data.count == count {
                    self.silenceWatchdog.heard()
                    continuation.resume(returning: data)
                } else if isComplete || error != nil {
                    continuation.resume(throwing: NetworkControlConnectionError.closed)
                } else {
                    continuation.resume(throwing: NetworkControlConnectionError.notReady)
                }
            }
        }
    }
}
#endif

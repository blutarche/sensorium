import Foundation
import SensoriumCore

/// Everything one viewer QUIC session is dialled with. The application
/// protocol and the server name are fixed for the whole product rather than
/// per-host: the host answers to exactly one ALPN, and its certificate is
/// self-signed and pinned, so the name in SNI identifies the service and
/// never a public DNS record.
public struct QUICSessionParameters: Equatable, Sendable {
    public static let applicationProtocol = "com.sensorium.control-v1"
    public static let serverName = "sensorium-host"

    public let host: String
    public let port: UInt16
    /// `nil` is allowed only during the one-time pairing ceremony; see
    /// `QUICPeerCertificateVerification.accepts`.
    public let tlsCertificateHash: Data?

    public var applicationProtocol: String { Self.applicationProtocol }
    public var serverName: String { Self.serverName }

    public init(host: String, port: UInt16, tlsCertificateHash: Data?) {
        self.host = host
        self.port = port
        self.tlsCertificateHash = tlsCertificateHash
    }
}

/// The decision a TLS verify callback makes about the host's certificate,
/// kept out of the callback so it is measured without a handshake.
public enum QUICPeerCertificateVerification {
    /// Whether the handshake may continue, recording a mismatch on `flag` so
    /// the dial can report the one reason TLS itself will not carry.
    public static func accepts(
        leafCertificateDER: Data?,
        pin: Data?,
        mismatchFlag: PinMismatchFlag
    ) -> Bool {
        guard let pin else {
            // Safe only for the first pairing exchange: `pairApproved` is
            // signed by the returned Ed25519 host identity and binds its
            // certificate hash before it is persisted.
            return true
        }
        guard let leafCertificateDER else {
            // A peer that presented nothing has failed the pin exactly as
            // surely as one that presented the wrong certificate, and the
            // dial must say so rather than report a bare transport failure.
            mismatchFlag.recordMismatch()
            return false
        }
        let matches = ClientControlDialing.certificatePinMatches(
            certificateDER: leafCertificateDER,
            expectedHash: pin
        )
        if !matches {
            mismatchFlag.recordMismatch()
        }
        return matches
    }
}

/// What the handshake must have settled on. The host answers to exactly one
/// application protocol, so anything else means this is not a Sensorium host,
/// whatever else about the handshake succeeded.
public enum QUICApplicationProtocol {
    public static func isExpected(_ negotiated: String?) -> Bool {
        negotiated == QUICSessionParameters.applicationProtocol
    }
}

/// One QUIC connection carrying one bidirectional stream, reduced to what the
/// viewer's framing needs of it. Everything platform-specific -- name
/// resolution, the socket, the TLS stack, its threading -- lives behind this,
/// so the framing above it is verified with no socket at all.
public protocol QUICSessionIO: AnyObject, Sendable {
    /// Completes the handshake, offering `QUICSessionParameters`' application
    /// protocol and server name, and opens the one bidirectional stream.
    func connect() async throws
    func write(_ bytes: Data) async throws
    /// Queues `bytes` before returning, ahead of any `write` started after
    /// this call, without waiting for them to go out. A failure is dropped.
    func enqueueWrite(_ bytes: Data)
    /// Exactly `count` bytes. A stream that ends first throws
    /// `NetworkControlConnectionError.closed`. One reader at a time, which
    /// is what a receive loop over one stream is; a second concurrent reader
    /// throws `NetworkControlConnectionError.notReady` rather than splitting
    /// the stream between them.
    func read(count: Int) async throws -> Data
    /// Idempotent, and callable while a read is outstanding.
    func close()
}

/// The steps that end a QUIC session in the only order that leaves the peer
/// with an orderly ending rather than a connection that vanished.
public protocol QUICSessionTeardown: AnyObject {
    /// Marks this viewer's half of the stream finished.
    func concludeStream()
    /// One step of the connection shutdown, `true` once it has completed. A
    /// nonblocking shutdown returns before it is done, so it is driven
    /// rather than called once.
    func stepShutdown() -> Bool
    /// Releases the stream, the connection and everything under them.
    func releaseSession()
}

public enum QUICSessionClose {
    /// Ends a session and then frees it, reporting whether the peer
    /// acknowledged the close. Freeing before the shutdown has been driven
    /// loses whatever the peer has not acknowledged, and skipping the
    /// conclude leaves the peer reporting the session as dropped rather than
    /// ended. `hasTimeRemaining` bounds the drive: a peer that never
    /// acknowledges must not keep a viewer from exiting, and the wire is
    /// already closed to it either way.
    @discardableResult
    public static func perform(
        _ teardown: any QUICSessionTeardown,
        hasTimeRemaining: () -> Bool,
        wait: () -> Void
    ) -> Bool {
        teardown.concludeStream()
        var acknowledged = teardown.stepShutdown()
        while !acknowledged, hasTimeRemaining() {
            wait()
            acknowledged = teardown.stepShutdown()
        }
        teardown.releaseSession()
        return acknowledged
    }
}

/// Whether `close()` has run. Read from the receive loop and written by the
/// watchdog's own task, so it is lock-guarded rather than assumed
/// single-threaded.
private final class ConnectionClosedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func markClosed() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}

/// The viewer's control connection over any QUIC session: the 5 byte
/// `[tag:1][len:4 BE]` header and its payload, the dial deadline, the pin
/// outcome, and the silence watch. It owns no socket; `QUICSessionIO` does.
public final class QUICControlConnection: ClientControlConnection, @unchecked Sendable {
    private let io: any QUICSessionIO
    private let pinMismatchFlag: PinMismatchFlag
    private let silenceWatchdog: SilenceWatchdog
    private let closedFlag = ConnectionClosedFlag()
    public let deferredPackets = DeferredPacketQueue()

    /// The certificate this link was pinned to, carried so the hello sent
    /// over it can name and sign the host it is actually talking to.
    public let pinnedHostCertificateHash: Data?

    public init(
        io: any QUICSessionIO,
        pinMismatchFlag: PinMismatchFlag,
        pinnedHostCertificateHash: Data? = nil,
        silenceTimeout: Duration = ClientControlDialing.defaultHostSilenceTimeout
    ) {
        self.io = io
        self.pinMismatchFlag = pinMismatchFlag
        self.pinnedHostCertificateHash = pinnedHostCertificateHash
        let closed = closedFlag
        silenceWatchdog = SilenceWatchdog(timeout: silenceTimeout) {
            closed.markClosed()
            io.close()
        }
    }

    /// Dialling has its own deadline: a machine that accepts and then stalls, or a
    /// route that never completes, must surface as an error rather than a viewer
    /// that sits there printing nothing.
    public func start(timeout: TimeInterval = SessionTimeouts.remoteDefault.handshake) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [io] in
                try await io.connect()
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
                io.close()
                let termination: DialTermination = (error as? NetworkControlConnectionError == .timedOut)
                    ? .timedOut
                    : .failed(error)
                throw ClientControlDialing.resolveDialError(
                    termination,
                    pinMismatchObserved: pinMismatchFlag.observed
                )
            }
        }
    }

    /// Arms the silence watchdog. Never automatic: a connection sits ready
    /// but silent for as long as pairing's own retyped-digit flow or a
    /// session's pre-live handshake need, both already bounded by their own
    /// timeouts. Idempotent.
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
        try await sendRaw(try SensoriumTransportPacketCodec.encode(packet))
    }

    public func enqueue(_ packet: SensoriumTransportPacket) {
        guard !closedFlag.isClosed,
              let frame = try? SensoriumTransportPacketCodec.encode(packet) else {
            return
        }
        io.enqueueWrite(frame)
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

    public func close() async {
        silenceWatchdog.stop()
        closedFlag.markClosed()
        io.close()
    }

    private func sendRaw(_ frame: Data) async throws {
        guard !closedFlag.isClosed else {
            throw NetworkControlConnectionError.closed
        }
        do {
            try await io.write(frame)
        } catch {
            throw NetworkControlConnectionError.closed
        }
    }

    /// A read parked on a closed connection is ended by the session itself:
    /// `QUICSessionIO.close()` is required to be callable while a read is
    /// outstanding, and to make that read throw. Racing a second task against
    /// every read here instead would be one cancellable continuation per
    /// packet, which is a far easier thing to leave parked than the read it
    /// was meant to rescue.
    private func receiveBytes(count: Int) async throws -> Data {
        guard count > 0 else { return Data() }
        guard !closedFlag.isClosed else {
            throw NetworkControlConnectionError.closed
        }
        let bytes = try await io.read(count: count)
        silenceWatchdog.heard()
        return bytes
    }
}

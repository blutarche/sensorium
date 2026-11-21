#if os(Linux)
import COpenSSL
import Foundation
import Glibc
import SensoriumCore

/// The one application protocol the host answers to. It matches the macOS
/// host's listener, so a viewer cannot tell the two hosts apart.
///
/// The 30 s idle timeout the macOS host sets explicitly is not set here:
/// OpenSSL accepts `SSL_VALUE_QUIC_IDLE_TIMEOUT` on neither a listener nor a
/// connection it has already accepted (the latter fails with "feature not
/// renegotiable", and the Network.framework client then fails the handshake),
/// and the library's own default is the same 30 s. The test suite reads the
/// value the server advertises, so a library that changed the default would
/// be noticed.
private let applicationProtocol = "com.sensorium.control-v1"

/// How long a closing channel keeps trying to flush and be acknowledged
/// before it is freed regardless. A peer that has already gone must never
/// keep the host from letting go of it.
private let closeBoundSeconds: TimeInterval = 2.0

/// The server's own protocol list in TLS wire format: one length byte, then
/// the name. Allocated once and never freed, because the ALPN callback hands
/// OpenSSL a pointer into it.
nonisolated(unsafe) private let applicationProtocolWire: UnsafeMutablePointer<UInt8> = {
    let name = Array(applicationProtocol.utf8)
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: name.count + 1)
    buffer[0] = UInt8(name.count)
    for (index, byte) in name.enumerated() {
        buffer[index + 1] = byte
    }
    return buffer
}()

/// Selects the Sensorium protocol when the client offers it and refuses the
/// handshake otherwise. A QUIC connection with no agreed protocol is not one
/// this host wants, so there is no fall-through to "no ALPN".
private func sensoriumALPNSelect(
    _ ssl: OpaquePointer?,
    _ out: UnsafeMutablePointer<UnsafePointer<UInt8>?>?,
    _ outLength: UnsafeMutablePointer<UInt8>?,
    _ offered: UnsafePointer<UInt8>?,
    _ offeredLength: UInt32,
    _ argument: UnsafeMutableRawPointer?
) -> Int32 {
    let fatal = Int32(SSL_TLSEXT_ERR_ALERT_FATAL)
    guard let out, let outLength, let offered else {
        return fatal
    }
    let expected = Array(applicationProtocol.utf8)
    var index = 0
    let total = Int(offeredLength)
    while index < total {
        let length = Int(offered[index])
        guard index + 1 + length <= total else {
            return fatal
        }
        let candidate = UnsafeBufferPointer(start: offered + index + 1, count: length)
        if candidate.elementsEqual(expected) {
            out.pointee = UnsafePointer(applicationProtocolWire + 1)
            outLength.pointee = UInt8(expected.count)
            return Int32(SSL_TLSEXT_ERR_OK)
        }
        index += 1 + length
    }
    return fatal
}

public enum OpenSSLQUICServerError: Error, Equatable {
    case setupFailed
    case bindFailed
    /// The stream ended, the connection was lost, or the channel was
    /// cancelled.
    case closed
    /// A second read was started while one was outstanding.
    case notReady
}

/// One viewer's connection to the host, reduced to the byte stream a host
/// session runs over: the viewer's single bidirectional stream, once it has
/// been opened.
///
/// A channel is surfaced as soon as the handshake has finished and the
/// application protocol is confirmed. The viewer's stream only reaches the
/// host when the viewer first writes, and a pairing connection can sit
/// silent for a long time, so reads stay pending and writes stay queued
/// until the stream arrives.
///
/// The methods mirror `HostByteChannel` (`start`, `cancel`, `sendBytes`,
/// `receiveBytes(count:)`, `peerAddress`) so that protocol can be adopted
/// with a one-line adapter.
///
/// **Threading.** Every `SSL` call happens on the server's one event-loop
/// thread. These methods only queue work for it and wake it.
public final class OpenSSLQUICServerChannel: @unchecked Sendable {
    /// OpenSSL does not expose the peer address of a connection accepted
    /// from a listener, so the host log names none.
    public var peerAddress: String? { nil }

    /// The idle timeout, in milliseconds, this host asked for on the
    /// connection, and the one the two ends settled on (the smaller of the
    /// two requests). Read on the event loop when the handshake finished.
    public var requestedIdleTimeoutMilliseconds: UInt64? { lock.withLock { requestedIdle } }
    public var negotiatedIdleTimeoutMilliseconds: UInt64? { lock.withLock { negotiatedIdle } }

    private enum Phase {
        case handshaking
        case open
        case closing
        case done
    }

    private let lock = NSLock()
    private var pendingWrites: [(bytes: Data, continuation: CheckedContinuation<Void, any Error>?)] = []
    private var pendingRead: (count: Int, continuation: CheckedContinuation<Data, any Error>)?
    private var cancelRequested = false
    private var finished = false
    private let wake: @Sendable () -> Void

    /// Owned by the event-loop thread alone.
    private var phase = Phase.handshaking
    private var connection: OpaquePointer?
    private var stream: OpaquePointer?
    private var receiveBuffer = Data()
    private var writeOffset = 0
    private var concluded = false
    private var closeDeadline = Date.distantFuture
    private var requestedIdle: UInt64?
    private var negotiatedIdle: UInt64?

    init(connection: OpaquePointer, wake: @escaping @Sendable () -> Void) {
        self.connection = connection
        self.wake = wake
    }

    // MARK: - Public surface, any thread

    public func start() {}

    public func cancel() {
        lock.withLock { cancelRequested = true }
        wake()
    }

    public func sendBytes(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            enqueueWrite(data, continuation)
        }
    }

    public func receiveBytes(count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            enqueueRead(count, continuation)
        }
    }

    private func enqueueWrite(_ data: Data, _ continuation: CheckedContinuation<Void, any Error>) {
        let refused: Bool = lock.withLock {
            if finished || cancelRequested {
                return true
            }
            pendingWrites.append((data, continuation))
            return false
        }
        if refused {
            continuation.resume(throwing: OpenSSLQUICServerError.closed)
        } else {
            wake()
        }
    }

    private func enqueueRead(_ count: Int, _ continuation: CheckedContinuation<Data, any Error>) {
        let refusal: OpenSSLQUICServerError? = lock.withLock {
            if finished || cancelRequested {
                return .closed
            }
            if pendingRead != nil {
                return .notReady
            }
            pendingRead = (count, continuation)
            return nil
        }
        if let refusal {
            continuation.resume(throwing: refusal)
        } else {
            wake()
        }
    }

    // MARK: - Event loop only

    var isDone: Bool { phase == .done }

    /// Moves this channel forward as far as it can without waiting. Returns
    /// whether anything happened, so the loop knows not to sleep.
    func service(onEstablished: (OpenSSLQUICServerChannel) -> Void) -> Bool {
        guard phase != .done, let connection else { return false }
        if phase != .closing, lock.withLock({ cancelRequested }) {
            phase = .closing
            closeDeadline = Date().addingTimeInterval(closeBoundSeconds)
        }
        switch phase {
        case .handshaking:
            let result = SSL_do_handshake(connection)
            if result == 1 {
                return finishHandshake(onEstablished)
            }
            let reason = SSL_get_error(connection, result)
            if reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE {
                return false
            }
            release()
            return true
        case .open:
            var progressed = false
            if stream == nil {
                if let accepted = SSL_accept_stream(connection, 1) {
                    stream = accepted
                    // One stream carries the whole session; any further
                    // stream the peer opens is refused.
                    _ = SSL_set_incoming_stream_policy(
                        connection,
                        SSL_INCOMING_STREAM_POLICY_REJECT,
                        0
                    )
                    progressed = true
                } else if connectionHasClosed(connection) {
                    release()
                    return true
                }
            }
            if serviceWrites() { progressed = true }
            if serviceRead() { progressed = true }
            return progressed
        case .closing:
            return serviceClosing(connection)
        case .done:
            return false
        }
    }

    private func finishHandshake(_ onEstablished: (OpenSSLQUICServerChannel) -> Void) -> Bool {
        guard let connection else { return false }
        var selected: UnsafePointer<UInt8>?
        var length: UInt32 = 0
        SSL_get0_alpn_selected(connection, &selected, &length)
        let negotiated = selected.map {
            String(decoding: UnsafeBufferPointer(start: $0, count: Int(length)), as: UTF8.self)
        }
        guard negotiated == applicationProtocol else {
            release()
            return true
        }
        var requested: UInt64 = 0
        if SSL_get_value_uint(
            connection, UInt32(SSL_VALUE_CLASS_FEATURE_REQUEST), UInt32(SSL_VALUE_QUIC_IDLE_TIMEOUT), &requested
        ) == 1 {
            lock.withLock { requestedIdle = requested }
        }
        var settled: UInt64 = 0
        if SSL_get_value_uint(
            connection, UInt32(SSL_VALUE_CLASS_FEATURE_NEGOTIATED), UInt32(SSL_VALUE_QUIC_IDLE_TIMEOUT), &settled
        ) == 1 {
            lock.withLock { negotiatedIdle = settled }
        }
        phase = .open
        onEstablished(self)
        return true
    }

    private func connectionHasClosed(_ connection: OpaquePointer) -> Bool {
        var info = SSL_CONN_CLOSE_INFO()
        return SSL_get_conn_close_info(connection, &info, MemoryLayout<SSL_CONN_CLOSE_INFO>.size) == 1
    }

    private func serviceWrites() -> Bool {
        guard let stream else { return false }
        let next = lock.withLock { pendingWrites.first }
        guard let next else { return false }

        var written = 0
        let remaining = next.bytes.dropFirst(writeOffset)
        let result = remaining.withUnsafeBytes { bytes -> Int32 in
            guard let base = bytes.baseAddress else { return 1 }
            return SSL_write_ex(stream, base, bytes.count, &written)
        }
        guard result == 1 else {
            let reason = SSL_get_error(stream, 0)
            if reason == SSL_ERROR_WANT_WRITE || reason == SSL_ERROR_WANT_READ {
                return false
            }
            release()
            return true
        }
        writeOffset += written
        if writeOffset >= next.bytes.count {
            writeOffset = 0
            let finishedWrite = lock.withLock {
                pendingWrites.isEmpty ? nil : pendingWrites.removeFirst()
            }
            finishedWrite?.continuation?.resume()
        }
        return written > 0
    }

    private func serviceRead() -> Bool {
        guard let stream else { return false }
        let waiting = lock.withLock { pendingRead }
        guard let waiting else { return false }

        var progressed = false
        if receiveBuffer.count < waiting.count {
            var chunk = [UInt8](repeating: 0, count: max(waiting.count - receiveBuffer.count, 4096))
            var read = 0
            guard SSL_read_ex(stream, &chunk, chunk.count, &read) == 1 else {
                let reason = SSL_get_error(stream, 0)
                if reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE {
                    return false
                }
                release()
                return true
            }
            guard read > 0 else { return false }
            receiveBuffer.append(contentsOf: chunk[0..<read])
            progressed = true
        }
        guard receiveBuffer.count >= waiting.count else { return progressed }
        let delivered = Data(receiveBuffer.prefix(waiting.count))
        receiveBuffer.removeFirst(waiting.count)
        lock.withLock { pendingRead = nil }
        waiting.continuation.resume(returning: delivered)
        return true
    }

    /// Flushes what is queued, ends this host's half of the stream, and
    /// drives the connection's shutdown until the peer acknowledges it or the
    /// bound runs out.
    private func serviceClosing(_ connection: OpaquePointer) -> Bool {
        var progressed = false
        let expired = Date() >= closeDeadline
        let flushing = stream != nil && !expired && !lock.withLock({ pendingWrites.isEmpty })
        if flushing {
            return serviceWrites()
        }
        if let stream, !concluded {
            _ = SSL_stream_conclude(stream, 0)
            concluded = true
            progressed = true
        }
        if SSL_shutdown(connection) == 1 || expired {
            release()
            return true
        }
        return progressed
    }

    /// Fails everything still waiting and frees the connection: the stream
    /// first, then the connection.
    func release() {
        guard phase != .done else { return }
        phase = .done
        let (writes, reader) = lock.withLock { () -> ([(bytes: Data, continuation: CheckedContinuation<Void, any Error>?)], (count: Int, continuation: CheckedContinuation<Data, any Error>)?) in
            finished = true
            let writes = pendingWrites
            let reader = pendingRead
            pendingWrites = []
            pendingRead = nil
            return (writes, reader)
        }
        if let stream {
            SSL_free(stream)
            self.stream = nil
        }
        if let connection {
            SSL_free(connection)
            self.connection = nil
        }
        for write in writes {
            write.continuation?.resume(throwing: OpenSSLQUICServerError.closed)
        }
        reader?.continuation.resume(throwing: OpenSSLQUICServerError.closed)
    }

    func requestClose() {
        lock.withLock { cancelRequested = true }
    }
}

/// A QUIC server for the Linux host, on OpenSSL's own QUIC implementation.
///
/// One thread owns the listener and every connection it accepts. It sleeps in
/// `poll` on the UDP socket and on a wake pipe, bounded by
/// `SSL_get_event_timeout`, and runs `SSL_handle_events` on every wake; this
/// is the application-driven arrangement `openssl-quic(7)` describes, and
/// `openssl-quic-concurrency(7)` says the Contentive Concurrency Model it
/// uses is the one to pick when the application services the domain
/// regularly. A listener and its connections share one engine, so spreading
/// them across threads would only add locking.
public final class OpenSSLQUICServer: @unchecked Sendable {
    /// Connections that have finished the handshake with the Sensorium
    /// application protocol, in the order they arrived.
    public let channels: AsyncStream<OpenSSLQUICServerChannel>
    /// The UDP port the server listens on; the real one when `0` was asked
    /// for. Valid after `start()`.
    public private(set) var boundPort: UInt16 = 0

    private let identity: HostTLSIdentity
    private let bindAddress: String
    private let requestedPort: UInt16
    private let channelContinuation: AsyncStream<OpenSSLQUICServerChannel>.Continuation

    private let lock = NSLock()
    private var started = false
    private var stopRequested = false
    private let stopped = DispatchSemaphore(value: 0)

    private var context: OpaquePointer?
    private var listener: OpaquePointer?
    private var socketDescriptor: Int32 = -1
    private var wakeReadDescriptor: Int32 = -1
    private var wakeWriteDescriptor: Int32 = -1
    private var active: [OpenSSLQUICServerChannel] = []

    /// `bindAddress` is a literal IPv4 or IPv6 address. The caller decides
    /// which interface the host is reachable on; this type never widens it.
    public init(identity: HostTLSIdentity, bindAddress: String, port: UInt16) {
        self.identity = identity
        self.bindAddress = bindAddress
        requestedPort = port
        var continuation: AsyncStream<OpenSSLQUICServerChannel>.Continuation!
        channels = AsyncStream { continuation = $0 }
        channelContinuation = continuation
    }

    /// Binds the socket and starts listening. Throws if either fails.
    public func start() throws {
        let alreadyStarted = lock.withLock { () -> Bool in
            defer { started = true }
            return started
        }
        guard !alreadyStarted else { throw OpenSSLQUICServerError.setupFailed }
        do {
            try openListener()
        } catch {
            releaseListener()
            throw error
        }
        let thread = Thread { [self] in
            runLoop()
        }
        thread.name = "com.sensorium.openssl-quic-server"
        thread.start()
    }

    /// Closes every connection, waits for the loop to finish, and releases
    /// the socket. Idempotent.
    public func stop() {
        let shouldWait = lock.withLock { () -> Bool in
            guard started, !stopRequested else { return false }
            stopRequested = true
            return true
        }
        guard shouldWait else { return }
        signalWake()
        stopped.wait()
    }

    // MARK: - Setup

    private func openListener() throws {
        defer { ERR_clear_error() }
        guard let context = SSL_CTX_new(OSSL_QUIC_server_method()) else {
            throw OpenSSLQUICServerError.setupFailed
        }
        self.context = context
        let credentials = try identity.makeOpenSSLCredentials()
        defer {
            X509_free(credentials.certificate)
            EVP_PKEY_free(credentials.privateKey)
        }
        guard SSL_CTX_use_certificate(context, credentials.certificate) == 1,
              SSL_CTX_use_PrivateKey(context, credentials.privateKey) == 1,
              SSL_CTX_check_private_key(context) == 1 else {
            throw OpenSSLQUICServerError.setupFailed
        }
        SSL_CTX_set_alpn_select_cb(context, sensoriumALPNSelect, nil)

        guard let listener = SSL_new_listener(context, 0) else {
            throw OpenSSLQUICServerError.setupFailed
        }
        self.listener = listener
        socketDescriptor = try bindSocket()
        guard let bio = BIO_new_dgram(socketDescriptor, BIO_NOCLOSE) else {
            throw OpenSSLQUICServerError.setupFailed
        }
        SSL_set_bio(listener, bio, bio)
        guard SSL_set_blocking_mode(listener, 0) == 1,
              SSL_listen(listener) == 1 else {
            throw OpenSSLQUICServerError.setupFailed
        }

        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else {
            throw OpenSSLQUICServerError.setupFailed
        }
        wakeReadDescriptor = descriptors[0]
        wakeWriteDescriptor = descriptors[1]
        _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(descriptors[1], F_SETFL, O_NONBLOCK)
    }

    private func bindSocket() throws -> Int32 {
        var v4 = sockaddr_in()
        var v6 = sockaddr_in6()
        let family: Int32
        if inet_pton(AF_INET, bindAddress, &v4.sin_addr) == 1 {
            family = AF_INET
        } else if inet_pton(AF_INET6, bindAddress, &v6.sin6_addr) == 1 {
            family = AF_INET6
        } else {
            throw OpenSSLQUICServerError.bindFailed
        }
        let descriptor = socket(family, Int32(SOCK_DGRAM.rawValue), 0)
        guard descriptor >= 0 else { throw OpenSSLQUICServerError.bindFailed }
        _ = fcntl(descriptor, F_SETFL, O_NONBLOCK)

        let bound: Int32
        if family == AF_INET {
            v4.sin_family = sa_family_t(AF_INET)
            v4.sin_port = requestedPort.bigEndian
            bound = withUnsafePointer(to: &v4) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } else {
            v6.sin6_family = sa_family_t(AF_INET6)
            v6.sin6_port = requestedPort.bigEndian
            bound = withUnsafePointer(to: &v6) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        guard bound == 0 else {
            Glibc.close(descriptor)
            throw OpenSSLQUICServerError.bindFailed
        }

        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else {
            Glibc.close(descriptor)
            throw OpenSSLQUICServerError.bindFailed
        }
        boundPort = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                // `sin_port` and `sin6_port` sit at the same offset.
                UInt16(bigEndian: $0.pointee.sin_port)
            }
        }
        return descriptor
    }

    private func releaseListener() {
        if let listener {
            SSL_free(listener)
            self.listener = nil
        }
        if let context {
            SSL_CTX_free(context)
            self.context = nil
        }
        if socketDescriptor >= 0 {
            Glibc.close(socketDescriptor)
            socketDescriptor = -1
        }
        // Under the lock `signalWake` writes under, so a late wake-up from a
        // channel never lands on a descriptor number the kernel has reused.
        let wakeEnds: [Int32] = lock.withLock {
            defer {
                wakeReadDescriptor = -1
                wakeWriteDescriptor = -1
            }
            return [wakeReadDescriptor, wakeWriteDescriptor]
        }
        for descriptor in wakeEnds where descriptor >= 0 {
            Glibc.close(descriptor)
        }
    }

    // MARK: - The event loop

    private func runLoop() {
        var drainDeadline: Date?
        while true {
            let stopping = lock.withLock { stopRequested }
            if stopping, drainDeadline == nil {
                drainDeadline = Date().addingTimeInterval(closeBoundSeconds)
                for channel in active { channel.requestClose() }
            }
            var progressed = stopping ? false : acceptConnections()
            for channel in active {
                if channel.service(onEstablished: { [channelContinuation] in channelContinuation.yield($0) }) {
                    progressed = true
                }
            }
            active.removeAll { $0.isDone }
            if let drainDeadline, active.isEmpty || Date() >= drainDeadline {
                for channel in active { channel.release() }
                active.removeAll()
                break
            }
            if !progressed {
                waitForEvents()
            }
        }
        channelContinuation.finish()
        releaseListener()
        stopped.signal()
    }

    /// Takes every connection the listener has ready. The handshake is not
    /// finished yet; the channel drives it.
    private func acceptConnections() -> Bool {
        guard let listener else { return false }
        var accepted = false
        // `SSL_ACCEPT_CONNECTION_NO_BLOCK` is `1UL << 0`, which Swift cannot
        // import.
        while let connection = SSL_accept_connection(listener, 1) {
            accepted = true
            guard configure(connection) else {
                SSL_free(connection)
                continue
            }
            active.append(OpenSSLQUICServerChannel(connection: connection, wake: { [weak self] in
                self?.signalWake()
            }))
        }
        return accepted
    }

    private func configure(_ connection: OpaquePointer) -> Bool {
        // Streams are accepted explicitly, and nothing is conjured by a
        // first read or write.
        _ = SSL_set_default_stream_mode(connection, UInt32(SSL_DEFAULT_STREAM_MODE_NONE))
        guard SSL_set_blocking_mode(connection, 0) == 1,
              SSL_set_incoming_stream_policy(connection, SSL_INCOMING_STREAM_POLICY_ACCEPT, 0) == 1 else {
            return false
        }
        return true
    }

    private func waitForEvents() {
        guard let listener else { return }
        var descriptors: [pollfd] = []
        var events: Int16 = 0
        if SSL_net_read_desired(listener) == 1 { events |= Int16(POLLIN) }
        if SSL_net_write_desired(listener) == 1 { events |= Int16(POLLOUT) }
        if events != 0 {
            descriptors.append(pollfd(fd: socketDescriptor, events: events, revents: 0))
        }
        descriptors.append(pollfd(fd: wakeReadDescriptor, events: Int16(POLLIN), revents: 0))
        _ = poll(&descriptors, nfds_t(descriptors.count), pollTimeoutMilliseconds(listener))
        var scratch = [UInt8](repeating: 0, count: 64)
        while Glibc.read(wakeReadDescriptor, &scratch, scratch.count) > 0 {}
        _ = SSL_handle_events(listener)
    }

    private func pollTimeoutMilliseconds(_ listener: OpaquePointer) -> Int32 {
        var remaining = timeval()
        var isInfinite: Int32 = 0
        guard SSL_get_event_timeout(listener, &remaining, &isInfinite) == 1, isInfinite == 0 else {
            return -1
        }
        let milliseconds = remaining.tv_sec * 1_000 + Int(remaining.tv_usec) / 1_000
        return Int32(clamping: max(milliseconds, 0))
    }

    private func signalWake() {
        lock.lock()
        defer { lock.unlock() }
        guard wakeWriteDescriptor >= 0 else { return }
        var byte: UInt8 = 1
        _ = Glibc.write(wakeWriteDescriptor, &byte, 1)
    }
}
#endif

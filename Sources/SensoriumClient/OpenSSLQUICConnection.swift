#if canImport(COpenSSL)
import COpenSSL
import Foundation
import SensoriumCore
#if canImport(Glibc)
import Glibc
#endif

/// The QUIC idle timeout this viewer requests, in milliseconds. The silence
/// watchdog above it is what actually ends a dead link; this is only the
/// backstop underneath, and it matches what the host asks for so neither side
/// is the one that gives up early.
private let quicIdleTimeoutMilliseconds: UInt64 = 30_000

/// How long a close drives the shutdown before giving up. A QUIC close is
/// acknowledged by the peer, and OpenSSL's RFC-compliant shutdown can take up
/// to three times the round trip, so it is driven rather than called once.
/// Freeing the socket before the acknowledgement arrives leaves the host
/// sending into a port nothing is listening on, which it reports as a refused
/// connection rather than a session that ended. A peer that has already gone
/// must still never keep a viewer from exiting, hence the bound.
private let shutdownBoundSeconds: TimeInterval = 1.0

/// The longest one wait inside that bound may sleep. Not a polling interval:
/// the loop is woken by the socket and by its own wake pipe, and this only
/// keeps a shutdown whose peer has stopped answering from waiting on a
/// timeout that never comes.
private let shutdownWaitMilliseconds: Int32 = 50

/// Our slot on each `SSL` object, so the verify callback -- a C function
/// pointer, which can capture nothing -- can find the session it belongs to.
private let sensoriumSSLExDataIndex: Int32 =
    CRYPTO_get_ex_new_index(CRYPTO_EX_INDEX_SSL, 0, nil, nil, nil, nil)

/// Compares the leaf certificate offered during the handshake against the
/// pin, and nothing else: chain building and name checking are meaningless
/// for a self-signed host identity that pairing already bound to an Ed25519
/// key.
private func sensoriumVerifyCallback(preverified: Int32, storeContext: OpaquePointer?) -> Int32 {
    guard let storeContext,
          let sslPointer = X509_STORE_CTX_get_ex_data(
            storeContext,
            SSL_get_ex_data_X509_STORE_CTX_idx()
          ),
          let session = SSL_get_ex_data(OpaquePointer(sslPointer), sensoriumSSLExDataIndex)
    else {
        return 0
    }
    let io = Unmanaged<OpenSSLQUICSessionIO>.fromOpaque(session).takeUnretainedValue()
    let leaf = X509_STORE_CTX_get0_cert(storeContext).map(derBytes(of:)) ?? nil
    return QUICPeerCertificateVerification.accepts(
        leafCertificateDER: leaf,
        pin: io.parameters.tlsCertificateHash,
        mismatchFlag: io.pinMismatchFlag
    ) ? 1 : 0
}

private func derBytes(of certificate: OpaquePointer) -> Data? {
    var buffer: UnsafeMutablePointer<UInt8>?
    let length = i2d_X509(certificate, &buffer)
    guard length > 0, let buffer else {
        return nil
    }
    defer { CRYPTO_free(buffer, #file, #line) }
    return Data(bytes: buffer, count: Int(length))
}

/// One QUIC connection to a host, over OpenSSL's own QUIC implementation.
///
/// **Threading.** Every `SSL` call this type makes happens on one dedicated
/// thread, and callers reach it through a queue. `openssl-quic(7)`, THREAD
/// ASSISTED MODE, says that even in thread-assisted mode "the thread safety
/// guarantees for the public SSL API are unchanged. Therefore, an application
/// must still do its own locking if it wishes to make concurrent use of the
/// public SSL APIs", and the one concurrency guarantee
/// `openssl-quic-concurrency(7)`, CONCURRENCY MODELS, spells out is for
/// *different* stream objects used from different threads. Reading and
/// writing one stream object from two threads is nowhere permitted, so it is
/// not done.
///
/// One thread owning every call rules out a blocking read, which would leave
/// a queued write waiting behind it forever. The connection therefore runs in
/// application-level nonblocking mode and the thread drives its own event
/// loop, the arrangement `openssl-quic(7)` describes under APPLICATION-DRIVEN
/// EVENT LOOPS. It blocks in `poll` on the QUIC socket and on a pipe that
/// `close`, `send` and every new read write a byte to, so the thread wakes on
/// a datagram or on local work and on nothing else; the sleep is bounded by
/// `SSL_get_event_timeout`, and `SSL_handle_events` runs on every wake.
/// Waiting for the application's own event alongside the QUIC ones is what
/// `openssl-quic-concurrency(7)`, THREAD CANCELLATION, recommends for prompt
/// cancellation.
///
/// The method is `OSSL_QUIC_client_method`, the Contentive Concurrency Model,
/// rather than the thread-assisted one: `openssl-quic-concurrency(7)`,
/// RECOMMENDED USAGE, says to pick it when the application can guarantee the
/// domain is serviced regularly, which a loop built on
/// `SSL_get_event_timeout` does. Thread-assisted mode would put OpenSSL's own
/// thread on the same socket this loop polls, and the two would race for
/// every datagram.
final class OpenSSLQUICSessionIO: QUICSessionIO, QUICSessionTeardown, @unchecked Sendable {
    let parameters: QUICSessionParameters
    let pinMismatchFlag: PinMismatchFlag

    private enum SessionError: Error {
        case resolutionFailed
        case socketFailed
        case setupFailed
    }

    /// Guards every field below it and wakes the session thread.
    private let condition = NSCondition()
    private var connectContinuation: CheckedContinuation<Void, any Error>?
    private var connectRequested = false
    /// A `nil` continuation is an `enqueueWrite(_:)`, which nobody awaits.
    private var pendingWrites: [(bytes: Data, continuation: CheckedContinuation<Void, any Error>?)] = []
    private var pendingRead: (count: Int, continuation: CheckedContinuation<Data, any Error>)?
    private var closeRequested = false
    private var threadStarted = false

    /// Owned by the session thread alone, from its first statement to its
    /// last. No other thread reads these.
    private var context: OpaquePointer?
    private var connection: OpaquePointer?
    private var stream: OpaquePointer?
    private var socketDescriptor: Int32 = -1
    /// Written by any thread with work for the loop, read only by the loop.
    /// A pipe rather than a condition: the loop's one wait is a `poll`, and
    /// local work has to be one of the descriptors it waits on.
    private var wakeReadDescriptor: Int32 = -1
    private var wakeWriteDescriptor: Int32 = -1
    private var receiveBuffer = Data()
    private var writeOffset = 0
    /// How many times the loop has come back to try a pending read again.
    /// Read from a test thread, so it is guarded like the queue is.
    private var readAttempts = 0

    var readProgressAttempts: Int {
        condition.lock()
        defer { condition.unlock() }
        return readAttempts
    }

    init(parameters: QUICSessionParameters, pinMismatchFlag: PinMismatchFlag) {
        self.parameters = parameters
        self.pinMismatchFlag = pinMismatchFlag
    }

    func connect() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            enqueueConnect(continuation)
        }
    }

    func write(_ bytes: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            enqueueWrite(bytes, continuation)
        }
    }

    func enqueueWrite(_ bytes: Data) {
        enqueueWrite(bytes, nil)
    }

    func read(count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            enqueueRead(count, continuation)
        }
    }

    func close() {
        condition.lock()
        closeRequested = true
        let started = threadStarted
        condition.unlock()
        signalWake()
        // A session that never started a thread has nothing to tear down, but
        // a caller may still be parked on it.
        if !started {
            failEverythingPending(with: NetworkControlConnectionError.closed)
        }
    }

    // MARK: - Queue, off the session thread

    /// Locking is confined to plain, non-`async` methods: an `NSCondition`
    /// call written directly inside an `async` function's body is unavailable
    /// from an asynchronous context.
    private func enqueueConnect(_ continuation: CheckedContinuation<Void, any Error>) {
        condition.lock()
        guard !closeRequested else {
            condition.unlock()
            continuation.resume(throwing: NetworkControlConnectionError.closed)
            return
        }
        connectContinuation = continuation
        connectRequested = true
        startThreadLocked()
        condition.unlock()
        signalWake()
    }

    private func enqueueWrite(_ bytes: Data, _ continuation: CheckedContinuation<Void, any Error>?) {
        condition.lock()
        guard !closeRequested else {
            condition.unlock()
            continuation?.resume(throwing: NetworkControlConnectionError.closed)
            return
        }
        pendingWrites.append((bytes, continuation))
        startThreadLocked()
        condition.unlock()
        signalWake()
    }

    private func enqueueRead(_ count: Int, _ continuation: CheckedContinuation<Data, any Error>) {
        condition.lock()
        guard !closeRequested else {
            condition.unlock()
            continuation.resume(throwing: NetworkControlConnectionError.closed)
            return
        }
        guard pendingRead == nil else {
            condition.unlock()
            // The receive loop reads one packet at a time; a second reader
            // would be a bug in the caller, not a stream condition.
            continuation.resume(throwing: NetworkControlConnectionError.notReady)
            return
        }
        pendingRead = (count, continuation)
        startThreadLocked()
        condition.unlock()
        signalWake()
    }

    private func startThreadLocked() {
        guard !threadStarted else { return }
        threadStarted = true
        var descriptors: [Int32] = [-1, -1]
        if pipe(&descriptors) == 0 {
            // Nonblocking at both ends: a full pipe already means the loop has
            // a wake-up coming, and a drain must never park the loop.
            _ = fcntl(descriptors[0], F_SETFL, O_NONBLOCK)
            _ = fcntl(descriptors[1], F_SETFL, O_NONBLOCK)
            wakeReadDescriptor = descriptors[0]
            wakeWriteDescriptor = descriptors[1]
        }
        let thread = Thread { [weak self] in
            self?.runSession()
        }
        thread.name = "com.sensorium.openssl-quic"
        thread.start()
    }

    private func failEverythingPending(with error: any Error) {
        condition.lock()
        let connectWaiter = connectContinuation
        let writes = pendingWrites
        let reader = pendingRead
        connectContinuation = nil
        connectRequested = false
        pendingWrites = []
        pendingRead = nil
        condition.unlock()
        connectWaiter?.resume(throwing: error)
        for write in writes {
            write.continuation?.resume(throwing: error)
        }
        reader?.continuation.resume(throwing: error)
    }

    // MARK: - The session thread

    private func runSession() {
        while true {
            condition.lock()
            let shouldClose = closeRequested
            let shouldConnect = connectRequested
            connectRequested = false
            condition.unlock()

            if shouldClose {
                tearDown()
                failEverythingPending(with: NetworkControlConnectionError.closed)
                return
            }
            if shouldConnect {
                performConnect()
                continue
            }

            let progressed = serviceWrites() || serviceRead()
            if !progressed {
                waitForEvents()
            }
        }
    }

    /// Sleeps until the socket has something to say, until OpenSSL's own next
    /// timer is due, or until another thread signals the wake pipe -- and
    /// never on a fixed interval. `cappedAt` is a ceiling in milliseconds on
    /// that sleep, negative for none.
    private func waitForEvents(cappedAt ceiling: Int32 = -1) {
        var descriptors: [pollfd] = []
        if socketDescriptor >= 0, let connection {
            var events: Int16 = 0
            if SSL_net_read_desired(connection) == 1 {
                events |= Int16(POLLIN)
            }
            if SSL_net_write_desired(connection) == 1 {
                events |= Int16(POLLOUT)
            }
            if events != 0 {
                descriptors.append(pollfd(fd: socketDescriptor, events: events, revents: 0))
            }
        }
        if wakeReadDescriptor >= 0 {
            descriptors.append(pollfd(fd: wakeReadDescriptor, events: Int16(POLLIN), revents: 0))
        }
        guard !descriptors.isEmpty else {
            // Only reachable when the wake pipe could not be created and the
            // connection wants nothing from the socket. There is no event to
            // wait on, so the loop yields briefly rather than spinning.
            _ = poll(nil, 0, 10)
            return
        }
        _ = poll(&descriptors, nfds_t(descriptors.count), pollTimeoutMilliseconds(cappedAt: ceiling))
        drainWake()
        if let connection {
            // Cheap, and always correct: OpenSSL decides for itself whether a
            // wake-up was one of its timers or one of ours.
            _ = SSL_handle_events(connection)
        }
    }

    /// How long `poll` may sleep: whatever OpenSSL says its next timer needs,
    /// narrowed by any ceiling the caller imposed. `-1` means indefinitely,
    /// which is what an idle session with no timer pending should do.
    private func pollTimeoutMilliseconds(cappedAt ceiling: Int32) -> Int32 {
        var fromOpenSSL: Int32 = -1
        if let connection {
            var remaining = timeval()
            var isInfinite: Int32 = 0
            if SSL_get_event_timeout(connection, &remaining, &isInfinite) == 1, isInfinite == 0 {
                let milliseconds = remaining.tv_sec * 1_000 + Int(remaining.tv_usec) / 1_000
                fromOpenSSL = Int32(clamping: max(milliseconds, 0))
            }
        }
        switch (fromOpenSSL, ceiling) {
        case (-1, _): return ceiling
        case (_, -1): return fromOpenSSL
        default: return min(fromOpenSSL, ceiling)
        }
    }

    /// The write happens under the lock the descriptor is read under: the end
    /// is nonblocking, so the critical section is bounded, and a teardown
    /// cannot close the descriptor between the read and the write.
    private func signalWake() {
        condition.lock()
        defer { condition.unlock() }
        guard wakeWriteDescriptor >= 0 else { return }
        var byte: UInt8 = 1
        _ = Glibc.write(wakeWriteDescriptor, &byte, 1)
    }

    /// One wake-up is one wake-up however many bytes produced it.
    private func drainWake() {
        guard wakeReadDescriptor >= 0 else { return }
        var scratch = [UInt8](repeating: 0, count: 64)
        while Glibc.read(wakeReadDescriptor, &scratch, scratch.count) > 0 {}
    }

    private func isCloseRequested() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        return closeRequested
    }

    private func performConnect() {
        do {
            try openConnection()
            condition.lock()
            let waiter = connectContinuation
            connectContinuation = nil
            condition.unlock()
            waiter?.resume()
        } catch {
            condition.lock()
            let waiter = connectContinuation
            connectContinuation = nil
            condition.unlock()
            waiter?.resume(throwing: NetworkControlConnectionError.peerFailed)
        }
    }

    private func openConnection() throws {
        guard let context = SSL_CTX_new(OSSL_QUIC_client_method()) else {
            throw SessionError.setupFailed
        }
        self.context = context
        SSL_CTX_set_verify(context, SSL_VERIFY_PEER, sensoriumVerifyCallback)

        guard let connection = SSL_new(context) else {
            throw SessionError.setupFailed
        }
        self.connection = connection
        SSL_set_ex_data(connection, sensoriumSSLExDataIndex, Unmanaged.passUnretained(self).toOpaque())
        // Multi-stream mode: this protocol owns exactly one bidirectional
        // stream and never wants one conjured by the first read or write.
        _ = SSL_set_default_stream_mode(connection, UInt32(SSL_DEFAULT_STREAM_MODE_NONE))

        var alpn = [UInt8(parameters.applicationProtocol.utf8.count)]
        alpn.append(contentsOf: Array(parameters.applicationProtocol.utf8))
        guard SSL_set_alpn_protos(connection, alpn, UInt32(alpn.count)) == 0 else {
            throw SessionError.setupFailed
        }
        guard sensorium_ssl_set_tlsext_host_name(connection, parameters.serverName) == 1 else {
            throw SessionError.setupFailed
        }
        guard SSL_set_value_uint(
            connection,
            UInt32(SSL_VALUE_CLASS_FEATURE_REQUEST),
            UInt32(SSL_VALUE_QUIC_IDLE_TIMEOUT),
            quicIdleTimeoutMilliseconds
        ) == 1 else {
            throw SessionError.setupFailed
        }

        try attachSocket(to: connection)
        // Nonblocking at the application level: see this type's own note on
        // why one thread owning every call cannot afford a blocking read.
        guard SSL_set_blocking_mode(connection, 0) == 1 else {
            throw SessionError.setupFailed
        }

        while true {
            let result = SSL_connect(connection)
            if result == 1 {
                break
            }
            let reason = SSL_get_error(connection, result)
            guard reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE else {
                throw SessionError.setupFailed
            }
            guard !isCloseRequested() else {
                throw SessionError.setupFailed
            }
            waitForEvents()
        }

        guard QUICApplicationProtocol.isExpected(negotiatedApplicationProtocol(on: connection)) else {
            let negotiated = negotiatedApplicationProtocol(on: connection) ?? ""
            print("""
                The host settled on application protocol "\(negotiated)", \
                not \(QUICSessionParameters.applicationProtocol). Not a Sensorium host.
                """)
            throw SessionError.setupFailed
        }

        guard let stream = SSL_new_stream(connection, 0) else {
            throw SessionError.setupFailed
        }
        self.stream = stream
    }

    /// Resolves the host, connects a datagram socket to it, and hands both
    /// the socket and the peer address to the connection. IPv4 and IPv6 are
    /// whatever the resolver returns, in the order it returns them.
    private func attachSocket(to connection: OpaquePointer) throws {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_DGRAM.rawValue)
        var resolved: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(parameters.host, String(parameters.port), &hints, &resolved) == 0,
              let head = resolved else {
            throw SessionError.resolutionFailed
        }
        defer { freeaddrinfo(head) }

        var candidate: UnsafeMutablePointer<addrinfo>? = head
        while let entry = candidate {
            let descriptor = socket(entry.pointee.ai_family, entry.pointee.ai_socktype, entry.pointee.ai_protocol)
            if descriptor >= 0 {
                if Glibc.connect(descriptor, entry.pointee.ai_addr, entry.pointee.ai_addrlen) == 0,
                   let peer = makePeerAddress(from: entry.pointee) {
                    defer { BIO_ADDR_free(peer) }
                    guard let bio = BIO_new_dgram(descriptor, BIO_NOCLOSE) else {
                        Glibc.close(descriptor)
                        throw SessionError.socketFailed
                    }
                    SSL_set_bio(connection, bio, bio)
                    guard SSL_set1_initial_peer_addr(connection, peer) == 1 else {
                        Glibc.close(descriptor)
                        throw SessionError.socketFailed
                    }
                    socketDescriptor = descriptor
                    return
                }
                Glibc.close(descriptor)
            }
            candidate = entry.pointee.ai_next
        }
        throw SessionError.socketFailed
    }

    private func makePeerAddress(from entry: addrinfo) -> OpaquePointer? {
        guard let address = entry.ai_addr, let peer = BIO_ADDR_new() else {
            return nil
        }
        let made: Int32
        switch entry.ai_family {
        case AF_INET:
            made = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { inet in
                var raw = inet.pointee.sin_addr
                return withUnsafeBytes(of: &raw) { bytes in
                    BIO_ADDR_rawmake(peer, AF_INET, bytes.baseAddress, bytes.count, inet.pointee.sin_port)
                }
            }
        case AF_INET6:
            made = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { inet in
                var raw = inet.pointee.sin6_addr
                return withUnsafeBytes(of: &raw) { bytes in
                    BIO_ADDR_rawmake(peer, AF_INET6, bytes.baseAddress, bytes.count, inet.pointee.sin6_port)
                }
            }
        default:
            made = 0
        }
        guard made == 1 else {
            BIO_ADDR_free(peer)
            return nil
        }
        return peer
    }

    /// What the handshake actually settled on, or `nil` when it settled on
    /// nothing at all.
    private func negotiatedApplicationProtocol(on connection: OpaquePointer) -> String? {
        var selected: UnsafePointer<UInt8>?
        var length: UInt32 = 0
        SSL_get0_alpn_selected(connection, &selected, &length)
        guard let selected, length > 0 else {
            return nil
        }
        return String(decoding: UnsafeBufferPointer(start: selected, count: Int(length)), as: UTF8.self)
    }

    /// Returns whether any byte moved, so the loop knows not to wait.
    private func serviceWrites() -> Bool {
        guard let stream else { return false }
        condition.lock()
        guard let next = pendingWrites.first else {
            condition.unlock()
            return false
        }
        condition.unlock()

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
            finishFirstWrite(throwing: NetworkControlConnectionError.closed)
            return true
        }
        writeOffset += written
        if writeOffset >= next.bytes.count {
            finishFirstWrite(throwing: nil)
        }
        return written > 0
    }

    private func finishFirstWrite(throwing error: (any Error)?) {
        writeOffset = 0
        condition.lock()
        let finished = pendingWrites.isEmpty ? nil : pendingWrites.removeFirst()
        condition.unlock()
        guard let finished else { return }
        if let error {
            finished.continuation?.resume(throwing: error)
        } else {
            finished.continuation?.resume()
        }
    }

    private func serviceRead() -> Bool {
        condition.lock()
        guard let waiting = pendingRead else {
            condition.unlock()
            return false
        }
        readAttempts += 1
        condition.unlock()
        guard let stream else { return false }

        if receiveBuffer.count < waiting.count {
            var chunk = [UInt8](repeating: 0, count: max(waiting.count - receiveBuffer.count, 4096))
            var read = 0
            let result = SSL_read_ex(stream, &chunk, chunk.count, &read)
            guard result == 1 else {
                let reason = SSL_get_error(stream, 0)
                if reason == SSL_ERROR_WANT_READ || reason == SSL_ERROR_WANT_WRITE {
                    return false
                }
                finishRead(with: .failure(NetworkControlConnectionError.closed))
                return true
            }
            guard read > 0 else {
                return false
            }
            receiveBuffer.append(contentsOf: chunk[0..<read])
        }
        guard receiveBuffer.count >= waiting.count else {
            return true
        }
        let delivered = Data(receiveBuffer.prefix(waiting.count))
        receiveBuffer.removeFirst(waiting.count)
        finishRead(with: .success(delivered))
        return true
    }

    private func finishRead(with outcome: Result<Data, any Error>) {
        condition.lock()
        let waiting = pendingRead
        pendingRead = nil
        condition.unlock()
        guard let waiting else { return }
        waiting.continuation.resume(with: outcome)
    }

    private func tearDown() {
        let deadline = Date().addingTimeInterval(shutdownBoundSeconds)
        let acknowledged = QUICSessionClose.perform(
            self,
            hasTimeRemaining: { Date() < deadline },
            wait: { waitForEvents(cappedAt: shutdownWaitMilliseconds) }
        )
        if !acknowledged {
            let bound = Int(shutdownBoundSeconds * 1_000)
            print("The host did not acknowledge the QUIC shutdown within \(bound) ms; freeing the session anyway.")
        }
    }

    /// Ends this viewer's half of the stream. Without it the host sees a
    /// connection that stopped answering rather than a session that ended,
    /// and reports the drop with an operating-system error beside it.
    func concludeStream() {
        guard let stream else { return }
        _ = SSL_stream_conclude(stream, 0)
    }

    /// `SSL_shutdown` cannot be used on a stream object, only on the
    /// connection, and in nonblocking mode it returns 0 until the close has
    /// been acknowledged.
    func stepShutdown() -> Bool {
        guard let connection else { return true }
        return SSL_shutdown(connection) == 1
    }

    /// Frees in the order OpenSSL requires: the stream, then the connection,
    /// then the context.
    func releaseSession() {
        if let connection {
            logConnectionClose(connection)
        }
        if let stream {
            SSL_free(stream)
            self.stream = nil
        }
        if let connection {
            SSL_free(connection)
            self.connection = nil
        }
        if let context {
            SSL_CTX_free(context)
            self.context = nil
        }
        if socketDescriptor >= 0 {
            Glibc.close(socketDescriptor)
            socketDescriptor = -1
        }
        // Taken under the lock before they are closed: a thread that has
        // already read the write end out of `signalWake` must not be left
        // holding a descriptor number this closes and the kernel reuses.
        condition.lock()
        let wakeEnds = [wakeReadDescriptor, wakeWriteDescriptor]
        wakeReadDescriptor = -1
        wakeWriteDescriptor = -1
        condition.unlock()
        for descriptor in wakeEnds where descriptor >= 0 {
            Glibc.close(descriptor)
        }
    }

    /// The peer's own reason for closing, for the log line and nothing else.
    /// Control flow never reads it: a stream that ended is `closed` whatever
    /// the connection says about why.
    private func logConnectionClose(_ connection: OpaquePointer) {
        var info = SSL_CONN_CLOSE_INFO()
        guard SSL_get_conn_close_info(connection, &info, MemoryLayout<SSL_CONN_CLOSE_INFO>.size) == 1 else {
            return
        }
        let reason = info.reason.map { String(cString: $0) } ?? ""
        guard !reason.isEmpty || info.error_code != 0 else { return }
        print("QUIC connection closed: code \(info.error_code)\(reason.isEmpty ? "" : ", \(reason)")")
    }
}

/// What the viewer asks OpenSSL for before a connection is established, read
/// back from OpenSSL itself. `SSL_VALUE_QUIC_IDLE_TIMEOUT` can only be
/// configured before establishment, so this opens no socket and dials
/// nothing.
public enum OpenSSLQUICIdleTimeout {
    /// The idle timeout, in milliseconds, a fresh connection object carries
    /// after this code has configured it. `nil` when OpenSSL refused either
    /// the set or the read back.
    public static func requestedMilliseconds() -> UInt64? {
        guard let context = SSL_CTX_new(OSSL_QUIC_client_method()) else {
            return nil
        }
        defer { SSL_CTX_free(context) }
        guard let connection = SSL_new(context) else {
            return nil
        }
        defer { SSL_free(connection) }
        guard SSL_set_value_uint(
            connection,
            UInt32(SSL_VALUE_CLASS_FEATURE_REQUEST),
            UInt32(SSL_VALUE_QUIC_IDLE_TIMEOUT),
            quicIdleTimeoutMilliseconds
        ) == 1 else {
            return nil
        }
        var value: UInt64 = 0
        guard SSL_get_value_uint(
            connection,
            UInt32(SSL_VALUE_CLASS_FEATURE_REQUEST),
            UInt32(SSL_VALUE_QUIC_IDLE_TIMEOUT),
            &value
        ) == 1 else {
            return nil
        }
        return value
    }
}

/// The viewer's control connection on Linux: OpenSSL's QUIC underneath, and
/// the same framing, pinning, dial deadline and silence watch every platform
/// shares.
public final class OpenSSLQUICConnection: ClientControlConnection, @unchecked Sendable {
    private let core: QUICControlConnection
    private let io: OpenSSLQUICSessionIO

    public var deferredPackets: DeferredPacketQueue { core.deferredPackets }
    public var pinnedHostCertificateHash: Data? { core.pinnedHostCertificateHash }

    /// How many times the session thread has come back to retry a pending
    /// read. An observation point for the check that an idle session waits on
    /// events rather than on a clock; nothing in the viewer reads it.
    public var readProgressAttempts: Int { io.readProgressAttempts }

    /// `nil` is allowed only during the one-time pairing ceremony; the signed
    /// pairing approval binds the returned certificate hash to the host key.
    /// Every saved-host reconnect passes the persisted hash and rejects any
    /// different self-signed certificate.
    public init(host: String, port: UInt16, tlsCertificateHash: Data? = nil) {
        let parameters = QUICSessionParameters(
            host: host,
            port: port,
            tlsCertificateHash: tlsCertificateHash
        )
        let pinMismatchFlag = PinMismatchFlag()
        let session = OpenSSLQUICSessionIO(parameters: parameters, pinMismatchFlag: pinMismatchFlag)
        io = session
        core = QUICControlConnection(
            io: session,
            pinMismatchFlag: pinMismatchFlag,
            pinnedHostCertificateHash: tlsCertificateHash
        )
    }

    public func start(timeout: TimeInterval = SessionTimeouts.remoteDefault.handshake) async throws {
        try await core.start(timeout: timeout)
    }

    public func beginHostSilenceWatch() {
        core.beginHostSilenceWatch()
    }

    public func endHostSilenceWatch() {
        core.endHostSilenceWatch()
    }

    public func send(_ message: SensoriumMessage) async throws {
        try await core.send(message)
    }

    public func send(_ packet: SensoriumTransportPacket) async throws {
        try await core.send(packet)
    }

    public func enqueue(_ packet: SensoriumTransportPacket) {
        core.enqueue(packet)
    }

    public func receiveWirePacket() async throws -> SensoriumTransportPacket {
        try await core.receiveWirePacket()
    }

    public func close() async {
        await core.close()
    }
}
#endif

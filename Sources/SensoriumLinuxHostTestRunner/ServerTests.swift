#if os(Linux)
import Foundation
import SensoriumClient
import SensoriumCore
import SensoriumLinuxHost

/// Hands each channel the server surfaces to whoever asks, in order.
final class ChannelCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [OpenSSLQUICServerChannel] = []
    private var task: Task<Void, Never>?

    init(_ server: OpenSSLQUICServer) {
        let stream = server.channels
        task = Task { [self] in
            for await channel in stream {
                append(channel)
            }
        }
    }

    deinit { task?.cancel() }

    private func append(_ channel: OpenSSLQUICServerChannel) {
        lock.withLock { collected.append(channel) }
    }

    private func popFirst() -> OpenSSLQUICServerChannel? {
        lock.withLock { collected.isEmpty ? nil : collected.removeFirst() }
    }

    var count: Int {
        lock.withLock { collected.count }
    }

    func next(timeout: TimeInterval) async throws -> OpenSSLQUICServerChannel {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let channel = popFirst() {
                return channel
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CheckFailure("the server surfaced no connection within \(timeout) s")
    }
}

func runningServer(
    identity: HostTLSIdentity
) throws -> (server: OpenSSLQUICServer, collector: ChannelCollector) {
    let server = OpenSSLQUICServer(identity: identity, bindAddress: "127.0.0.1", port: 0)
    try server.start()
    return (server, ChannelCollector(server))
}

/// Reads one length-prefixed transport packet off a server channel.
func readPacket(from channel: OpenSSLQUICServerChannel) async throws -> SensoriumTransportPacket {
    let header = try await channel.receiveBytes(count: 5)
    let length = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
    let payload = try await channel.receiveBytes(count: length)
    return try SensoriumTransportPacketCodec.decode(header + payload)
}

/// Gives up on `operation` after `seconds`. The operations raced here park on
/// continuations that cancellation cannot wake, so the race is settled by
/// whichever finishes first rather than by a task group, which would wait for
/// the loser.
func withDeadline<T: Sendable>(
    _ seconds: TimeInterval,
    _ what: String,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = OneShot<T>()
    return try await withCheckedThrowingContinuation { continuation in
        outcome.install(continuation)
        Task {
            do { outcome.finish(.success(try await operation())) } catch { outcome.finish(.failure(error)) }
        }
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            outcome.finish(.failure(CheckFailure("\(what) took longer than \(seconds) s")))
        }
    }
}

final class OneShot<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    private var spent = false

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        lock.withLock { self.continuation = continuation }
    }

    func finish(_ result: Result<T, any Error>) {
        let waiting: CheckedContinuation<T, any Error>? = lock.withLock {
            guard !spent else { return nil }
            spent = true
            return continuation
        }
        waiting?.resume(with: result)
    }
}

func testClientAndServerExchangePacketsBothWays() async throws {
    let identity = try HostTLSIdentity.generate(commonName: "Sensorium Host")
    let (server, collector) = try runningServer(identity: identity)
    defer { server.stop() }
    let client = OpenSSLQUICConnection(
        host: "127.0.0.1",
        port: server.boundPort,
        tlsCertificateHash: identity.certificateHash
    )
    try await client.start(timeout: 10)

    // The viewer's stream only reaches the host once the viewer writes, but
    // the connection is surfaced as soon as the handshake has finished.
    let channel = try await collector.next(timeout: 5)
    let hello = SensoriumTransportPacket.unrecognized(tag: 0x40, payload: Data("hello host".utf8))
    try await client.send(hello)
    let received = try await withDeadline(10, "reading the first packet") { try await readPacket(from: channel) }
    try require(received == hello, "the host read what the viewer sent")

    let reply = SensoriumTransportPacket.unrecognized(tag: 0x41, payload: Data("hello viewer".utf8))
    try await channel.sendBytes(try SensoriumTransportPacketCodec.encode(reply))
    let answered = try await withDeadline(10, "the viewer reading the reply") { try await client.receiveWirePacket() }
    try require(answered == reply, "the viewer read what the host sent")

    await client.close()
}
#endif

#if os(Linux)
func testLargePacketsCrossBothWaysAndAClientCloseEndsTheChannel() async throws {
    let identity = try HostTLSIdentity.generate(commonName: "Sensorium Host")
    let (server, collector) = try runningServer(identity: identity)
    defer { server.stop() }
    let client = OpenSSLQUICConnection(
        host: "127.0.0.1",
        port: server.boundPort,
        tlsCertificateHash: identity.certificateHash
    )
    try await client.start(timeout: 10)
    let channel = try await collector.next(timeout: 5)

    var big = Data(count: 1_500_000)
    for index in big.indices {
        big[index] = UInt8(truncatingIfNeeded: index &* 31 &+ 7)
    }
    let upload = SensoriumTransportPacket.unrecognized(tag: 0x42, payload: big)
    // A write this large completes only as the far end reads, so the reader
    // starts first.
    let hostRead = Task { try await readPacket(from: channel) }
    try await withDeadline(30, "sending the large packet") { try await client.send(upload) }
    let uploaded = try await withDeadline(30, "reading the large packet") { try await hostRead.value }
    try require(uploaded == upload, "a payload over 1 MiB reaches the host intact")

    let download = SensoriumTransportPacket.unrecognized(tag: 0x43, payload: Data(big.reversed()))
    let viewerRead = Task { try await client.receiveWirePacket() }
    let encoded = try SensoriumTransportPacketCodec.encode(download)
    try await withDeadline(30, "the host sending the large packet") { try await channel.sendBytes(encoded) }
    let downloaded = try await withDeadline(30, "the viewer reading the large packet") {
        try await viewerRead.value
    }
    try require(downloaded == download, "a payload over 1 MiB reaches the viewer intact")

    await client.close()
    do {
        _ = try await withDeadline(10, "the host noticing the close") { try await channel.receiveBytes(count: 1) }
        throw CheckFailure("a read on a closed connection returned data")
    } catch let error as OpenSSLQUICServerError {
        try require(error == .closed, "the host's read fails as closed after the viewer closes")
    }
}

func testAClientWithTheWrongPinIsRefused() async throws {
    let identity = try HostTLSIdentity.generate(commonName: "Sensorium Host")
    let (server, collector) = try runningServer(identity: identity)
    defer { server.stop() }
    let client = OpenSSLQUICConnection(
        host: "127.0.0.1",
        port: server.boundPort,
        tlsCertificateHash: Data(repeating: 0xAB, count: 32)
    )
    var refused = false
    do {
        try await client.start(timeout: 10)
    } catch {
        refused = true
    }
    try require(refused, "the viewer refuses a host whose certificate is not the pinned one")
    try await Task.sleep(for: .milliseconds(500))
    try require(collector.count == 0, "the server surfaces no connection for a viewer that rejected it")
    await client.close()
}

func testAClientOfferingAnotherProtocolIsRefused() async throws {
    let identity = try HostTLSIdentity.generate(commonName: "Sensorium Host")
    let (server, collector) = try runningServer(identity: identity)
    defer { server.stop() }

    let wrong = await rawHandshake(port: server.boundPort, offering: "com.example.other-v1")
    try require(!wrong.completed, "a handshake offering another protocol does not complete")
    try await Task.sleep(for: .milliseconds(300))
    try require(collector.count == 0, "the server surfaces nothing for another protocol")

    let right = await rawHandshake(port: server.boundPort, offering: QUICSessionParameters.applicationProtocol)
    try require(right.completed, "the same client completes when it offers the Sensorium protocol")
    try require(
        right.negotiatedProtocol == QUICSessionParameters.applicationProtocol,
        "the negotiated protocol is the Sensorium one"
    )
    _ = try await collector.next(timeout: 5)
}

func testTheServerAsksForAThirtySecondIdleTimeout() async throws {
    let identity = try HostTLSIdentity.generate(commonName: "Sensorium Host")
    let (server, collector) = try runningServer(identity: identity)
    defer { server.stop() }

    let outcome = await rawHandshake(port: server.boundPort, offering: QUICSessionParameters.applicationProtocol)
    try require(outcome.completed, "the handshake completes")
    try require(
        outcome.peerRequestedIdleTimeout == 30_000,
        "the server's transport parameters ask for 30 s, saw \(String(describing: outcome.peerRequestedIdleTimeout))"
    )
    let channel = try await collector.next(timeout: 5)
    try require(
        channel.requestedIdleTimeoutMilliseconds == 30_000,
        "the host's own request reads back as 30 s, saw \(String(describing: channel.requestedIdleTimeoutMilliseconds))"
    )
}
#endif

import Foundation
import SensoriumClient
import SensoriumCore

/// A `QUICSessionIO` whose every answer the test wrote down first: the bytes
/// the peer "sent", whether the handshake stalls, and which certificate the
/// peer presents. Nothing here opens a socket, so the framing, pin decision,
/// dial deadline, watchdog and error mapping are all measured on both
/// platforms.
private final class ScriptedQUICSessionIO: QUICSessionIO, @unchecked Sendable {
    private let lock = NSLock()
    private let parameters: QUICSessionParameters
    private let pinMismatchFlag: PinMismatchFlag
    /// The leaf certificate the scripted peer presents, in DER. `nil` stands
    /// for a peer that presented none.
    private let peerLeafCertificateDER: Data?
    /// Whether `connect()` never returns, so a dial runs into its deadline.
    private let stallsForever: Bool
    private var inbound: Data
    private var inboundReadIndex: Data.Index
    private var written = Data()
    private var closed = false
    private var connected = false
    /// One reader at a time, which is what the receive loop does.
    private var pendingRead: (count: Int, continuation: CheckedContinuation<Data, any Error>)?

    init(
        parameters: QUICSessionParameters,
        pinMismatchFlag: PinMismatchFlag,
        inbound: Data = Data(),
        peerLeafCertificateDER: Data? = nil,
        stallsForever: Bool = false
    ) {
        self.parameters = parameters
        self.pinMismatchFlag = pinMismatchFlag
        self.inbound = inbound
        inboundReadIndex = inbound.startIndex
        self.peerLeafCertificateDER = peerLeafCertificateDER
        self.stallsForever = stallsForever
    }

    var offeredParameters: QUICSessionParameters { parameters }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    var didConnect: Bool {
        lock.lock()
        defer { lock.unlock() }
        return connected
    }

    var writtenBytes: Data {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    func connect() async throws {
        if stallsForever {
            // Cancellable, so the dial's own deadline is what ends this.
            try? await Task.sleep(for: .seconds(3600))
            throw NetworkControlConnectionError.peerFailed
        }
        // Exactly where the real handshake decides it: a peer whose leaf
        // fails the pin never reaches a ready connection.
        guard QUICPeerCertificateVerification.accepts(
            leafCertificateDER: peerLeafCertificateDER,
            pin: parameters.tlsCertificateHash,
            mismatchFlag: pinMismatchFlag
        ) else {
            throw NetworkControlConnectionError.peerFailed
        }
        markConnected()
    }

    func write(_ bytes: Data) async throws {
        try record(bytes)
    }

    func enqueueWrite(_ bytes: Data) {
        try? record(bytes)
    }

    func read(count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: NetworkControlConnectionError.closed)
                return
            }
            guard pendingRead == nil else {
                lock.unlock()
                continuation.resume(throwing: NetworkControlConnectionError.notReady)
                return
            }
            pendingRead = (count, continuation)
            lock.unlock()
            serviceRead()
        }
    }

    func close() {
        lock.lock()
        closed = true
        let waiting = pendingRead
        pendingRead = nil
        lock.unlock()
        waiting?.continuation.resume(throwing: NetworkControlConnectionError.closed)
    }

    /// Locking is confined to plain, non-`async` methods: an `NSLock` call
    /// written directly in an `async` function's body is unavailable there.
    private func markConnected() {
        lock.lock()
        defer { lock.unlock() }
        connected = true
    }

    private func record(_ bytes: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else {
            throw NetworkControlConnectionError.closed
        }
        written.append(bytes)
    }

    /// Hands the waiting reader its bytes once enough have been scripted in.
    /// A read that asks for more than the script holds simply waits, which is
    /// what a live stream that has not sent them yet does.
    private func serviceRead() {
        lock.lock()
        guard let waiting = pendingRead else {
            lock.unlock()
            return
        }
        let available = inbound.distance(from: inboundReadIndex, to: inbound.endIndex)
        guard available >= waiting.count else {
            lock.unlock()
            return
        }
        let end = inbound.index(inboundReadIndex, offsetBy: waiting.count)
        let chunk = Data(inbound[inboundReadIndex..<end])
        inboundReadIndex = end
        pendingRead = nil
        lock.unlock()
        waiting.continuation.resume(returning: chunk)
    }
}

private func scriptedParameters(pin: Data? = nil) -> QUICSessionParameters {
    QUICSessionParameters(host: "host.example", port: 7443, tlsCertificateHash: pin)
}

private func encodedPacket(_ packet: SensoriumTransportPacket) -> Data {
    (try? SensoriumTransportPacketCodec.encode(packet)) ?? Data()
}

private func makeVideoPacket(sequence: UInt64) -> SensoriumTransportPacket {
    .video(EncodedVideoFramePacket(
        sequence: sequence,
        presentationTimeNanoseconds: sequence * 16_000_000,
        isKeyFrame: true,
        payload: Data([0x01, 0x02, 0x03])
    ))
}

@MainActor
func testQUICControlConnectionTests() async {
    do {
        let reply = SensoriumMessage.canvasReady(
            displayID: 7,
            logicalWidth: 1920,
            logicalHeight: 1200,
            hostSignature: nil,
            surfaceID: nil
        )
        let flag = PinMismatchFlag()
        let io = ScriptedQUICSessionIO(
            parameters: scriptedParameters(),
            pinMismatchFlag: flag,
            inbound: encodedPacket(.control(reply))
        )
        let connection = QUICControlConnection(io: io, pinMismatchFlag: flag)
        try? await connection.start(timeout: 1)
        try? await connection.send(.hello(protocolVersion: 1, deviceName: "fedora"))
        let received = try? await connection.receive()
        expect(received == reply, "a control frame comes back through the framing unchanged -- got \(String(describing: received))")
        expect(
            io.writtenBytes == encodedPacket(.control(.hello(protocolVersion: 1, deviceName: "fedora"))),
            "a sent control message reaches the stream as one encoded transport packet"
        )
        await connection.close()
        print("PASS: a control frame round trips through a scripted QUIC session")
    }

    do {
        let flag = PinMismatchFlag()
        let io = ScriptedQUICSessionIO(parameters: scriptedParameters(), pinMismatchFlag: flag)
        let connection = QUICControlConnection(io: io, pinMismatchFlag: flag)
        try? await connection.start(timeout: 1)
        let copy = SensoriumTransportPacket.clipboard(.text("copied"))
        connection.enqueue(copy)
        try? await connection.send(.hello(protocolVersion: 1, deviceName: "fedora"))
        var expected = encodedPacket(copy)
        expected.append(encodedPacket(.control(.hello(protocolVersion: 1, deviceName: "fedora"))))
        expect(io.writtenBytes == expected, "an enqueued packet reaches the stream ahead of anything sent after it")
        await connection.close()
        connection.enqueue(copy)
        expect(io.writtenBytes == expected, "an enqueue on a closed connection is dropped")
        print("PASS: an enqueued packet is on the stream before a later send")
    }

    do {
        let video = makeVideoPacket(sequence: 3)
        let reply = SensoriumMessage.inputApplied(sequence: 41)
        let flag = PinMismatchFlag()
        var script = encodedPacket(video)
        script.append(encodedPacket(.control(reply)))
        let io = ScriptedQUICSessionIO(parameters: scriptedParameters(), pinMismatchFlag: flag, inbound: script)
        let connection = QUICControlConnection(io: io, pinMismatchFlag: flag)
        try? await connection.start(timeout: 1)
        let control = try? await connection.receive()
        expect(control == reply, "a control wait steps over video that arrived first -- got \(String(describing: control))")
        let held = try? await connection.receivePacket()
        expect(held == video, "the video stepped over is held for the media loop, never dropped")
        await connection.close()
        print("PASS: media arriving before a control reply is deferred, not lost")
    }

    do {
        let leaf = Data("a self-signed host leaf".utf8)
        let flag = PinMismatchFlag()
        let io = ScriptedQUICSessionIO(
            parameters: scriptedParameters(pin: HostTLSIdentity.certificateHash(for: leaf)),
            pinMismatchFlag: flag,
            peerLeafCertificateDER: leaf
        )
        let connection = QUICControlConnection(io: io, pinMismatchFlag: flag)
        var failure: (any Error)?
        do {
            try await connection.start(timeout: 1)
        } catch {
            failure = error
        }
        expect(failure == nil, "a leaf matching the pin completes the dial -- got \(String(describing: failure))")
        expect(io.didConnect, "the handshake ran to completion")
        expect(!flag.observed, "no mismatch is recorded for a matching leaf")
        await connection.close()
        print("PASS: a leaf certificate matching the pin is accepted")
    }

    do {
        let flag = PinMismatchFlag()
        let io = ScriptedQUICSessionIO(
            parameters: scriptedParameters(pin: HostTLSIdentity.certificateHash(for: Data("the pinned leaf".utf8))),
            pinMismatchFlag: flag,
            peerLeafCertificateDER: Data("some other machine's leaf".utf8)
        )
        let connection = QUICControlConnection(io: io, pinMismatchFlag: flag)
        var failure: (any Error)?
        do {
            try await connection.start(timeout: 1)
        } catch {
            failure = error
        }
        expect(
            failure as? NetworkControlConnectionError == .certificatePinMismatch,
            "a leaf that is not the pinned one reports the pin mismatch itself -- got \(String(describing: failure))"
        )
        expect(!io.didConnect, "the handshake never completed")
        await connection.close()
        print("PASS: a leaf certificate failing the pin fails the dial as certificatePinMismatch")
    }

    do {
        let flag = PinMismatchFlag()
        let io = ScriptedQUICSessionIO(
            parameters: scriptedParameters(pin: nil),
            pinMismatchFlag: flag,
            peerLeafCertificateDER: Data("any leaf at all".utf8)
        )
        let connection = QUICControlConnection(io: io, pinMismatchFlag: flag)
        var failure: (any Error)?
        do {
            try await connection.start(timeout: 1)
        } catch {
            failure = error
        }
        expect(failure == nil, "the pairing dial has no pin yet and accepts the leaf -- got \(String(describing: failure))")
        expect(io.didConnect, "the pairing handshake ran to completion")
        await connection.close()
        print("PASS: a dial with no pin yet accepts the host leaf, as the pairing ceremony needs")
    }

    do {
        let parameters = scriptedParameters()
        expect(
            parameters.applicationProtocol == "com.sensorium.control-v1",
            "the viewer offers exactly the host's ALPN -- got \(parameters.applicationProtocol)"
        )
        expect(
            parameters.serverName == "sensorium-host",
            "the viewer names the host service in SNI -- got \(parameters.serverName)"
        )
        let flag = PinMismatchFlag()
        let io = ScriptedQUICSessionIO(parameters: parameters, pinMismatchFlag: flag)
        expect(
            io.offeredParameters.applicationProtocol == "com.sensorium.control-v1",
            "the session is handed that ALPN and no other"
        )
        _ = QUICControlConnection(io: io, pinMismatchFlag: flag)
        print("PASS: the application protocol offered is exactly com.sensorium.control-v1")
    }

    do {
        let flag = PinMismatchFlag()
        let io = ScriptedQUICSessionIO(parameters: scriptedParameters(), pinMismatchFlag: flag, stallsForever: true)
        let connection = QUICControlConnection(io: io, pinMismatchFlag: flag)
        var failure: (any Error)?
        do {
            try await connection.start(timeout: 0.05)
        } catch {
            failure = error
        }
        expect(
            failure as? NetworkControlConnectionError == .timedOut,
            "a handshake that never completes ends at the dial deadline -- got \(String(describing: failure))"
        )
        expect(io.isClosed, "the stalled session is closed rather than left running")
        print("PASS: a dial that outlives its deadline reports timedOut")
    }

    do {
        let flag = PinMismatchFlag()
        var oversized = Data([0])
        var length = UInt32(SensoriumTransportPacketCodec.maximumPayloadLength + 1).bigEndian
        withUnsafeBytes(of: &length) { oversized.append(contentsOf: $0) }
        let io = ScriptedQUICSessionIO(parameters: scriptedParameters(), pinMismatchFlag: flag, inbound: oversized)
        let connection = QUICControlConnection(io: io, pinMismatchFlag: flag)
        try? await connection.start(timeout: 1)
        var failure: (any Error)?
        do {
            _ = try await connection.receiveWirePacket()
        } catch {
            failure = error
        }
        expect(
            failure as? SensoriumProtocolError == .frameTooLarge,
            "a length field past the cap is refused before a byte of payload is read -- got \(String(describing: failure))"
        )
        await connection.close()
        print("PASS: an oversized length field is refused as frameTooLarge")
    }

    do {
        let flag = PinMismatchFlag()
        let io = ScriptedQUICSessionIO(
            parameters: scriptedParameters(),
            pinMismatchFlag: flag,
            inbound: Data([0, 0])
        )
        let connection = QUICControlConnection(io: io, pinMismatchFlag: flag)
        try? await connection.start(timeout: 1)
        let pending = Task { () -> (any Error)? in
            do {
                _ = try await connection.receiveWirePacket()
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        io.close()
        let failure = await pending.value
        expect(
            failure as? NetworkControlConnectionError == .closed,
            "a stream that ends partway through a header reports closed -- got \(String(describing: failure))"
        )
        await connection.close()
        print("PASS: a peer that closes mid-header reports closed")
    }

    do {
        let flag = PinMismatchFlag()
        let io = ScriptedQUICSessionIO(parameters: scriptedParameters(), pinMismatchFlag: flag)
        let connection = QUICControlConnection(io: io, pinMismatchFlag: flag)
        try? await connection.start(timeout: 1)
        let pending = Task { () -> (any Error)? in
            do {
                _ = try await connection.receiveWirePacket()
                return nil
            } catch {
                return error
            }
        }
        try? await Task.sleep(for: .milliseconds(30))
        await connection.close()
        let failure = await pending.value
        expect(
            failure as? NetworkControlConnectionError == .closed,
            "closing the connection ends the read parked on it -- got \(String(describing: failure))"
        )
        print("PASS: close() unblocks a read already waiting on the stream")
    }

    do {
        let flag = PinMismatchFlag()
        let io = ScriptedQUICSessionIO(parameters: scriptedParameters(), pinMismatchFlag: flag)
        let connection = QUICControlConnection(io: io, pinMismatchFlag: flag, silenceTimeout: .milliseconds(30))
        try? await connection.start(timeout: 1)
        expect(!io.isClosed, "nothing closes a connection that was never armed")
        connection.beginHostSilenceWatch()
        try? await Task.sleep(for: .milliseconds(120))
        expect(io.isClosed, "a link that goes silent past the timeout is closed by the watchdog")
        await connection.close()
        print("PASS: the silence watchdog closes a link that stops answering")
    }
}

/// Records each teardown step in the order it was asked for, so the sequence
/// a session ends with is verified without an OpenSSL connection to end.
private final class RecordingTeardown: QUICSessionTeardown {
    private(set) var steps: [String] = []
    private let shutdownCompletesAfter: Int
    private var shutdownSteps = 0

    /// `shutdownCompletesAfter` is how many steps the shutdown takes before
    /// it reports itself done; `Int.max` stands for one that never does.
    init(shutdownCompletesAfter: Int) {
        self.shutdownCompletesAfter = shutdownCompletesAfter
    }

    func concludeStream() {
        steps.append("conclude")
    }

    func stepShutdown() -> Bool {
        steps.append("shutdown")
        shutdownSteps += 1
        return shutdownSteps >= shutdownCompletesAfter
    }

    func releaseSession() {
        steps.append("release")
    }
}

func testQUICSessionCloseTests() {
    do {
        let teardown = RecordingTeardown(shutdownCompletesAfter: 1)
        let acknowledged = QUICSessionClose.perform(teardown, hasTimeRemaining: { true }, wait: {})
        expect(
            teardown.steps == ["conclude", "shutdown", "release"],
            "a session ends by concluding the stream, shutting the connection down, then freeing -- got \(teardown.steps)"
        )
        expect(acknowledged, "a shutdown the peer acknowledged is reported as acknowledged")
        print("PASS: closing a session concludes the stream and shuts down before anything is freed")
    }

    do {
        let teardown = RecordingTeardown(shutdownCompletesAfter: 3)
        let acknowledged = QUICSessionClose.perform(teardown, hasTimeRemaining: { true }, wait: {})
        expect(
            teardown.steps == ["conclude", "shutdown", "shutdown", "shutdown", "release"],
            "a nonblocking shutdown is driven until it reports itself done -- got \(teardown.steps)"
        )
        expect(acknowledged, "a shutdown driven to completion is reported as acknowledged")
        print("PASS: a shutdown that does not complete at once is driven to completion")
    }

    do {
        let teardown = RecordingTeardown(shutdownCompletesAfter: Int.max)
        var waitsLeft = 3
        let acknowledged = QUICSessionClose.perform(
            teardown,
            hasTimeRemaining: {
                defer { waitsLeft -= 1 }
                return waitsLeft > 0
            },
            wait: {}
        )
        expect(
            teardown.steps == ["conclude", "shutdown", "shutdown", "shutdown", "shutdown", "release"],
            "a peer that never acknowledges the close still lets the session be freed -- got \(teardown.steps)"
        )
        expect(
            !acknowledged,
            "a close the peer never acknowledged is reported as unacknowledged, so the viewer can log it"
        )
        expect(teardown.steps.last == "release", "freeing is always the last step")
        print("PASS: a shutdown the peer never acknowledges is bounded and still frees the session")
    }
}

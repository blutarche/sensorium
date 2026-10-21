import Foundation
import SensoriumCore
import SensoriumHost

/// Stands in for `Task.sleep` in the connection-deadline watchdog, so a test
/// moves its clock by hand: each sleep waits for `release()` and records how
/// long it was asked to wait. Cancelling the sleeping task ends the sleep, as
/// `Task.sleep` does.
private final class SteppedSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var requested: [Duration] = []
    private var waiting: CheckedContinuation<Void, Error>?
    private var cancelled = false

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] duration in try await wait(duration) }
    }

    var requestedDurations: [Duration] {
        lock.lock()
        defer { lock.unlock() }
        return requested
    }

    var isWaiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return waiting != nil
    }

    private func wait(_ duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                requested.append(duration)
                waiting = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let continuation = waiting
            waiting = nil
            lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Ends the sleep in progress, once the watchdog has actually started
    /// one. `false` when none started in time.
    func advance() async -> Bool {
        guard await waitUntil(timeoutSeconds: 2, { isWaiting }) else {
            return false
        }
        takeWaiting()?.resume()
        return true
    }

    private func takeWaiting() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let continuation = waiting
        waiting = nil
        return continuation
    }
}

private final class DeadlineLineRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(line)
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class DeadlinePresenceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [HostPeerPresence] = []

    func record(_ peer: HostPeerPresence) {
        lock.lock()
        defer { lock.unlock() }
        seen.append(peer)
    }

    var events: [HostPeerPresence] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }
}

private func deadlineTestHello(_ device: DeviceIdentity) -> SensoriumMessage {
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: device.publicKey, hostCertificateHash: nil
    )
    return .authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: device.publicKey,
        signature: try! device.sign(transcript)
    )
}

/// A control frame of a message type this build does not know, which the
/// host decodes and skips.
private func unknownControlFrame() -> SensoriumTransportPacket {
    let json = Data(#"{"type":"messageFromALaterRevision"}"#.utf8)
    var payload = Data()
    var length = UInt32(json.count).bigEndian
    withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
    payload.append(json)
    return .unrecognized(tag: 0, payload: payload)
}

/// A frame with a transport tag this build does not know, which the host
/// skips without decoding.
private func unknownTagFrame() -> SensoriumTransportPacket {
    .unrecognized(tag: 9, payload: Data([1, 2, 3]))
}

@MainActor
private func deadlineTestController(
    approvedPublicKeys: Set<Data> = [],
    pairing: HostPairingService? = nil,
    onPairingRequested: ((String) -> Void)? = nil
) -> HostSessionController {
    HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: approvedPublicKeys,
        requireAuthentication: true,
        pairing: pairing,
        onPairingRequested: onPairingRequested,
        keyConfinement: .unconfined
    )
}

/// The receive loop notes a message's arrival before the controller handles
/// it, so once the controller has seen the pairIntent the watchdog's first
/// look counts it. Advancing the watchdog any earlier races that loop.
private func waitForPairIntent(_ pairIntents: DeadlineLineRecorder) async {
    expect(
        await waitUntil(timeoutSeconds: 1) { !pairIntents.lines.isEmpty },
        "the pairIntent reaches the controller"
    )
}

private func hostScreenRefusalCount(_ channel: FakeHostByteChannel) -> Int {
    channel.sentPackets.filter { if case .control(.hostScreenRefused) = $0 { return true }; return false }.count
}

private func canvasRefusalCount(_ channel: FakeHostByteChannel) -> Int {
    channel.sentPackets.filter { if case .control(.canvasRefused) = $0 { return true }; return false }.count
}

@MainActor
func runHostConnectionDeadlineTests() async {
    // A peer that never starts a handshake is closed 15 seconds after it was
    // accepted, however many frames it sends that the host skips.
    do {
        let channel = FakeHostByteChannel(scriptedPackets: [unknownControlFrame(), unknownTagFrame()])
        channel.peerAddress = "100.64.1.5"
        let sleeper = SteppedSleeper()
        let events = DeadlineLineRecorder()
        let session = HostNetworkSession(
            connection: channel,
            controller: deadlineTestController(),
            connectionDeadlineSleep: sleeper.sleep,
            onEvent: { events.record($0) }
        )
        session.start()
        channel.feed([unknownControlFrame(), unknownTagFrame(), unknownControlFrame()])
        expect(await sleeper.advance(), "the watchdog waits for the first deadline")
        expect(
            sleeper.requestedDurations == [.seconds(15)],
            "the first wait is the 15-second handshake deadline, got \(sleeper.requestedDurations)"
        )
        expect(
            await waitUntil(timeoutSeconds: 1) { channel.cancelCount > 0 },
            "a peer that sent only frames the host skips is closed at 15 seconds"
        )
        expect(
            await waitUntil(timeoutSeconds: 1) { events.lines.contains { $0.contains("100.64.1.5") } },
            "the close is logged naming the peer's address, got \(events.lines)"
        )
        expect(
            events.lines.filter { $0.contains("100.64.1.5") }.count == 1,
            "in exactly one line, got \(events.lines)"
        )
        session.stop()
        print("PASS: a peer that never starts a handshake is closed 15 seconds after accept, in one line naming it")
    }

    // A peer that announces pairing and then never pairs or authenticates is
    // closed 330 seconds after accept: a code's 300-second life plus 30.
    // Frames it keeps sending in between move nothing.
    do {
        let channel = FakeHostByteChannel(scriptedMessages: [.pairIntent(deviceName: "Probe")])
        channel.peerAddress = "100.64.1.6"
        let sleeper = SteppedSleeper()
        let pairIntents = DeadlineLineRecorder()
        let events = DeadlineLineRecorder()
        let session = HostNetworkSession(
            connection: channel,
            controller: deadlineTestController(
                pairing: HostPairingService(hostIdentity: try! DeviceIdentity.generate()),
                onPairingRequested: { pairIntents.record($0) }
            ),
            connectionDeadlineSleep: sleeper.sleep,
            onEvent: { events.record($0) }
        )
        session.start()
        await waitForPairIntent(pairIntents)
        var elapsed: Duration = .zero
        while true {
            channel.feed([unknownControlFrame(), unknownTagFrame()])
            expect(await sleeper.advance(), "the watchdog is waiting \(elapsed) after accept")
            elapsed = sleeper.requestedDurations.reduce(.zero, +)
            if elapsed >= .seconds(330) {
                break
            }
            expect(
                await waitUntil(timeoutSeconds: 1) { sleeper.isWaiting },
                "the watchdog looks again after \(elapsed)"
            )
            expect(channel.cancelCount == 0, "a peer that announced pairing is still open \(elapsed) after accept")
        }
        expect(elapsed == .seconds(330), "the last deadline is 330 seconds after accept, got \(elapsed)")
        expect(
            await waitUntil(timeoutSeconds: 1) { channel.cancelCount > 0 },
            "a peer that announced pairing and never paired is closed at 330 seconds"
        )
        expect(
            await waitUntil(timeoutSeconds: 1) { events.lines.contains { $0.contains("100.64.1.6") } },
            "the close is logged naming the peer's address, got \(events.lines)"
        )
        expect(
            events.lines.filter { $0.contains("100.64.1.6") }.count == 1,
            "in exactly one line, got \(events.lines)"
        )
        session.stop()
        print("PASS: a peer that announces pairing and never finishes is closed 330 seconds after accept")
    }

    // A paired machine that identifies itself and then asks for neither a
    // host screen nor a session canvas is closed 60 seconds after accept. It
    // is identified by then, so the line naming it is the peer log's own
    // close line, carried by the close reason.
    do {
        let device = try! DeviceIdentity.generate()
        let channel = FakeHostByteChannel(scriptedMessages: [deadlineTestHello(device)])
        channel.peerAddress = "100.64.1.7"
        let sleeper = SteppedSleeper()
        let events = DeadlineLineRecorder()
        let presence = DeadlinePresenceRecorder()
        let session = HostNetworkSession(
            connection: channel,
            controller: deadlineTestController(approvedPublicKeys: [device.publicKey]),
            connectionDeadlineSleep: sleeper.sleep,
            onEvent: { events.record($0) },
            onPeerPresence: { presence.record($0) }
        )
        session.start()
        expect(
            await waitUntil(timeoutSeconds: 1) {
                presence.events.contains { if case .identified = $0 { return true }; return false }
            },
            "the hello is accepted"
        )
        var elapsed: Duration = .zero
        while true {
            channel.feed([unknownControlFrame(), unknownTagFrame()])
            expect(await sleeper.advance(), "the watchdog is waiting \(elapsed) after accept")
            elapsed = sleeper.requestedDurations.reduce(.zero, +)
            if elapsed >= .seconds(60) {
                break
            }
            expect(
                await waitUntil(timeoutSeconds: 1) { sleeper.isWaiting },
                "the watchdog looks again after \(elapsed)"
            )
            expect(channel.cancelCount == 0, "an identified machine is still open \(elapsed) after accept")
        }
        expect(elapsed == .seconds(60), "an identified machine's deadline is 60 seconds after accept, got \(elapsed)")
        expect(
            await waitUntil(timeoutSeconds: 1) { channel.cancelCount > 0 },
            "an identified machine that asked for no screen is closed at 60 seconds"
        )
        expect(
            await waitUntil(timeoutSeconds: 1) {
                presence.events.contains {
                    if case let .closed(reason) = $0 { return reason?.contains("60 seconds") == true }
                    return false
                }
            },
            "its close reason names the deadline, got \(presence.events)"
        )
        expect(
            !events.lines.contains { $0.contains("100.64.1.7") },
            "and no second line names it by address, got \(events.lines)"
        )
        session.stop()
        print("PASS: an identified machine that asks for no screen is closed 60 seconds after accept, naming why")
    }

    // A pairing request still on its way when a deadline closes the
    // connection pairs nothing: the viewer would never hear it was approved.
    do {
        let device = try! DeviceIdentity.generate()
        let pairing = HostPairingService(hostIdentity: try! DeviceIdentity.generate())
        pairing.issueCode(code: "424242")
        let pairIntents = DeadlineLineRecorder()
        let controller = deadlineTestController(pairing: pairing, onPairingRequested: { pairIntents.record($0) })
        let channel = FakeHostByteChannel(scriptedMessages: [.pairIntent(deviceName: "Probe")])
        let sleeper = SteppedSleeper()
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            connectionDeadlineSleep: sleeper.sleep
        )
        session.start()
        await waitForPairIntent(pairIntents)
        while channel.cancelCount == 0, sleeper.requestedDurations.reduce(.zero, +) < .seconds(330) {
            expect(await sleeper.advance(), "the watchdog keeps watching a connection that announced pairing")
        }
        expect(
            await waitUntil(timeoutSeconds: 1) { channel.cancelCount > 0 },
            "the connection is closed at 330 seconds"
        )
        let late = signedPairRequest(deviceName: "Probe", identity: device, code: "424242")
        var refused = false
        do {
            _ = try controller.handle(late)
        } catch {
            refused = true
        }
        expect(refused, "a pairing request handled after the deadline closed its connection is refused")
        guard case let .pairRequest(deviceName, publicKey, code, signature) = late,
              case .pairApproved = pairing.handlePairRequest(
                deviceName: deviceName, publicKey: publicKey, code: code, signature: signature
              ) else {
            expect(false, "and the code it carried is still unspent")
            return
        }
        session.stop()
        print("PASS: a pairing request that arrives after a deadline closed its connection is refused and spends no code")
    }

    // A code typed late in its life, after the 60-second check and before
    // the 330-second one, pairs, and the paired connection is not closed.
    do {
        let device = try! DeviceIdentity.generate()
        let pairing = HostPairingService(hostIdentity: try! DeviceIdentity.generate())
        pairing.issueCode(code: "424242")
        let channel = FakeHostByteChannel(scriptedMessages: [.pairIntent(deviceName: "Probe")])
        channel.peerAddress = "100.64.1.8"
        let sleeper = SteppedSleeper()
        let events = DeadlineLineRecorder()
        let pairIntents = DeadlineLineRecorder()
        let session = HostNetworkSession(
            connection: channel,
            controller: deadlineTestController(pairing: pairing, onPairingRequested: { pairIntents.record($0) }),
            connectionDeadlineSleep: sleeper.sleep,
            onEvent: { events.record($0) }
        )
        session.start()
        await waitForPairIntent(pairIntents)
        expect(await sleeper.advance(), "the watchdog waits for the 15-second deadline")
        expect(await sleeper.advance(), "and then for the 60-second one")
        expect(
            await waitUntil(timeoutSeconds: 1) { sleeper.isWaiting },
            "and then for the 330-second one"
        )
        expect(
            sleeper.requestedDurations == [.seconds(15), .seconds(45), .seconds(270)],
            "the deadlines fall 15, 60 and 330 seconds after accept, got \(sleeper.requestedDurations)"
        )
        expect(channel.cancelCount == 0, "a connection on the code step is open 60 seconds after accept")
        channel.feed([signedPairRequest(deviceName: "Probe", identity: device, code: "424242")])
        expect(
            await waitUntil(timeoutSeconds: 1) {
                channel.sentPackets.contains { if case .control(.pairApproved) = $0 { return true }; return false }
            },
            "the code typed before the last deadline pairs"
        )
        expect(await sleeper.advance(), "the watchdog reaches the 330-second deadline")
        try? await Task.sleep(for: .milliseconds(100))
        expect(channel.cancelCount == 0, "a connection that paired before 330 seconds is not closed at 330")
        expect(!events.lines.contains { $0.contains("100.64.1.8") }, "and nothing logs it as closed, got \(events.lines)")
        session.stop()
        print("PASS: a code typed just before the 330-second deadline pairs and its connection stays open")
    }

    // A real session -- hello, then a canvas -- meets every deadline at the
    // first look, and the watchdog stops watching it.
    do {
        let device = try! DeviceIdentity.generate()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [device.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        let channel = FakeHostByteChannel(scriptedMessages: [
            deadlineTestHello(device),
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
            .timeSyncRequest(clientTimeNanoseconds: 1),
        ])
        let sleeper = SteppedSleeper()
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            connectionDeadlineSleep: sleeper.sleep
        )
        session.attach(coordinator: HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace())
        ))
        session.start()
        expect(
            await waitUntil(timeoutSeconds: 1) {
                channel.sentPackets.contains {
                    if case let .control(.timeSyncReply(client, _)) = $0 { return client == 1 }
                    return false
                }
            },
            "the session is live"
        )
        expect(await sleeper.advance(), "the watchdog waits for the first deadline")
        try? await Task.sleep(for: .milliseconds(100))
        expect(
            !sleeper.isWaiting && sleeper.requestedDurations == [.seconds(15)],
            "a live session leaves the watchdog nothing more to wait for, got \(sleeper.requestedDurations)"
        )
        expect(channel.cancelCount == 0, "and is never closed by it")
        session.stop()
        print("PASS: a live session meets every connection deadline and is never closed by one")
    }

    // A request for a screen that the host refuses leaves a connection with
    // no session and, once it has asked, no deadline. The host closes it
    // right after the refusal is written, so the viewer still hears why.
    do {
        let device = try! DeviceIdentity.generate()
        let channel = FakeHostByteChannel(scriptedMessages: [
            deadlineTestHello(device),
            .hostScreenRequest(token: Data([1, 2, 3]), resumeTicket: nil),
        ])
        let session = HostNetworkSession(
            connection: channel,
            controller: deadlineTestController(approvedPublicKeys: [device.publicKey]),
            connectionDeadlineSleep: SteppedSleeper().sleep
        )
        session.start()
        expect(
            await waitUntil(timeoutSeconds: 2) { hostScreenRefusalCount(channel) >= 2 },
            "the offer after the hello and the refusal of the request are both written, got \(channel.sentPackets)"
        )
        expect(
            await waitUntil(timeoutSeconds: 1) { channel.cancelCount > 0 },
            "a refused host screen request closes a connection that has no session"
        )
        session.stop()
        print("PASS: a refused host screen request closes a connection with no session, after the refusal is written")
    }

    do {
        let device = try! DeviceIdentity.generate()
        let channel = FakeHostByteChannel(scriptedMessages: [
            deadlineTestHello(device),
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
        ])
        let session = HostNetworkSession(
            connection: channel,
            controller: deadlineTestController(approvedPublicKeys: [device.publicKey]),
            connectionDeadlineSleep: SteppedSleeper().sleep
        )
        session.start()
        expect(
            await waitUntil(timeoutSeconds: 2) { canvasRefusalCount(channel) >= 1 },
            "the refusal of the canvas request is written, got \(channel.sentPackets)"
        )
        expect(
            await waitUntil(timeoutSeconds: 1) { channel.cancelCount > 0 },
            "a refused canvas request closes a connection that has no session"
        )
        session.stop()
        print("PASS: a refused canvas request closes a connection with no session, after the refusal is written")
    }

    // The offer an unarmed device gets right after its hello is not a reply
    // to a request, so it closes nothing.
    do {
        let device = try! DeviceIdentity.generate()
        let channel = FakeHostByteChannel(scriptedMessages: [deadlineTestHello(device)])
        let session = HostNetworkSession(
            connection: channel,
            controller: deadlineTestController(approvedPublicKeys: [device.publicKey]),
            connectionDeadlineSleep: SteppedSleeper().sleep
        )
        session.start()
        expect(
            await waitUntil(timeoutSeconds: 2) { hostScreenRefusalCount(channel) >= 1 },
            "an unarmed device is offered nothing right after its hello"
        )
        try? await Task.sleep(for: .milliseconds(100))
        expect(channel.cancelCount == 0, "and the offer does not close the connection")
        session.stop()
        print("PASS: the unprompted offer to an unarmed device does not close its connection")
    }

    // A refusal on a connection that already has a session ends nothing.
    do {
        let device = try! DeviceIdentity.generate()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [device.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        let channel = FakeHostByteChannel(scriptedMessages: [
            deadlineTestHello(device),
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
            .hostScreenRequest(token: Data([1, 2, 3]), resumeTicket: nil),
            .timeSyncRequest(clientTimeNanoseconds: 2),
        ])
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            connectionDeadlineSleep: SteppedSleeper().sleep
        )
        session.attach(coordinator: HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeCanvasMedia()),
            videoSink: FakeVideoSink(),
            workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace())
        ))
        session.start()
        expect(
            await waitUntil(timeoutSeconds: 2) {
                channel.sentPackets.contains {
                    if case let .control(.timeSyncReply(client, _)) = $0 { return client == 2 }
                    return false
                }
            },
            "the request after the refused one is still answered"
        )
        expect(hostScreenRefusalCount(channel) >= 2, "the host screen request was refused while the canvas was live")
        expect(channel.cancelCount == 0, "a refusal on a connection with a live session leaves it open")
        session.stop()
        print("PASS: a refusal on a connection that already has a session leaves it open")
    }

    // A canvas request the creation gate rejects is answered, and a
    // connection with no canvas to carry on with is then closed. A second
    // surface rejected while the first is live leaves the session open.
    do {
        let device = try! DeviceIdentity.generate()
        let adapter = FakeVirtualDisplayAdapter()
        adapter.acquireError = CanvasCreationGateError.creationInProgress
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: adapter)),
            approvedPublicKeys: [device.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        let channel = FakeHostByteChannel(scriptedMessages: [
            deadlineTestHello(device),
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
        ])
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            connectionDeadlineSleep: SteppedSleeper().sleep
        )
        session.start()
        expect(
            await waitUntil(timeoutSeconds: 2) { canvasRefusalCount(channel) >= 1 },
            "the gate's refusal of the first canvas is written, got \(channel.sentPackets)"
        )
        expect(
            await waitUntil(timeoutSeconds: 1) { channel.cancelCount > 0 },
            "a canvas request the gate refused closes a connection that has no session"
        )
        session.stop()
        print("PASS: a canvas request refused by the creation gate closes a connection with no session")
    }

    do {
        let device = try! DeviceIdentity.generate()
        let secondAdapter = FakeVirtualDisplayAdapter()
        secondAdapter.acquireError = CanvasCreationGateError.creationInProgress
        let controller = HostSessionController(
            sessions: CanvasSurfaceSlots(
                surface0: VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()),
                surface1: VirtualDisplaySession(adapter: secondAdapter)
            ),
            approvedPublicKeys: [device.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        let channel = FakeHostByteChannel(scriptedMessages: [
            deadlineTestHello(device),
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0),
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 1),
            .timeSyncRequest(clientTimeNanoseconds: 3),
        ])
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            connectionDeadlineSleep: SteppedSleeper().sleep
        )
        session.start()
        expect(
            await waitUntil(timeoutSeconds: 2) {
                channel.sentPackets.contains {
                    if case let .control(.timeSyncReply(client, _)) = $0 { return client == 3 }
                    return false
                }
            },
            "the request after the gate's refusal of the second surface is still answered"
        )
        expect(canvasRefusalCount(channel) == 1, "the second surface was refused, got \(channel.sentPackets)")
        expect(channel.cancelCount == 0, "a second surface refused during a live session leaves it open")
        session.stop()
        print("PASS: a second surface refused by the creation gate leaves a live session open")
    }

    // A request the host handles without leaving a session behind ends the
    // connection, whether it was answered, refused with an error that is not
    // fatal, or changed the connection's shape before failing.
    do {
        let device = try! DeviceIdentity.generate()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [device.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        let channel = FakeHostByteChannel(scriptedMessages: [
            deadlineTestHello(device),
            .canvasRequest(logicalWidth: 1, logicalHeight: 1, scale: 1, surfaceID: nil),
        ])
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            connectionDeadlineSleep: SteppedSleeper().sleep
        )
        session.start()
        expect(
            await waitUntil(timeoutSeconds: 2) { channel.cancelCount > 0 },
            "a canvas request with a geometry the host does not offer closes a connection that has no session"
        )
        session.stop()
        print("PASS: a canvas request with bad geometry closes a connection with no session")
    }

    do {
        let device = try! DeviceIdentity.generate()
        let secondAdapter = FakeVirtualDisplayAdapter()
        secondAdapter.acquireError = HostSessionControllerError.unexpectedMessage
        let controller = HostSessionController(
            sessions: CanvasSurfaceSlots(
                surface0: VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()),
                surface1: VirtualDisplaySession(adapter: secondAdapter)
            ),
            approvedPublicKeys: [device.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        let channel = FakeHostByteChannel(scriptedMessages: [
            deadlineTestHello(device),
            .displayCount(2),
            .hostScreenRequest(token: Data([1, 2, 3]), resumeTicket: nil),
        ])
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            connectionDeadlineSleep: SteppedSleeper().sleep
        )
        session.start()
        expect(
            await waitUntil(timeoutSeconds: 2) { canvasRefusalCount(channel) >= 1 },
            "the failed display count change is answered, got \(channel.sentPackets)"
        )
        expect(
            await waitUntil(timeoutSeconds: 1) { channel.cancelCount > 0 },
            "a display count change that fails on a connection with no session closes it"
        )
        session.stop()
        print("PASS: a failed first display count change closes a connection with no session")
    }
}

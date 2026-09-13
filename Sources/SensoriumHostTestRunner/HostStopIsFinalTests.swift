import Foundation
import SensoriumCore
import SensoriumHost

/// Stop, as the person at the host means it.
///
/// CLAUDE.md requires "a control that stops it immediately". A viewer cannot
/// tell a socket the operator closed on purpose from one the network dropped,
/// so a session torn down without a word is redialled within a second and Stop
/// appears to do nothing. The reason travels on the wire for exactly that
/// reason.
@MainActor
func runHostStopIsFinalTests() async {
    do {
        // Stop names itself to the peer, while the socket is still open
        let adapter = FakeVirtualDisplayAdapter()
        let session = VirtualDisplaySession(adapter: adapter)
        let controller = HostSessionController(sessions: surfaceZeroOnly(session), keyConfinement: .unconfined)
        _ = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expect(session.isActive, "the canvas is established before Stop is pressed")
        let channel = FakeHostByteChannel(scriptedMessages: [])
        let networkSession = HostNetworkSession(connection: channel, controller: controller)

        networkSession.stop()
        try! await Task.sleep(for: .milliseconds(200))

        expect(
            channel.packetsSentBeforeCancel.contains(.control(.goodbye(reason: GoodbyeReason.stoppedByHost))),
            "Stop tells the peer why before the socket closes, so the viewer knows this was a person and not a dropout"
        )
        expect(channel.cancelCount == 1, "and the transport is closed exactly once after that word is out")
        expect(!session.isActive, "and the session canvas is still released")

        print("PASS: Stop names itself to the peer before closing the socket, and still releases the canvas")
    }

    do {
        // A write that never lands must not strand the session
        // A peer that has stopped reading is exactly when Stop matters most.
        // The goodbye is best effort: the socket closes and the session ends
        // whether or not the bytes ever left.
        let adapter = FakeVirtualDisplayAdapter()
        let session = VirtualDisplaySession(adapter: adapter)
        let controller = HostSessionController(sessions: surfaceZeroOnly(session), keyConfinement: .unconfined)
        _ = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        let channel = FakeHostByteChannel(scriptedMessages: [])
        channel.sendBytesError = HostNetworkSessionError.closed
        let networkSession = HostNetworkSession(connection: channel, controller: controller)

        networkSession.stop()
        try! await Task.sleep(for: .milliseconds(200))

        expect(channel.cancelCount >= 1, "a goodbye that cannot be written still closes the transport")
        expect(!session.isActive, "and still releases the session canvas")

        print("PASS: a goodbye that cannot be written stops the session anyway")
    }

    do {
        // A peer that accepts no bytes delays Stop, never defeats it
        // The farewell is written to a link that has stopped moving, so it is
        // still outstanding when the deadline closes the socket underneath it.
        let adapter = FakeVirtualDisplayAdapter()
        let session = VirtualDisplaySession(adapter: adapter)
        let controller = HostSessionController(sessions: surfaceZeroOnly(session), keyConfinement: .unconfined)
        _ = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        let channel = FakeHostByteChannel(scriptedMessages: [])
        channel.sendDelay = .seconds(10)
        let networkSession = HostNetworkSession(connection: channel, controller: controller)

        let startedAt = ContinuousClock.now
        networkSession.stop()
        expect(channel.cancelCount == 0, "the write is under way, so nothing has closed yet")
        try! await Task.sleep(for: .milliseconds(1_400))

        expect(
            channel.cancelCount >= 1,
            "a farewell the peer never accepts must not hold the connection open past the deadline"
        )
        expect(
            startedAt.duration(to: ContinuousClock.now) < .seconds(3),
            "and the close comes on that deadline, nowhere near the ten seconds the write would take"
        )
        expect(
            channel.packetsSentBeforeCancel.isEmpty,
            "the socket closed with the goodbye still in flight, which is what best effort means"
        )
        expect(!session.isActive, "and the session canvas was released when Stop was pressed, not when the write gave up")

        print("PASS: a peer that accepts no bytes delays Stop by the farewell deadline and no longer")
    }
}

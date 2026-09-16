import Foundation
import SensoriumCore
import SensoriumHost

/// Collects what the transport reported about who is on the other end.
private final class SilencePresenceRecorder: @unchecked Sendable {
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

/// Starts a session and drives it to a live, streaming canvas before handing
/// control back, so a test's silence window is measured from the state the
/// watchdog is actually gated on rather than from before pairing finished.
@MainActor
private func startStreamingSession(
    channel: FakeHostByteChannel,
    controller: HostSessionController,
    viewerSilenceTimeout: Duration,
    onPeerPresence: (@Sendable (HostPeerPresence) -> Void)? = nil
) async -> HostNetworkSession {
    let session = HostNetworkSession(
        connection: channel,
        controller: controller,
        viewerSilenceTimeout: viewerSilenceTimeout,
        onPeerPresence: onPeerPresence
    )
    session.attach(coordinator: HostSessionCoordinator(
        controller: controller,
        media: onlyOnSurfaceZero(FakeCanvasMedia()),
        videoSink: FakeVideoSink(),
        workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace())
    ))
    session.start()
    let answered = await waitUntil(timeoutSeconds: 1) {
        channel.sentPackets.contains {
            if case let .control(.timeSyncReply(client, _)) = $0 { return client == 1 }
            return false
        }
    }
    expect(answered, "the canvas request that establishes streaming was answered before the silence window is measured")
    return session
}

@MainActor
func runHostViewerSilenceWatchdogTests() async {
    // A channel that never delivers anything again, once its session is
    // already streaming, is cancelled by the session's own watchdog after
    // `viewerSilenceTimeout` of true silence -- the transport's own idle
    // timeout is not what does this.
    do {
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        let channel = FakeHostByteChannel(scriptedMessages: [
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
            .timeSyncRequest(clientTimeNanoseconds: 1),
        ])
        let presence = SilencePresenceRecorder()
        let session = await startStreamingSession(
            channel: channel,
            controller: controller,
            viewerSilenceTimeout: .milliseconds(100),
            onPeerPresence: { presence.record($0) }
        )

        let cancelled = await waitUntil(timeoutSeconds: 1) { channel.cancelCount > 0 }
        expect(cancelled, "the watchdog cancels the channel once the viewer has been silent for the configured timeout")
        let closed = await waitUntil(timeoutSeconds: 1) {
            presence.events.contains { if case .closed = $0 { return true }; return false }
        }
        expect(closed, "the cancelled transport still reports its own ending")
        expect(
            presence.events.contains {
                if case let .closed(reason) = $0 { return reason?.contains("viewer") == true }
                return false
            },
            "the close reason names viewer silence rather than a bare cancel, got \(presence.events)"
        )
        expect(
            presence.events.contains {
                if case let .closed(reason) = $0 { return reason?.contains("100 milliseconds") == true }
                return false
            },
            "the close reason names the timeout this session was actually configured with, not a hardcoded default, got \(presence.events)"
        )
        session.stop()
        print("PASS: a streaming session with a silent channel is cancelled and closed by the viewer-silence watchdog, naming why")
    }

    // Pairing can sit idle for minutes while a person reads a code off the
    // host and types it into the viewer; the watchdog must not count any of
    // that against the connection, so one that never reaches a live surface
    // is never cancelled by it, no matter how long its channel stays quiet.
    do {
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        let channel = FakeHostByteChannel(scriptedMessages: [])
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            viewerSilenceTimeout: .milliseconds(100)
        )
        session.start()
        try? await Task.sleep(for: .milliseconds(250))
        expect(
            channel.cancelCount == 0,
            "a connection that never became a live session is not cancelled by the silence watchdog, however long it stays quiet"
        )
        session.stop()
        print("PASS: a connection that never reaches a live session is left alone by the viewer-silence watchdog")
    }

    // Bytes received inside the window keep a streaming session alive: fed a
    // message partway through, it is not cancelled once the window from
    // before that message would have elapsed.
    do {
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        let channel = FakeHostByteChannel(scriptedMessages: [
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil),
            .timeSyncRequest(clientTimeNanoseconds: 1),
        ])
        let session = await startStreamingSession(
            channel: channel,
            controller: controller,
            viewerSilenceTimeout: .milliseconds(200)
        )
        Task {
            try? await Task.sleep(for: .milliseconds(80))
            channel.feed([.timeSyncRequest(clientTimeNanoseconds: 2)])
        }
        try? await Task.sleep(for: .milliseconds(260))
        expect(
            channel.cancelCount == 0,
            "a message received inside the silence window keeps the watchdog from cancelling the channel"
        )
        session.stop()
        print("PASS: bytes received within the silence window keep a streaming session alive")
    }
}

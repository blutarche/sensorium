import AppKit
import Foundation
import Network
import SensoriumCore
import SensoriumHost

/// The host window's Stop button, pressed the way a person presses it, against
/// the process-wide `HostLiveSessionSlot` that `sensoriumd` builds once and
/// hands to both Stop controls.
///
/// A host serves more than one connection in a run -- a pairing attempt and
/// the session that follows it, or a connection whose death this machine
/// notices only after the viewer has already redialled -- and every one of
/// them eventually ends. Each ending reaches the same slot, so an ending that
/// belongs to a connection a newer one has already replaced must leave the
/// slot alone; emptying it there is what leaves Stop doing nothing at all
/// while a session is streaming.
private final class PeerPresenceRecorder: @unchecked Sendable {
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

@MainActor
func runHostSetupStopButtonTests() async {
    func stopButton(in controller: HostSetupWindowController) -> NSButton {
        for child in Mirror(reflecting: controller).children {
            if child.label == "stopButton", let button = child.value as? NSButton {
                return button
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named stopButton")
    }

    /// One accepted connection, built the way `sensoriumd` builds one: its own
    /// controller, its own session, and a coordinator attached to that session
    /// afterwards, which is what holds the session up while the slot below
    /// only points at it.
    func acceptConnection() -> (
        session: HostNetworkSession,
        channel: FakeHostByteChannel,
        presence: PeerPresenceRecorder
    ) {
        let factory = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        let controller = factory.makeController()
        let channel = FakeHostByteChannel(scriptedMessages: [])
        let presence = PeerPresenceRecorder()
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            onPeerPresence: { presence.record($0) }
        )
        session.attach(coordinator: HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeCanvasMedia()),
            videoSink: session,
            workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace())
        ))
        return (session, channel, presence)
    }

    do {
        // A connection that has already been replaced ends. The slot
        // must keep the session that replaced it, so Stop still ends
        // the one that is streaming.
        let slot = HostLiveSessionSlot()

        let first = acceptConnection()
        slot.session = first.session
        first.session.start()

        // The viewer redials, and this machine accepts the new connection
        // before it has noticed the old one is gone.
        let second = acceptConnection()
        slot.session = second.session
        second.session.start()

        // Only now does the first connection's own read fail, reporting a
        // close for a connection nothing is serving any more.
        first.session.stop()
        slot.release(first.session)

        expect(
            slot.session === second.session,
            "a superseded connection ending must leave the live session in the slot both Stop controls read"
        )

        let controller = HostSetupWindowController(
            status: HostOperatorStatus(
                connection: .serving(peerName: "Kestrel Laptop Pro"),
                permissions: HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
            ),
            onRevealPairingCode: {},
            onStop: { slot.session?.stop() },
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        let button = stopButton(in: controller)
        expect(!button.isHidden, "a live session is exactly when the Stop button is on screen to be pressed")
        expect(second.channel.cancelCount == 0, "the live connection is still up before anybody presses Stop")

        button.performClick(nil)
        // The socket closes once Stop's own goodbye has been written to the
        // peer, so this is a moment later than the click.
        try! await Task.sleep(for: .milliseconds(200))

        expect(
            second.presence.events.contains(.closed(reason: nil)),
            "pressing Stop must end the live session -- its own close is what the host logs and the menu bar reads"
        )
        expect(
            second.channel.cancelCount >= 1,
            "pressing Stop must cancel the live connection -- got \(second.channel.cancelCount) cancels"
        )

        print("PASS: Stop ends the live session even after an already-replaced connection has closed")
    }

    do {
        // The live connection's own ending still empties the slot:
        // there is nothing left to stop, and Stop must not reach a
        // session that has already ended.
        let slot = HostLiveSessionSlot()
        let only = acceptConnection()
        slot.session = only.session
        only.session.start()

        only.session.stop()
        slot.release(only.session)

        expect(slot.session == nil, "once the session in the slot has ended, there is nothing for Stop to act on")

        print("PASS: the live connection's own ending empties the slot both Stop controls read")
    }
}

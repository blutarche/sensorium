import AppKit
import Foundation
import Network
import SensoriumCore
import SensoriumHost

/// Whether a machine is connected and whether a pairing code is on screen are
/// two independent facts about this host, and the operator must be able to
/// read both at once. Showing the code is what a person does *while* waiting
/// to pair a second machine; it must never take the connected machine, or the
/// Stop control that ends it, off the screen.
/// Collects what the transport reported about who is on the other end, from
/// whatever thread the read loop happens to report it on.
private final class ClosingPresenceRecorder: @unchecked Sendable {
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
func runHostConnectionAndPairingTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
    let peerName = "Kestrel MacBook Pro"

    func button(_ label: String, in controller: HostSetupWindowController) -> NSButton {
        for child in Mirror(reflecting: controller).children {
            if child.label == label, let button = child.value as? NSButton {
                return button
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named \(label)")
    }

    func statusItem(in presence: HostMenuBarPresence) -> NSStatusItem {
        for child in Mirror(reflecting: presence).children {
            if child.label == "statusItem", let item = child.value as? NSStatusItem?, let item {
                return item
            }
        }
        fatalError("HostMenuBarPresence no longer has a stored property named statusItem, or install() left it nil")
    }

    /// One accepted connection, built the way `sensoriumd` builds one, so a
    /// Stop press in these tests reaches a real session over a real channel.
    func acceptConnection() -> (session: HostNetworkSession, channel: FakeHostByteChannel) {
        let factory = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        let controller = factory.makeController()
        let channel = FakeHostByteChannel(scriptedMessages: [])
        let session = HostNetworkSession(connection: channel, controller: controller)
        session.attach(coordinator: HostSessionCoordinator(
            controller: controller,
            media: onlyOnSurfaceZero(FakeCanvasMedia()),
            videoSink: session,
            workspaces: onlyOnSurfaceZero(FakeCanvasWorkspace())
        ))
        return (session, channel)
    }

    /// A host that is listening, with a machine connected to it.
    func servingStore() -> HostOperatorStatusStore {
        let store = HostOperatorStatusStore(permissions: granted)
        store.beginHosting(address: "203.0.113.42")
        store.apply(.identified(deviceName: peerName), from: HostConnectionToken())
        return store
    }

    let issued = Date()

    do {
        // A code on screen is not a fact about who is connected.
        let store = servingStore()
        store.showPairingCode("418297", expiresAt: issued.addingTimeInterval(272))
        let presentation = store.status.presentation(now: issued)

        expect(
            presentation.headline == "Connected to \(peerName)",
            "showing a pairing code must leave the connected machine on screen -- got \"\(presentation.headline)\""
        )
        expect(
            presentation.eyebrow == "CONNECTED",
            "showing a pairing code must not return the eyebrow to a waiting state -- got \"\(presentation.eyebrow)\""
        )
        expect(
            presentation.pairingCode == "418 297",
            "the code is still shown, beside the connection rather than instead of it -- got \(String(describing: presentation.pairingCode))"
        )

        print("PASS: showing a pairing code while a machine is connected leaves the connection on screen")
    }

    do {
        // And the Stop control keeps working while the code is up.
        let store = servingStore()
        store.showPairingCode("418297", expiresAt: issued.addingTimeInterval(272))

        let slot = HostLiveSessionSlot()
        let live = acceptConnection()
        slot.session = live.session
        live.session.start()

        let controller = HostSetupWindowController(
            status: store.status,
            onRevealPairingCode: {},
            onStop: { slot.session?.stop() },
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        let stop = button("stopButton", in: controller)
        expect(!stop.isHidden, "a machine is connected, so Stop is on screen whatever the pairing section is showing")

        stop.performClick(nil)
        // The socket closes once Stop's own goodbye has been written to the
        // peer, so this is a moment later than the click.
        try! await Task.sleep(for: .milliseconds(200))
        expect(
            live.channel.cancelCount >= 1,
            "Stop must end the live session while a code is on screen -- got \(live.channel.cancelCount) cancels"
        )

        print("PASS: Stop is on screen and ends the session while a pairing code is shown")
    }

    do {
        // The pairing code is a section with its own Hide control.
        let store = servingStore()
        store.showPairingCode("418297", expiresAt: issued.addingTimeInterval(272))

        var hidden = false
        let controller = HostSetupWindowController(
            status: store.status,
            onRevealPairingCode: {},
            onStop: {},
            onHidePairingCode: { hidden = true },
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        let hide = button("hideCodeButton", in: controller)
        let reveal = button("revealButton", in: controller)
        expect(!hide.isHidden, "a code on screen is a code the operator can take back off it")
        expect(reveal.isHidden, "the code itself replaces the button that asked for it")
        expect(hide.title == "Hide code", "the control says what it does -- got \"\(hide.title)\"")

        hide.performClick(nil)
        expect(hidden, "tapping Hide code must call onHidePairingCode")

        store.hidePairingCode()
        controller.update(store.status)
        expect(button("hideCodeButton", in: controller).isHidden, "with no code on screen there is nothing to hide")
        expect(!button("revealButton", in: controller).isHidden, "the section returns to offering the code again")
        expect(
            !button("stopButton", in: controller).isHidden,
            "hiding the code must leave the connected machine, and its Stop control, exactly where they were"
        )

        print("PASS: the pairing code section has its own Hide code control, and hiding it leaves the connection alone")
    }

    do {
        // Hiding the code leaves the connection untouched.
        let store = servingStore()
        store.showPairingCode("418297", expiresAt: issued.addingTimeInterval(272))
        store.hidePairingCode()
        let presentation = store.status.presentation(now: issued)

        expect(presentation.pairingCode == nil, "a hidden code is off the screen")
        expect(
            presentation.headline == "Connected to \(peerName)",
            "hiding the code must not disconnect anybody -- got \"\(presentation.headline)\""
        )

        print("PASS: hiding the pairing code leaves the connected machine on screen")
    }

    do {
        // A code that has been used is a code nobody should read out.
        let store = HostOperatorStatusStore(permissions: granted)
        store.beginHosting(address: "203.0.113.42")
        store.showPairingCode("418297", expiresAt: issued.addingTimeInterval(272))
        store.recordPairingApproved(deviceName: peerName)
        let presentation = store.status.presentation(now: issued)

        expect(presentation.pairingCode == nil, "an approved pairing takes its code off the screen")
        expect(
            presentation.headline == "Waiting for \(peerName) to finish pairing",
            "the approval itself is what the window now reports -- got \"\(presentation.headline)\""
        )

        print("PASS: an approved pairing takes its code off the screen")
    }

    do {
        // An expired code is withdrawn rather than left to be read.
        let store = servingStore()
        store.showPairingCode("418297", expiresAt: issued.addingTimeInterval(272))
        let presentation = store.status.presentation(now: issued.addingTimeInterval(273))

        expect(presentation.pairingCode == nil, "an expired code is withdrawn")
        expect(
            presentation.headline == "Connected to \(peerName)",
            "and expiry says nothing about who is connected -- got \"\(presentation.headline)\""
        )

        print("PASS: a code that expires is withdrawn without disturbing the connection")
    }

    do {
        // A close belonging to a connection a newer one has already
        // replaced must leave the live session on screen.
        let store = HostOperatorStatusStore(permissions: granted)
        store.beginHosting(address: "203.0.113.42")

        let superseded = HostConnectionToken()
        store.apply(.identified(deviceName: "Kestrel MacBook Air"), from: superseded)

        // The viewer redials; this machine accepts the new connection before
        // it has noticed the old one is gone.
        let live = HostConnectionToken()
        store.apply(.identified(deviceName: peerName), from: live)

        // Only now does the superseded connection's own read fail.
        store.apply(.closed(reason: nil), from: superseded)

        expect(
            store.status.connection == .serving(peerName: peerName),
            "a superseded connection ending says nothing about the one being served"
        )

        let controller = HostSetupWindowController(
            status: store.status,
            onRevealPairingCode: {},
            onStop: {},
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
        expect(
            !button("stopButton", in: controller).isHidden,
            "the machine is still connected, so its Stop button is still on screen"
        )

        store.apply(.closed(reason: nil), from: live)
        expect(
            store.status.connection == .hosting(address: "203.0.113.42"),
            "the connection actually being served ending does return the host to waiting"
        )

        print("PASS: only the connection being served can take the connected machine off the screen")
    }

    do {
        // A connection that dies of something names it
        let droppedFactory = HostConnectionSessionFactory(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            keyConfinement: .unconfined
        )
        let droppedController = droppedFactory.makeController()
        let droppedChannel = FakeHostByteChannel(scriptedMessages: [.timeSyncRequest(clientTimeNanoseconds: 1)])
        // What a link that has gone away does to the reply this host is in
        // the middle of writing.
        droppedChannel.sendBytesError = NSError(
            domain: NSPOSIXErrorDomain,
            code: 57,
            userInfo: [NSLocalizedDescriptionKey: "The network connection was lost."]
        )
        let droppedPresence = ClosingPresenceRecorder()
        let droppedSession = HostNetworkSession(
            connection: droppedChannel,
            controller: droppedController,
            onPeerPresence: { droppedPresence.record($0) }
        )
        droppedSession.start()
        let reportedClose = await waitUntil(timeoutSeconds: 2) { !droppedPresence.events.isEmpty }
        expect(reportedClose, "a connection whose write fails ends, and ending is reported")
        expect(
            droppedPresence.events == [.closed(reason: "macOS reported: The network connection was lost")],
            "and what ended it is carried with the ending, so the host log can say why the machine went away rather than only that it did -- got: \(droppedPresence.events)"
        )
        droppedSession.stop()
        print("PASS: a connection that drops reports what ended it, not only that it ended")
    }

    do {
        // The menu bar reads the same truth as the window.
        let store = servingStore()
        store.showPairingCode("418297", expiresAt: issued.addingTimeInterval(272))

        var stopped = false
        let presence = HostMenuBarPresence(status: store.status, onStop: { stopped = true }, quit: {})
        presence.install()
        guard let menu = statusItem(in: presence).menu else {
            fatalError("the status item's menu was never installed")
        }
        guard let stop = menu.items.first(where: { $0.title == "Stop" }) else {
            fatalError("no menu item titled Stop was found while a machine is connected and a code is shown")
        }
        guard let action = stop.action, let target = stop.target as? NSObject else {
            fatalError("the Stop menu item has no target/action wired")
        }
        _ = target.perform(action, with: stop)
        expect(stopped, "the menu bar offers Stop for the same connection the window does, code on screen or not")

        print("PASS: the menu bar offers a working Stop while a pairing code is shown")
    }
}

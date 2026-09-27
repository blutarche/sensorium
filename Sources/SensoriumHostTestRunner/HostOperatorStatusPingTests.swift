import Foundation
import SensoriumHost

/// `HostOperatorStatusStore.recordPing` and its effect on
/// `HostOperatorPresentation.menuBarTitle` -- pure, no AppKit, no window
/// server: the words the operator reads are decided and tested here, exactly
/// as `HostOperatorStatus`'s own file-level comment says they should be.
@MainActor
func runHostOperatorStatusPingTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    do {
        // A live host-screen session shows the peer's name until the first
        // ping sample arrives, then the ping replaces it.
        let store = HostOperatorStatusStore(permissions: granted)
        let connection = HostConnectionToken()
        store.setConnection(.servingHostScreen(peerName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        expect(
            store.status.presentation(now: Date()).menuBarTitle == "Kestrel Laptop Pro",
            "before any sample, the host-screen title stays the peer's name"
        )

        store.recordPing(roundTripNanoseconds: 8_000_000, atSeconds: 0, from: connection)
        expect(
            store.status.presentation(now: Date()).menuBarTitle == "8ms",
            "a live ping replaces the peer name in the title"
        )

        print("PASS: a live host-screen session's title falls back to the peer's name until a ping arrives, then shows the ping")
    }

    do {
        // A canvas session shows no title at all until a ping arrives -- the
        // existing quiet presentation is otherwise untouched.
        let store = HostOperatorStatusStore(permissions: granted)
        let connection = HostConnectionToken()
        store.setConnection(.serving(peerName: "Kestrel Laptop Pro"))
        expect(
            store.status.presentation(now: Date()).menuBarTitle == nil,
            "before any sample, a canvas session's title stays quiet"
        )

        store.recordPing(roundTripNanoseconds: 42_000_000, atSeconds: 0, from: connection)
        expect(
            store.status.presentation(now: Date()).menuBarTitle == "42ms",
            "a live ping gives a canvas session a title it never had before"
        )

        print("PASS: a canvas session shows no title until a ping arrives, then shows the ping the same as host screen does")
    }

    do {
        // While pairing (no live session), the code still shows -- a ping
        // that somehow arrived cannot displace it, and in practice none does,
        // since `recordPing` is only ever called for a live session.
        let store = HostOperatorStatusStore(permissions: granted)
        store.showPairingCode("123456", expiresAt: Date().addingTimeInterval(300))
        expect(
            store.status.presentation(now: Date()).menuBarTitle == "123 456",
            "pairing keeps showing the code when there is no ping to show instead"
        )

        print("PASS: pairing's own code is unaffected by a ping display that has nothing to show")
    }

    do {
        // A ping does not outlive the session it described: ending a live
        // session clears both the reading and its title.
        let store = HostOperatorStatusStore(permissions: granted)
        let connection = HostConnectionToken()
        store.setConnection(.servingHostScreen(peerName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        store.recordPing(roundTripNanoseconds: 8_000_000, atSeconds: 0, from: connection)
        expect(store.status.pingRoundTripNanoseconds == 8_000_000, "the reading is in force while the session is live")

        store.setConnection(.hosting(address: "100.64.0.1:4173"))
        expect(
            store.status.pingRoundTripNanoseconds == nil,
            "a session ending clears the reading rather than leaving a later one to inherit it"
        )
        expect(
            store.status.presentation(now: Date()).menuBarTitle == nil,
            "hosting with nobody connected shows no title at all"
        )

        // A later session starts clean rather than picking the old smoothing
        // window back up.
        store.setConnection(.serving(peerName: "A Different Machine"))
        expect(
            store.status.presentation(now: Date()).menuBarTitle == nil,
            "a new session shows no title until it reports its own first sample"
        )

        print("PASS: a session ending clears its ping reading, and a later session never inherits it")
    }

    do {
        // A ping that reaches `recordPing` after its own connection already
        // ended -- an unordered `Task` racing `setConnection` -- must not
        // resurrect a title for a session no longer on screen, even though
        // nothing has cleared this particular reading's own token yet.
        let store = HostOperatorStatusStore(permissions: granted)
        let connection = HostConnectionToken()
        store.setConnection(.servingHostScreen(peerName: "Kestrel Laptop Pro", displayLabel: "Built-in Display"))
        store.recordPing(roundTripNanoseconds: 8_000_000, atSeconds: 0, from: connection)
        store.setConnection(.hosting(address: "100.64.0.1:4173"))

        store.recordPing(roundTripNanoseconds: 9_000_000, atSeconds: 1, from: connection)
        expect(
            store.status.pingRoundTripNanoseconds == nil,
            "a ping that lands after its own session already ended is dropped, not shown"
        )
        expect(
            store.status.presentation(now: Date()).menuBarTitle == nil,
            "the title stays quiet -- nothing is live to show a round trip about"
        )

        print("PASS: a ping that arrives after its connection already ended never brings a phantom reading back")
    }

    do {
        // A ping naming a connection that is no longer the one serving --
        // replaced by a second connection while the first's ping was still
        // in flight -- is dropped, even though a session is live and would
        // otherwise have shown it.
        let store = HostOperatorStatusStore(permissions: granted)
        let first = HostConnectionToken()
        let second = HostConnectionToken()
        store.apply(.identified(deviceName: "Kestrel Laptop Pro"), from: first)
        store.apply(.identified(deviceName: "A Different Machine"), from: second)

        store.recordPing(roundTripNanoseconds: 8_000_000, atSeconds: 0, from: first)
        expect(
            store.status.pingRoundTripNanoseconds == nil,
            "a ping naming a connection that has been replaced is dropped, not attributed to whoever serves now"
        )

        store.recordPing(roundTripNanoseconds: 12_000_000, atSeconds: 0, from: second)
        expect(
            store.status.presentation(now: Date()).menuBarTitle == "12ms",
            "a ping naming the connection actually serving is shown as usual"
        )

        print("PASS: a ping naming a connection that has been replaced by another is dropped, never misattributed")
    }
}

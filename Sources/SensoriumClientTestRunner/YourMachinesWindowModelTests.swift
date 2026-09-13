import Foundation
import SensoriumClient
import SensoriumCore

private func savedMachineRow(
    _ name: String,
    key: UInt8,
    host: String,
    lastConnectedAt: Date? = nil
) -> SavedHost {
    SavedHost(
        displayName: name,
        host: host,
        port: 7777,
        hostPublicKey: Data([key]),
        tlsCertificateHash: Data([key, key]),
        lastConnectedAt: lastConnectedAt
    )
}

func testYourMachinesWindowModelTests() {
    let mini = savedMachineRow("Mac mini", key: 1, host: "mini.tail1234.ts.net", lastConnectedAt: Date(timeIntervalSince1970: 9_000))
    let studio = savedMachineRow("Mac Studio", key: 2, host: "100.64.1.7", lastConnectedAt: Date(timeIntervalSince1970: 1_000))

    do {
        // With nothing paired the list is one sentence, and adding a
        // machine is the only thing to do -- so it is the accent. With
        // machines saved it steps back to a secondary action.
        let empty = YourMachinesWindowModel(hosts: [])
        expect(empty.isEmpty, "no saved machines means the empty state")
        expect(
            YourMachinesWindowModel.emptySentence == "No machine is paired with this one yet.",
            "the empty state says what is empty in one plain sentence, got \(YourMachinesWindowModel.emptySentence)"
        )
        expect(empty.addIsPrimary, "with nothing paired, adding a machine is the accent")

        let listed = YourMachinesWindowModel(hosts: [mini, studio])
        expect(!listed.isEmpty, "a saved machine means a list")
        expect(!listed.addIsPrimary, "with machines listed, adding another is a secondary action")
        expect(
            listed.rows.map(\.name) == ["Mac mini", "Mac Studio"],
            "the rows are drawn in the order the store handed them over, got \(listed.rows.map(\.name))"
        )
        expect(
            YourMachinesWindowModel.heading == "Your Machines",
            "the heading is the window's own title, got \(YourMachinesWindowModel.heading)"
        )

        print("PASS: the launch window lists saved machines, or says plainly that none is paired")
    }

    do {
        // The line under each name is the address, and says online or
        // offline only where tailscale status actually answered for
        // that machine -- never a guess dressed as a fact. The dot beside
        // it follows the same restraint: none where nothing is known.
        let unknown = YourMachinesWindowModel(hosts: [mini])
        expect(
            unknown.rows[0].detail == "mini.tail1234.ts.net",
            "with nothing known, the line under the name is the address alone, got \(unknown.rows[0].detail)"
        )
        expect(unknown.rows[0].dot == nil, "and there is nothing to draw a dot for, got \(String(describing: unknown.rows[0].dot))")

        let peers = [
            TailnetPeer(
                id: "1", displayName: "Mac mini", magicDNSName: "mini.tail1234.ts.net",
                tailnetIPv4: "100.64.1.2", tailnetIPv6: nil, isOnline: true, isThisMachine: false
            ),
            TailnetPeer(
                id: "2", displayName: "Mac Studio", magicDNSName: "studio.tail1234.ts.net",
                tailnetIPv4: "100.64.1.7", tailnetIPv6: nil, isOnline: false, isThisMachine: false
            )
        ]
        let known = YourMachinesWindowModel(
            hosts: [mini, studio],
            reachability: SavedMachineReachability.byHostKey(hosts: [mini, studio], peers: peers)
        )
        expect(
            known.rows[0].detail == "mini.tail1234.ts.net \u{2014} online",
            "a machine matched by its MagicDNS name says online, got \(known.rows[0].detail)"
        )
        expect(known.rows[0].dot == .online, "and draws the online dot, got \(String(describing: known.rows[0].dot))")
        expect(
            known.rows[1].detail == "100.64.1.7 \u{2014} offline",
            "a machine matched by its tailnet address says offline, got \(known.rows[1].detail)"
        )
        expect(known.rows[1].dot == .offline, "and draws the offline dot, got \(String(describing: known.rows[1].dot))")

        let unlisted = savedMachineRow("Old machine", key: 3, host: "gone.tail1234.ts.net")
        expect(
            SavedMachineReachability.byHostKey(hosts: [unlisted], peers: peers).isEmpty,
            "a saved machine the tailnet never mentions is left unknown rather than called offline"
        )

        print("PASS: a row says online or offline only where the tailnet actually answered for that machine")
    }

    do {
        // One click connects. While that attempt is out the row says
        // so and offers Cancel; a failed attempt keeps the address and
        // appends the reason, and the next attempt goes back to saying
        // it is connecting. The attempt count keeps counting internally
        // even though the row no longer prints it.
        var model = YourMachinesWindowModel(hosts: [mini, studio])
        expect(model.connectingHostPublicKey == nil, "nothing is dialled until a row is clicked")
        expect(
            model.outcome(ofClickOn: mini.hostPublicKey) == .connect(hostPublicKey: mini.hostPublicKey),
            "clicking a row asks for a connection to that machine"
        )
        expect(!model.rows[0].offersCancel, "an idle row has nothing to cancel")

        model.connectStarted(hostPublicKey: mini.hostPublicKey)
        expect(model.connectingHostPublicKey == mini.hostPublicKey, "the clicked row is the connecting one")
        expect(
            model.rows[0].detail == "mini.tail1234.ts.net \u{2014} connecting\u{2026}",
            "the row keeps its address and says so, got \(model.rows[0].detail)"
        )
        expect(model.rows[0].dot == .activity, "a connecting row shows the pulsing dot")
        expect(model.rows[0].offersCancel, "a connecting row offers Cancel")
        expect(model.rows[1].detail == "100.64.1.7", "every other row is unchanged, got \(model.rows[1].detail)")
        expect(model.rows[1].dot != .activity, "an idle row shows no pulsing dot")

        model.attemptFailed(reason: "no answer")
        expect(
            model.rows[0].detail == "mini.tail1234.ts.net \u{2014} no answer",
            "a failed attempt keeps the address and appends the reason, got \(model.rows[0].detail)"
        )
        expect(
            model.rows[0].activity == .failed(attempt: 1, reason: "no answer"),
            "the attempt number is still tracked, even though the row no longer prints it, got \(model.rows[0].activity)"
        )
        expect(model.rows[0].dot == nil, "a failed attempt's own line already says everything, so it draws no dot")
        expect(model.rows[0].offersCancel, "a failed attempt is still being retried, so Cancel stays")

        model.connectStarted(hostPublicKey: mini.hostPublicKey)
        expect(
            model.rows[0].detail == "mini.tail1234.ts.net \u{2014} connecting\u{2026}",
            "the next attempt says it is connecting again, got \(model.rows[0].detail)"
        )
        model.attemptFailed(reason: "no answer")
        expect(
            model.rows[0].activity == .failed(attempt: 2, reason: "no answer"),
            "the attempt count carries across attempts, got \(model.rows[0].activity)"
        )

        model.stoppedConnecting()
        expect(model.connectingHostPublicKey == nil, "cancelling leaves nothing dialling")
        expect(
            model.rows[0].detail == "mini.tail1234.ts.net",
            "a cancelled row goes back to its address, got \(model.rows[0].detail)"
        )

        print("PASS: a connecting row reports each attempt in place of its address, and cancels back to it")
    }

    do {
        // Every other row stays live while one is dialling: clicking
        // one cancels the attempt already out rather than starting a
        // second one beside it. Clicking the row already dialling is
        // not a second connect.
        var model = YourMachinesWindowModel(hosts: [mini, studio])
        model.connectStarted(hostPublicKey: mini.hostPublicKey)
        expect(
            model.outcome(ofClickOn: studio.hostPublicKey)
                == .cancelThenConnect(cancelling: mini.hostPublicKey, connecting: studio.hostPublicKey),
            "clicking another machine cancels the attempt already out and dials that one instead"
        )
        expect(
            model.outcome(ofClickOn: mini.hostPublicKey) == .ignore,
            "clicking the row that is already dialling does nothing; its own Cancel is how it stops"
        )

        print("PASS: clicking another machine while one is dialling cancels that attempt instead of stacking a second")
    }

    do {
        // Re-reading the saved machines -- after one is forgotten, or
        // after tailscale status finally answers -- must not reset
        // the attempt already out: the row that was dialling keeps
        // saying so, and keeps its attempt count.
        var model = YourMachinesWindowModel(hosts: [mini, studio])
        model.connectStarted(hostPublicKey: mini.hostPublicKey)
        model.attemptFailed(reason: "no answer")

        model.replaceHosts([mini, studio], reachability: [mini.hostPublicKey: true])
        expect(model.connectingHostPublicKey == mini.hostPublicKey, "the machine being dialled is still the one dialling")
        expect(
            model.rows[0].detail == "mini.tail1234.ts.net \u{2014} no answer",
            "the attempt already out survives a re-read, got \(model.rows[0].detail)"
        )
        expect(
            model.rows[0].activity == .failed(attempt: 1, reason: "no answer"),
            "and its attempt number survives with it, got \(model.rows[0].activity)"
        )
        model.connectStarted(hostPublicKey: mini.hostPublicKey)
        model.attemptFailed(reason: "no answer")
        expect(
            model.rows[0].activity == .failed(attempt: 2, reason: "no answer"),
            "and so does its attempt count, got \(model.rows[0].activity)"
        )

        // Forgetting the machine that was dialling leaves nothing dialling: the
        // row it was reported on does not exist any more.
        model.replaceHosts([studio], reachability: [:])
        expect(model.connectingHostPublicKey == nil, "forgetting the machine being dialled leaves nothing dialling")
        expect(model.rows.map(\.name) == ["Mac Studio"], "and the list is what the store now holds")

        print("PASS: re-reading the saved machines keeps the attempt already out, and drops it with its own row")
    }

    do {
        // When the retry loop gives up, the row must keep saying why
        // -- losing the reason at the moment the waiting stops is
        // exactly when it is most needed -- while becoming clickable
        // again, since clicking it is now the way to try again.
        var model = YourMachinesWindowModel(hosts: [mini, studio])
        model.connectStarted(hostPublicKey: mini.hostPublicKey)
        model.attemptFailed(reason: "no answer")
        model.stoppedTrying()
        expect(
            model.rows[0].detail == "mini.tail1234.ts.net \u{2014} no answer",
            "giving up keeps the reason on the row, got \(model.rows[0].detail)"
        )
        expect(!model.rows[0].offersCancel, "there is nothing left to cancel once the retries have stopped")
        expect(model.connectingHostPublicKey == nil, "and nothing is dialling")
        expect(
            model.outcome(ofClickOn: mini.hostPublicKey) == .connect(hostPublicKey: mini.hostPublicKey),
            "so clicking that machine again is how it is tried again"
        )

        model.connectStarted(hostPublicKey: mini.hostPublicKey)
        expect(
            model.rows[0].detail == "mini.tail1234.ts.net \u{2014} connecting\u{2026}",
            "and that attempt starts counting again, got \(model.rows[0].detail)"
        )

        // A run stopped before any attempt reported a reason has nothing to
        // keep, so the row goes back to saying where that machine is.
        model.stoppedTrying()
        expect(
            model.rows[0].detail == "mini.tail1234.ts.net",
            "a run that stopped with nothing to report leaves the address, got \(model.rows[0].detail)"
        )

        print("PASS: a run that gave up leaves the reason on its row and makes it clickable again")
    }

    do {
        // A click says Connecting straight away, before any socket
        // exists. Every attempt the retry loop then makes advances the
        // count the model tracks internally, even though the row's
        // own line never prints it.
        var model = YourMachinesWindowModel(hosts: [mini, studio])
        model.connectRequested(hostPublicKey: mini.hostPublicKey)
        expect(model.connectingHostPublicKey == mini.hostPublicKey, "the clicked row is the connecting one at once")
        expect(
            model.rows[0].detail == "mini.tail1234.ts.net \u{2014} connecting\u{2026}",
            "and says so before the first attempt has begun, got \(model.rows[0].detail)"
        )
        expect(model.rows[0].offersCancel, "a row with a click behind it can be cancelled")

        model.connectStarted(hostPublicKey: mini.hostPublicKey)
        model.attemptFailed(reason: "no answer")
        expect(
            model.rows[0].activity == .failed(attempt: 1, reason: "no answer"),
            "the first attempt is the first, got \(model.rows[0].activity)"
        )
        model.connectStarted(hostPublicKey: mini.hostPublicKey)
        model.attemptFailed(reason: "no answer")
        model.connectStarted(hostPublicKey: mini.hostPublicKey)
        model.attemptFailed(reason: "no answer")
        expect(
            model.rows[0].activity == .failed(attempt: 3, reason: "no answer"),
            "and each attempt after it advances the count, got \(model.rows[0].activity)"
        )

        print("PASS: a click says Connecting at once, and every attempt after it advances the row's count")
    }

    do {
        // Cancelling cannot always end an attempt the instant it is
        // asked for -- a handshake already out has to finish -- so
        // the row says what it is doing rather than going quiet or
        // claiming to be connecting still.
        var model = YourMachinesWindowModel(hosts: [mini, studio])
        model.connectRequested(hostPublicKey: mini.hostPublicKey)
        model.connectStarted(hostPublicKey: mini.hostPublicKey)
        model.stopping()
        expect(
            model.rows[0].detail == "mini.tail1234.ts.net \u{2014} stopping\u{2026}",
            "a row being stopped keeps its address and says so, got \(model.rows[0].detail)"
        )
        expect(model.rows[0].dot == .activity, "a stopping row shows the pulsing dot")
        expect(!model.rows[0].offersCancel, "there is nothing left to ask for: it is already stopping")
        expect(
            model.connectingHostPublicKey == mini.hostPublicKey,
            "and the attempt is still this row's until it actually ends"
        )

        model.stoppedConnecting()
        expect(
            model.rows[0].detail == "mini.tail1234.ts.net",
            "when it ends the row goes back to where that machine is, got \(model.rows[0].detail)"
        )
        expect(model.connectingHostPublicKey == nil, "and nothing is dialling")

        print("PASS: a cancelled attempt says it is stopping until it has actually stopped")
    }
}

import Foundation
import SensoriumClient
import SensoriumCore

private func savedMachine(
    _ name: String,
    key: UInt8,
    lastConnectedAt: Date? = nil
) -> SavedHost {
    SavedHost(
        displayName: name,
        host: "\(name.lowercased()).tail1234.ts.net",
        port: 7777,
        hostPublicKey: Data([key]),
        tlsCertificateHash: Data([key, key]),
        lastConnectedAt: lastConnectedAt
    )
}

func testSavedMachinesStoreTests() {
    do {
        // The store holds a list, not one machine: saving a second one
        // keeps the first, and saving the same key again replaces
        // that entry in place rather than adding a duplicate.
        let store = InMemorySavedHostStore()
        expect(store.loadAll().isEmpty, "a fresh machine has no saved machines at all")

        let mini = savedMachine("Mini", key: 1)
        let studio = savedMachine("Studio", key: 2)
        store.save(mini)
        store.save(studio)
        expect(
            store.loadAll().map(\.displayName).sorted() == ["Mini", "Studio"],
            "saving a second machine keeps the first, got \(store.loadAll().map(\.displayName))"
        )

        let renamedMini = SavedHost(
            displayName: "The Mini",
            host: mini.host,
            port: mini.port,
            hostPublicKey: mini.hostPublicKey,
            tlsCertificateHash: mini.tlsCertificateHash
        )
        store.save(renamedMini)
        expect(store.loadAll().count == 2, "saving the same key again replaces it instead of adding a second row")
        expect(
            store.load(hostPublicKey: mini.hostPublicKey)?.displayName == "The Mini",
            "the replacement is what a later read finds"
        )

        store.remove(hostPublicKey: mini.hostPublicKey)
        expect(
            store.loadAll().map(\.displayName) == ["Studio"],
            "forgetting one machine leaves every other one, got \(store.loadAll().map(\.displayName))"
        )
        expect(store.load(hostPublicKey: mini.hostPublicKey) == nil, "a forgotten machine is gone")

        store.clear()
        expect(store.loadAll().isEmpty, "clearing forgets every saved machine")

        print("PASS: the saved-machines store upserts by pinned key and forgets one machine at a time")
    }

    do {
        // Most recently connected first, so the machine a person is most
        // likely to want is the one their pointer is already near. A
        // machine paired but never connected has no date to sort on and
        // keeps the order it was saved in, below every machine that has.
        let old = savedMachine("Old", key: 1, lastConnectedAt: Date(timeIntervalSince1970: 1_000))
        let recent = savedMachine("Recent", key: 2, lastConnectedAt: Date(timeIntervalSince1970: 9_000))
        let neverA = savedMachine("NeverA", key: 3)
        let neverB = savedMachine("NeverB", key: 4)

        expect(
            SavedHostList.presentationOrder([old, neverA, recent, neverB]).map(\.displayName)
                == ["Recent", "Old", "NeverA", "NeverB"],
            "most recently connected first, never-connected last in saved order, got "
                + "\(SavedHostList.presentationOrder([old, neverA, recent, neverB]).map(\.displayName))"
        )

        let store = InMemorySavedHostStore()
        for host in [old, neverA, recent, neverB] {
            store.save(host)
        }
        expect(
            store.loadAll().map(\.displayName) == ["Recent", "Old", "NeverA", "NeverB"],
            "the store hands its list back already in the order the window draws it, got "
                + "\(store.loadAll().map(\.displayName))"
        )

        print("PASS: saved machines are listed most recently connected first")
    }

    do {
        // A save file holding just one machine, with no list wrapper
        // around its JSON object, must still load. Reading it as nothing
        // at all would silently discard a pinned key and a TLS hash and
        // ask for a pairing code that is not needed, so it is read as a
        // one-element list instead.
        let legacy = savedMachine("Mini", key: 7)
        let singleObject = try! JSONEncoder().encode(legacy)
        let migrated = SavedHostFileCoding.decode(singleObject)
        expect(migrated == [legacy], "a single saved host reads as a one-element list, got \(migrated)")
        expect(
            migrated.first?.hostPublicKey == legacy.hostPublicKey
                && migrated.first?.tlsCertificateHash == legacy.tlsCertificateHash,
            "the pinned key and the TLS hash carry over unchanged"
        )

        let array = SavedHostFileCoding.encode([legacy, savedMachine("Studio", key: 8)])!
        expect(
            SavedHostFileCoding.decode(array).map(\.displayName) == ["Mini", "Studio"],
            "the list shape round-trips"
        )
        expect(
            SavedHostFileCoding.decode(Data("not json at all".utf8)).isEmpty,
            "a file that is neither shape reads as no saved machines rather than crashing"
        )

        print("PASS: a saved-host file written before this machine held a list migrates without losing a pin")
    }

    do {
        // A session that goes live is what makes a machine the most
        // recent one; nothing else moves it up the list.
        let connected = savedMachine("Mini", key: 1).connected(at: Date(timeIntervalSince1970: 4_000), liveTarget: .virtualDisplay)
        expect(
            connected.lastConnectedAt == Date(timeIntervalSince1970: 4_000),
            "the connect time is recorded on the saved machine"
        )
        expect(
            connected.hostPublicKey == Data([1]) && connected.displayName == "Mini",
            "recording it changes nothing else about the saved machine"
        )

        print("PASS: a live session stamps the saved machine with when it last connected")
    }

    do {
        // The stamp is written against whatever the store holds now, not
        // against the copy the session started from: writing against that
        // stale copy would undo a resolution the person chose while a
        // session that drops and reconnects was running.
        let store = InMemorySavedHostStore(hosts: [savedMachine("Mini", key: 1)])
        let atSessionStart = store.load(hostPublicKey: Data([1]))
        expect(atSessionStart?.streamScalePreference == .automatic, "the session starts on the saved preference")

        // What the Display menu writes mid-session, through the same store.
        store.save(SavedHost(
            displayName: "Mini",
            host: "mini.tail1234.ts.net",
            port: 7777,
            hostPublicKey: Data([1]),
            tlsCertificateHash: Data([1, 1]),
            streamScalePreference: .fixed(1.5)
        ))

        store.stampConnected(
            hostPublicKey: Data([1]), at: Date(timeIntervalSince1970: 7_000), liveTarget: .virtualDisplay
        )
        let stamped = store.load(hostPublicKey: Data([1]))
        expect(
            stamped?.lastConnectedAt == Date(timeIntervalSince1970: 7_000),
            "the reconnect records when it connected"
        )
        expect(
            stamped?.streamScalePreference == .fixed(1.5),
            "and keeps the resolution chosen while the session was up, got \(String(describing: stamped?.streamScalePreference))"
        )

        store.stampConnected(
            hostPublicKey: Data([9]), at: Date(timeIntervalSince1970: 7_000), liveTarget: .virtualDisplay
        )
        expect(store.loadAll().count == 1, "stamping a machine this one no longer holds saves nothing")

        print("PASS: recording a connection reads the stored machine first, so nothing written during the session is lost")
    }

    do {
        // A saved machine names the host this viewer trusts and the
        // certificate hash it pins. Another account able to read or rewrite
        // that file could point a later session at a machine of its own, so
        // it is written exactly as owner-only as the device key beside it.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sensorium-saved-host-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("saved-host.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        FileSavedHostStore(url: url).save(savedMachine("Studio", key: 1))

        let fileMode = (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)??.intValue
        expect(
            fileMode == 0o600,
            "the saved machines file is readable by its owner alone, got \(String(describing: fileMode))"
        )
        let directoryMode = (try? FileManager.default.attributesOfItem(
            atPath: directory.path
        )[.posixPermissions] as? NSNumber)??.intValue
        expect(
            directoryMode == 0o700,
            "and sits in a directory no other account can list, got \(String(describing: directoryMode))"
        )
        expect(
            FileSavedHostStore(url: url).loadAll().count == 1,
            "and reads back through the same store"
        )
        print("PASS: the saved machines file is written owner-only, like the device key beside it")
    }

    do {
        // Picking a resolution from the Display menu says nothing about where
        // this machine should start, what it last streamed, or which host
        // screens it was offered, so none of the three may be dropped on the
        // way through.
        let store = InMemorySavedHostStore()
        store.save(SavedHost(
            displayName: "Studio",
            host: "studio.tail1234.ts.net",
            port: 7777,
            hostPublicKey: Data([4]),
            tlsCertificateHash: Data([4, 4]),
            streamScalePreference: .automatic,
            lastConnectedAt: Date(timeIntervalSince1970: 1_000),
            startTargetPreference: .virtualDisplay,
            lastLiveTarget: .hostScreen(displayIdentity: "screen-a", label: "Studio Display"),
            rememberedHostScreenOffer: [
                RememberedHostScreen(displayIdentity: "screen-a", label: "Studio Display")
            ]
        ))

        store.setStreamScalePreference(hostPublicKey: Data([4]), to: .fixed(1.5))

        guard let stored = store.load(hostPublicKey: Data([4])) else {
            expect(false, "the machine survives a stream-scale change")
            return
        }
        expect(stored.streamScalePreference == .fixed(1.5), "the chosen scale is what the store now holds")
        expect(stored.startTargetPreference == .virtualDisplay, "and the saved Start with preference is untouched")
        expect(
            stored.lastLiveTarget == .hostScreen(displayIdentity: "screen-a", label: "Studio Display"),
            "and the last live target is untouched"
        )
        expect(
            stored.rememberedHostScreenOffer == [
                RememberedHostScreen(displayIdentity: "screen-a", label: "Studio Display")
            ],
            "and the remembered host-screen offer is untouched"
        )
        expect(stored.lastConnectedAt == Date(timeIntervalSince1970: 1_000), "and so is when it last connected")

        store.setStreamScalePreference(hostPublicKey: Data([44]), to: .fixed(2))
        expect(store.loadAll().count == 1, "a machine this one no longer holds saves nothing")

        print("PASS: choosing a stream scale keeps the Start with preference, the last live target and the remembered offer")
    }
}

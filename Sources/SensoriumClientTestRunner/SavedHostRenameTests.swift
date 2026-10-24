import Foundation
import SensoriumClient
import SensoriumCore

private func machine(_ name: String, key: UInt8 = 1, host: String = "mini.tail1234.ts.net") -> SavedHost {
    SavedHost(
        displayName: name,
        host: host,
        port: 7777,
        hostPublicKey: Data([key]),
        tlsCertificateHash: Data([key, key])
    )
}

func testSavedHostRenameTests() {
    do {
        let renamed = machine("100.64.1.7", host: "100.64.1.7").withCustomName("  Studio  ")
        expect(renamed.displayName == "Studio", "a renamed machine shows the trimmed name, got \(renamed.displayName)")
        expect(renamed.pairedName == "100.64.1.7", "the name pairing gave it is kept underneath, got \(renamed.pairedName)")
        expect(renamed.host == "100.64.1.7", "renaming never changes the address a session dials")
        expect(renamed.hostPublicKey == Data([1]), "renaming never changes the pinned key")
        print("PASS: renaming shows the trimmed name and leaves the address and key alone")
    }

    do {
        let renamed = machine("Loft").withCustomName("Studio")
        for blank in ["", "   ", "\n\t "] {
            let cleared = renamed.withCustomName(blank)
            expect(cleared.customName == nil, "a blank name (\(blank.debugDescription)) clears the custom name")
            expect(cleared.displayName == "Loft", "and the machine goes back to the name pairing gave it, got \(cleared.displayName)")
        }
        expect(renamed.withCustomName(nil).displayName == "Loft", "nil goes back to the default name too")
        print("PASS: an empty name puts the default name back")
    }

    do {
        let long = String(repeating: "a", count: 80)
        let renamed = machine("Loft").withCustomName(long)
        expect(SavedHostName.maximumLength == 64, "a name is capped at 64 characters")
        expect(renamed.displayName.count == 64, "an over-long name is cut to 64, got \(renamed.displayName.count)")
        let padded = machine("Loft").withCustomName(String(repeating: " ", count: 10) + long)
        expect(padded.displayName == String(repeating: "a", count: 64), "trimming happens before the cap")
        print("PASS: a name is capped at 64 characters")
    }

    do {
        let renamed = machine("Loft").withCustomName("Studio")
        let when = Date(timeIntervalSince1970: 5_000)
        let results: [(String, SavedHost)] = [
            ("connected(at:liveTarget:)", renamed.connected(at: when, liveTarget: .hostScreenWhenOffered)),
            ("withStartTargetPreference", renamed.withStartTargetPreference(.virtualDisplay)),
            ("withStreamScalePreference", renamed.withStreamScalePreference(.automatic)),
            ("withRememberedHostScreenOffer", renamed.withRememberedHostScreenOffer([]))
        ]
        for (name, result) in results {
            expect(result.customName == "Studio" && result.displayName == "Studio", "\(name) keeps a custom name")
            expect(result.pairedName == "Loft", "\(name) keeps the default name beneath it")
        }
        print("PASS: every update that rewrites a saved machine keeps its custom name")
    }

    do {
        let store = InMemorySavedHostStore(hosts: [machine("Loft")])
        store.rename(hostPublicKey: Data([1]), to: " Studio ")
        expect(store.loadAll().first?.displayName == "Studio", "the store records the rename")
        store.stampConnected(hostPublicKey: Data([1]), at: Date(timeIntervalSince1970: 9), liveTarget: .hostScreenWhenOffered)
        store.setStreamScalePreference(hostPublicKey: Data([1]), to: .automatic)
        store.setStartTargetPreference(hostPublicKey: Data([1]), to: .virtualDisplay)
        store.rememberHostScreenOffer(hostPublicKey: Data([1]), offer: [])
        expect(
            store.loadAll().first?.displayName == "Studio",
            "reconnect bookkeeping afterwards keeps the name, got \(store.loadAll().first?.displayName ?? "none")"
        )
        store.rename(hostPublicKey: Data([9]), to: "Nobody")
        expect(store.loadAll().count == 1, "renaming a machine that is not saved writes nothing")
        store.rename(hostPublicKey: Data([1]), to: "")
        expect(store.loadAll().first?.displayName == "Loft", "an empty rename through the store restores the default")
        print("PASS: the store renames one machine and later bookkeeping keeps the name")
    }

    do {
        let old = machine("Loft").withCustomName("Studio")
        let repaired = SavedHost(
            displayName: "Studio",
            host: "mini.tail1234.ts.net",
            port: 7777,
            hostPublicKey: Data([2]),
            tlsCertificateHash: Data([2, 2])
        )
        let merged = repaired.carryingName(from: old)
        expect(merged.displayName == "Studio", "pairing again keeps the custom name, got \(merged.displayName)")
        expect(merged.pairedName == "Loft", "and the default name is the one pairing first gave, not the custom name")
        expect(merged.hostPublicKey == Data([2]), "while the new key is the one pinned")

        let typed = SavedHost(
            displayName: "Attic", host: "mini.tail1234.ts.net", port: 7777, hostPublicKey: Data([2])
        )
        expect(typed.carryingName(from: old).pairedName == "Attic", "a name typed during pairing becomes the new default")
        expect(typed.carryingName(from: old).displayName == "Studio", "while the custom name still wins")

        let plain = repaired.carryingName(from: machine("Loft"))
        expect(plain.customName == nil, "a machine never renamed gains no custom name")
        expect(repaired.carryingName(from: nil) == repaired, "a first pairing is left as it was")
        print("PASS: pairing a machine again keeps its custom name")
    }

    do {
        let legacy = Data("""
        {"displayName":"Loft","host":"mini.tail1234.ts.net","port":7777,"hostPublicKey":"AQ=="}
        """.utf8)
        let decoded = SavedHostFileCoding.decode(legacy)
        expect(decoded.count == 1, "a file written before custom names still decodes")
        expect(decoded.first?.customName == nil, "with no custom name")
        expect(decoded.first?.displayName == "Loft", "and the same name it always showed")

        let renamed = machine("Loft").withCustomName("Studio")
        let roundTrip = SavedHostFileCoding.encode([renamed]).map(SavedHostFileCoding.decode)
        expect(roundTrip == [renamed], "a custom name survives the file")
        let plain = SavedHostFileCoding.encode([machine("Loft")]).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        expect(!plain.contains("customName"), "a machine never renamed writes no custom name")
        expect(plain.contains("\"displayName\":\"Loft\""), "and still writes the default name under its old key")
        print("PASS: older saved-machine files decode unchanged and a custom name round-trips")
    }

    do {
        let renamed = [machine("100.64.1.7", host: "100.64.1.7").withCustomName("Studio")]
        let peers = [TailnetPeer(
            id: "1", displayName: "Studio", magicDNSName: "other.tail1234.ts.net",
            tailnetIPv4: "100.64.1.9", tailnetIPv6: nil, isOnline: true, isThisMachine: false
        ), TailnetPeer(
            id: "2", displayName: "mini", magicDNSName: "mini.tail1234.ts.net",
            tailnetIPv4: "100.64.1.7", tailnetIPv6: nil, isOnline: false, isThisMachine: false
        )]
        let reach = SavedMachineReachability.byHostKey(hosts: renamed, peers: peers)
        expect(reach == [Data([1]): false], "a renamed machine is still matched by its address, never by its shown name, got \(reach)")
        print("PASS: a rename cannot change which tailnet peer a saved machine matches")
    }

    do {
        let model = YourMachinesWindowModel(hosts: [machine("Loft").withCustomName("Studio")])
        expect(model.rows.first?.name == "Studio", "the row shows the custom name")
        expect(
            model.rows.first?.detail == "mini.tail1234.ts.net \u{2014}\u{00A0}status unknown",
            "and the line under it still shows the address"
        )
        expect(YourMachinesWindowModel.renameTitle == "Rename\u{2026}", "the menu item is Rename\u{2026}")
        expect(YourMachinesWindowModel.renameConfirmTitle == "Rename", "the confirm button is Rename")
        print("PASS: the row shows the custom name over the address")
    }

    do {
        let renamed = machine("Loft").withCustomName("Studio\u{202E}\n\u{200B}Mac")
        expect(renamed.displayName == "Studio Mac", "a typed viewer-side name is cleaned the same way, got \(renamed.displayName)")
        expect(SavedHostName.maximumLength == DeviceName.maximumLength, "the viewer shares the one cap")
        let saved = try! JSONEncoder().encode(machine("Loft"))
        var object = try! JSONSerialization.jsonObject(with: saved) as! [String: Any]
        object["customName"] = "Studio\u{2066}\tMac"
        let hostile = try! JSONSerialization.data(withJSONObject: object)
        let decoded = try! JSONDecoder().decode(SavedHost.self, from: hostile)
        expect(decoded.displayName == "Studio Mac", "a hostile name already saved is cleaned on read, got \(decoded.displayName)")
        print("PASS: a viewer-side name goes through the shared name rule, on write and on read")
    }
}

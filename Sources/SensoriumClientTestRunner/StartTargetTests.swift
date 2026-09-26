import Foundation
import SensoriumClient
import SensoriumCore

/// A per-machine "Start with" preference: what it decodes to when a saved
/// machine predates the field, how it resolves against history, what the
/// Screen menu's own submenu offers for it, and the one explicit way out of
/// a failed preference-driven first connect. None of it needs a socket or a
/// window.
private func savedMachine(
    _ name: String,
    key: UInt8,
    startTargetPreference: StartTarget = .hostScreenWhenOffered,
    lastLiveTarget: StartTarget? = nil,
    rememberedHostScreenOffer: [RememberedHostScreen] = []
) -> SavedHost {
    SavedHost(
        displayName: name,
        host: "\(name.lowercased()).tail1234.ts.net",
        port: 7777,
        hostPublicKey: Data([key]),
        tlsCertificateHash: Data([key, key]),
        startTargetPreference: startTargetPreference,
        lastLiveTarget: lastLiveTarget,
        rememberedHostScreenOffer: rememberedHostScreenOffer
    )
}

private let office = HostScreenListEntry(
    opaqueToken: Data([9, 9]),
    label: "Office",
    logicalWidth: 1920,
    logicalHeight: 1080,
    backingScale: 2,
    isBuiltin: false,
    displayIdentity: "office-display-id"
)

private let lounge = HostScreenListEntry(
    opaqueToken: Data([8, 8]),
    label: "Lounge",
    logicalWidth: 3008,
    logicalHeight: 1692,
    backingScale: 2,
    isBuiltin: true,
    displayIdentity: "lounge-display-id"
)

func testStartTargetTests() {
    do {
        // A saved machine from before this field existed starts on
        // "last used", not any target this build invented for it.
        let legacyJSON = """
        {"displayName":"Mini","host":"mini.tail1234.ts.net","port":7777,\
        "hostPublicKey":"AQ==","streamScalePreference":{"kind":"automatic"}}
        """
        let decoded = try! JSONDecoder().decode(SavedHost.self, from: Data(legacyJSON.utf8))
        expect(
            decoded.startTargetPreference == .hostScreenWhenOffered,
            "a host with no key for it decodes as the unchanged default"
        )
        expect(decoded.lastLiveTarget == nil, "and remembers no history it never had")
        expect(decoded.rememberedHostScreenOffer.isEmpty, "and no offer it was never sent")
        print("PASS: a saved machine from before this preference existed decodes as \u{2018}host screen when offered\u{2019} with no history")
    }

    do {
        // Every shape round-trips through JSON unchanged
        for target: StartTarget in [
            .hostScreenWhenOffered, .virtualDisplay, .hostScreen(displayIdentity: "office-display-id", label: "Office")
        ] {
            let data = try! JSONEncoder().encode(target)
            let decoded = try! JSONDecoder().decode(StartTarget.self, from: data)
            expect(decoded == target, "\(target) round-trips through JSON, got \(decoded)")
        }
        let machine = savedMachine(
            "Mini", key: 1,
            startTargetPreference: .hostScreen(displayIdentity: "office-display-id", label: "Office"),
            lastLiveTarget: .hostScreen(displayIdentity: "office-display-id", label: "Office")
        )
        let data = try! JSONEncoder().encode(machine)
        let decoded = try! JSONDecoder().decode(SavedHost.self, from: data)
        expect(decoded == machine, "a saved machine with both fields set round-trips through JSON unchanged")
        print("PASS: every StartTarget shape, and a saved machine carrying one, round-trips through JSON")
    }

    do {
        // The resolver: a pinned preference always wins and never looks at
        // history. The default, `.hostScreenWhenOffered`, always starts on a
        // host screen from the host's fresh offer, preferring the one this
        // machine last went live on.
        expect(
            StartTargetResolution.resolve(preference: .hostScreenWhenOffered, lastTarget: nil)
                == .offeredHostScreen(preferredDisplayIdentity: nil),
            "no history starts on the first screen the host offers, never a session canvas"
        )
        expect(
            StartTargetResolution.resolve(preference: .hostScreenWhenOffered, lastTarget: .virtualDisplay)
                == .offeredHostScreen(preferredDisplayIdentity: nil),
            "a machine that last went live on a canvas resolves as if nothing were remembered"
        )
        expect(
            StartTargetResolution.resolve(
                preference: .hostScreenWhenOffered,
                lastTarget: .hostScreen(displayIdentity: "office-display-id", label: "Office")
            ) == .offeredHostScreen(preferredDisplayIdentity: "office-display-id"),
            "a machine that last went live on a host screen prefers that screen in the fresh offer"
        )
        expect(
            StartTargetResolution.resolve(
                preference: .virtualDisplay,
                lastTarget: .hostScreen(displayIdentity: "office-display-id", label: "Office")
            ) == .sessionCanvas,
            "a pinned \u{2018}virtual display\u{2019} preference ignores history entirely"
        )
        expect(
            StartTargetResolution.resolve(
                preference: .hostScreen(displayIdentity: "lounge-display-id", label: "Lounge"), lastTarget: .virtualDisplay
            ) == .hostScreen(displayIdentity: "lounge-display-id"),
            "and a pinned host-screen preference ignores history the same way"
        )
        print("PASS: the start-target resolver honours a pinned preference and otherwise starts on an offered host screen")
    }

    do {
        // The Screen menu's "Start with" submenu: always Host screen when
        // offered and Virtual display, then one row per host screen most
        // recently offered, checking whichever is saved.
        let menu = ScreenMenuPlan.startWithMenu(
            preference: .hostScreen(displayIdentity: "lounge-display-id", label: "Lounge"),
            offeredHostScreens: [office, lounge],
            isHostScreenSessionLive: false
        )
        expect(menu.title == "Start With", "the submenu is named what a person is choosing")
        expect(
            menu.items.map(\.title) == ["Host Screen When Offered", "Virtual Display", "Office", "Lounge"],
            "the two fixed rows come first, then every offered screen by its own label -- got \(menu.items.map(\.title))"
        )
        expect(
            menu.items.map(\.isSelected) == [false, false, false, true],
            "the row naming the saved preference's own screen is the one checked"
        )
        expect(menu.items.allSatisfy(\.isEnabled), "every row can be picked while no host screen is live")
        print("PASS: the Screen menu's \u{2018}Start with’ submenu lists both fixed rows and every offered screen, checking the saved one")
    }

    do {
        // Disabled, like Displays, while a host screen is live:
        // there is nothing a pick here could do about it.
        let menu = ScreenMenuPlan.startWithMenu(
            preference: .hostScreenWhenOffered, offeredHostScreens: [office], isHostScreenSessionLive: true
        )
        expect(!menu.items.contains { $0.isEnabled }, "every row is disabled while a host screen is live")
        expect(
            menu.items.map(\.title) == ["Host Screen When Offered", "Virtual Display", "Office"],
            "but the rows themselves are unchanged"
        )
        expect(menu.items[0].isSelected, "the default is the row checked when it is the saved preference")
        print("PASS: the \u{2018}Start with’ submenu disables every row while a host screen is live, the same rule Displays follows")
    }

    do {
        // A machine going live stamps what it actually reached,
        // which is what a \u{2018}last used\u{2019} preference will fall
        // back to next time -- and nothing else about the record.
        let stamped = savedMachine("Mini", key: 1).connected(
            at: Date(timeIntervalSince1970: 4_000),
            liveTarget: .hostScreen(displayIdentity: "office-display-id", label: "Office")
        )
        expect(
            stamped.lastLiveTarget == .hostScreen(displayIdentity: "office-display-id", label: "Office"),
            "the target that actually went live is what is remembered"
        )
        expect(
            stamped.startTargetPreference == .hostScreenWhenOffered, "recording it never changes the saved preference itself"
        )

        let store = InMemorySavedHostStore(hosts: [savedMachine("Mini", key: 1)])
        store.stampConnected(
            hostPublicKey: Data([1]), at: Date(timeIntervalSince1970: 7_000), liveTarget: .virtualDisplay
        )
        expect(
            store.load(hostPublicKey: Data([1]))?.lastLiveTarget == .virtualDisplay,
            "the store's own stamp records the live target the same way"
        )

        store.setStartTargetPreference(
            hostPublicKey: Data([1]), to: .hostScreen(displayIdentity: "lounge-display-id", label: "Lounge")
        )
        let afterPick = store.load(hostPublicKey: Data([1]))
        expect(
            afterPick?.startTargetPreference == .hostScreen(displayIdentity: "lounge-display-id", label: "Lounge"),
            "the \u{2018}Start with’ submenu's own pick writes the preference back"
        )
        expect(afterPick?.lastLiveTarget == .virtualDisplay, "and leaves the live-target history exactly as it was")

        store.rememberHostScreenOffer(
            hostPublicKey: Data([1]),
            offer: [RememberedHostScreen(displayIdentity: "office-display-id", label: "Office")]
        )
        let afterOffer = store.load(hostPublicKey: Data([1]))
        expect(
            afterOffer?.rememberedHostScreenOffer == [RememberedHostScreen(displayIdentity: "office-display-id", label: "Office")],
            "a canvas connect's own offer is remembered independently of either"
        )
        expect(afterOffer?.startTargetPreference == afterPick?.startTargetPreference, "and changes neither the preference")
        expect(afterOffer?.lastLiveTarget == .virtualDisplay, "nor the live-target history")
        print("PASS: a session going live stamps what it reached, a \u{2018}Start with’ pick writes the preference back, and a fresh offer is remembered, independently of one another")
    }

    do {
        // The launch row's own way out of a failed preference-driven
        // first connect: offered only while the row names one, and
        // cleared the moment a fresh attempt starts.
        var model = YourMachinesWindowModel(hosts: [savedMachine("Mini", key: 1)])
        model.connectStarted(hostPublicKey: Data([1]))
        expect(
            !model.rows[0].offersConnectAsVirtualDisplayFallback,
            "an attempt still out offers no fallback yet"
        )
        model.attemptFailed(reason: "refused", offersConnectAsVirtualDisplayFallback: true)
        expect(
            model.rows[0].offersConnectAsVirtualDisplayFallback,
            "a failure the caller marks as a host-screen preference's own offers the fallback"
        )
        model.stopping()
        expect(
            model.rows[0].offersConnectAsVirtualDisplayFallback,
            "cancelling on top of a failed attempt does not withdraw the offer"
        )
        model.connectStarted(hostPublicKey: Data([1]))
        expect(
            !model.rows[0].offersConnectAsVirtualDisplayFallback,
            "a fresh attempt clears the previous failure's own offer"
        )
        model.attemptFailed(reason: "refused again", offersConnectAsVirtualDisplayFallback: true)
        model.stoppedTrying()
        expect(
            model.rows[0].offersConnectAsVirtualDisplayFallback,
            "the whole run stopping still keeps the last failure's own offer on the row"
        )

        var plain = YourMachinesWindowModel(hosts: [savedMachine("Studio", key: 2)])
        plain.connectStarted(hostPublicKey: Data([2]))
        plain.attemptFailed(reason: "could not reach it")
        expect(
            !plain.rows[0].offersConnectAsVirtualDisplayFallback,
            "an ordinary failure the caller does not mark offers no fallback at all"
        )
        print("PASS: the launch row's virtual-display fallback is offered only for a marked failure, and survives Cancel and stopping")
    }

    do {
        // The line said before this session has ever gone live names
        // the display a saved preference was trying, since nothing
        // else on screen has named it from a menu a person picked.
        let line = StartTargetConnectCopy.line(
            reasonLine: "That machine gave a reason this version of Sensorium does not know.",
            displayLabel: "Office"
        )
        expect(line.hasPrefix("Sensorium tried to start with Office."), "the line opens by naming the display -- got: \(line)")
        expect(
            line.contains("That machine gave a reason this version of Sensorium does not know."),
            "and still says everything the ordinary refusal line would have"
        )
        print("PASS: a failed preference-driven first connect names the display it was trying, ahead of the ordinary refusal line")
    }
}

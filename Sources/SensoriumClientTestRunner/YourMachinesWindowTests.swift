#if canImport(AppKit)
import AppKit
import Foundation
import SensoriumClient
import SensoriumCore

/// Waits for the first call rather than polling -- the same shape
/// `GatedPointerSink` uses elsewhere in this runner to observe an async
/// callback deterministically instead of racing it.
private actor PairIntentCallRecorder {
    private(set) var callCount = 0
    private var continuation: CheckedContinuation<Void, Never>?

    func record() {
        callCount += 1
        continuation?.resume()
        continuation = nil
    }

    func waitForFirstCall() async {
        if callCount > 0 { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

/// Reads a private stored property by name via `Mirror` -- the same technique
/// `render-ui-previews.swift`'s own `stored(_:of:as:)` uses, which reads
/// without needing write access to the property itself.
private func storedValue<T>(_ label: String, of subject: Any, as type: T.Type = T.self) -> T {
    for child in Mirror(reflecting: subject).children where child.label == label {
        guard let typed = child.value as? T else {
            print("FAIL: \(label) is \(Swift.type(of: child.value)), not \(T.self)")
            Foundation.exit(1)
        }
        return typed
    }
    print("FAIL: no stored property named \(label) on \(Swift.type(of: subject))")
    Foundation.exit(1)
}

/// `submit()` is `private`, invoked here the same way
/// `Scripts/render-ui-previews.swift` already does from outside this type --
/// Objective-C runtime dispatch bypasses Swift's access control, and this file
/// has no other way to drive a real submission without a window on screen.
@MainActor
private func triggerSubmit(_ controller: YourMachinesWindowController) {
    let selector = NSSelectorFromString("submit")
    guard controller.responds(to: selector) else {
        print("FAIL: YourMachinesWindowController no longer answers -submit")
        Foundation.exit(1)
    }
    controller.perform(selector)
}

@MainActor
private func content(of controller: YourMachinesWindowController) -> NSView {
    guard let view = storedValue("window", of: controller, as: NSWindow.self).contentView else {
        print("FAIL: the Your machines window has no content view")
        Foundation.exit(1)
    }
    return view
}

@MainActor
private func hasLabel(_ text: String, in view: NSView) -> Bool {
    for subview in view.subviews {
        if let field = subview as? NSTextField, field.stringValue == text {
            return true
        }
        if hasLabel(text, in: subview) {
            return true
        }
    }
    return false
}

@MainActor
private func label(containing needle: String, in view: NSView) -> NSTextField? {
    for subview in view.subviews {
        if let field = subview as? NSTextField, field.stringValue.contains(needle) {
            return field
        }
        if let found = label(containing: needle, in: subview) {
            return found
        }
    }
    return nil
}

@MainActor
private func button(titled title: String, in view: NSView) -> NSButton? {
    for subview in view.subviews {
        if let button = subview as? NSButton, button.attributedTitle.string == title {
            return button
        }
        if let found = button(titled: title, in: subview) {
            return found
        }
    }
    return nil
}

@MainActor
private func tap(_ button: NSButton) {
    guard let action = button.action, let target = button.target as? NSObject else {
        print("FAIL: \(button.attributedTitle.string) has no target/action wired")
        Foundation.exit(1)
    }
    _ = target.perform(action, with: button)
}

@MainActor
private func pumpUntil(_ isSatisfied: () -> Bool) async {
    for _ in 0..<200 where !isSatisfied() {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private func testMachine(_ name: String, key: UInt8, host: String) -> SavedHost {
    SavedHost(
        displayName: name,
        host: host,
        port: 7777,
        hostPublicKey: Data([key]),
        tlsCertificateHash: Data([key, key])
    )
}

@MainActor
private func rowMenuTitles(in view: NSView) -> [[String]] {
    var found: [[String]] = []
    for subview in view.subviews {
        if String(describing: type(of: subview)) == "SavedMachineRowButton" {
            let menu: NSMenu? = storedValue("rowMenu", of: subview)
            found.append(menu?.items.map(\.title) ?? [])
        }
        found += rowMenuTitles(in: subview)
    }
    return found
}

@MainActor
private func chooseRename(_ key: Data, in controller: YourMachinesWindowController) {
    let selector = NSSelectorFromString("renameRow:")
    guard controller.responds(to: selector) else {
        print("FAIL: YourMachinesWindowController no longer answers -renameRow:")
        Foundation.exit(1)
    }
    let item = NSMenuItem(title: YourMachinesWindowModel.renameTitle, action: nil, keyEquivalent: "")
    item.representedObject = key
    controller.perform(selector, with: item)
}

@MainActor
func testYourMachinesWindowTests() async {
    let mini = testMachine("Loft", key: 1, host: "mini.tail1234.ts.net")
    let studio = testMachine("Studio", key: 2, host: "studio.tail1234.ts.net")

    do {
        // The launch window is the list. With nothing paired it says
        // so in one sentence and offers the one thing to do; with
        // machines saved it draws a row each and no eyebrow above them.
        let empty = YourMachinesWindowController(store: InMemorySavedHostStore())
        expect(hasLabel("Your Machines", in: content(of: empty)), "the window's heading names the window")
        expect(
            hasLabel("No machine is paired with this one yet.", in: content(of: empty)),
            "the empty state says what is empty"
        )
        expect(
            button(titled: "Add a Machine", in: content(of: empty)) != nil,
            "and offers the only thing that changes it"
        )
        expect(
            button(titled: "Quit Sensorium", in: content(of: empty)) == nil,
            "there is no Quit button in this window -- Command-Q is how Sensorium is quit"
        )

        let listed = YourMachinesWindowController(store: InMemorySavedHostStore(hosts: [mini, studio]))
        expect(hasLabel("Loft", in: content(of: listed)), "each saved machine gets a row named after it")
        expect(hasLabel("Studio", in: content(of: listed)), "including the second one")
        expect(
            hasLabel("mini.tail1234.ts.net", in: content(of: listed)),
            "the line under each name is where that machine is"
        )
        expect(
            !hasLabel("No machine is paired with this one yet.", in: content(of: listed)),
            "the empty sentence is gone once there is a list"
        )
        expect(
            label(containing: "Loft", in: content(of: listed))?.lineBreakMode == .byTruncatingTail,
            "a name too long for its row ends in an ellipsis rather than being cut through a letter"
        )

        print("PASS: the launch window lists the saved machines, or says plainly that none is paired")
    }

    do {
        // One click connects, and nothing is dialled before it. A
        // row that is dialling says so and offers Cancel; cancelling
        // tells the client to stop and puts the address back.
        var connected: [String] = []
        var cancels = 0
        let controller = YourMachinesWindowController(store: InMemorySavedHostStore(hosts: [mini, studio]))
        controller.onConnect = { connected.append($0.displayName) }
        controller.onCancelConnecting = { cancels += 1 }

        expect(connected.isEmpty, "opening the window dials nothing")
        guard let row = button(titled: "", in: content(of: controller)) as? NSButton else {
            print("FAIL: the list has no row buttons at all")
            Foundation.exit(1)
        }
        tap(row)
        expect(connected == ["Loft"], "clicking the first row asks for that machine, got \(connected)")

        controller.connectStarted(hostPublicKey: mini.hostPublicKey)
        expect(
            hasLabel("mini.tail1234.ts.net \u{2014} connecting\u{2026}", in: content(of: controller)),
            "the row keeps its address and says it is connecting"
        )
        controller.attemptFailed(reason: "no answer")
        expect(
            hasLabel("mini.tail1234.ts.net \u{2014} no answer", in: content(of: controller)),
            "a failed attempt is reported on the row itself, address kept and reason appended"
        )

        guard let cancel = button(titled: "Cancel", in: content(of: controller)) else {
            print("FAIL: a row with an attempt out offers no Cancel")
            Foundation.exit(1)
        }
        tap(cancel)
        expect(cancels == 1, "Cancel stops the attempt that is out")
        // An attempt already out has to finish unwinding, which is not
        // instant, so the row says what it is doing rather than going quiet
        // and twitching again seconds later.
        expect(
            hasLabel("mini.tail1234.ts.net \u{2014} stopping\u{2026}", in: content(of: controller)),
            "and keeps its address and says so until that attempt has actually ended"
        )
        expect(
            button(titled: "Cancel", in: content(of: controller))?.isHidden != false,
            "with nothing left to ask for while it does"
        )
        controller.stoppedConnecting(hostPublicKey: mini.hostPublicKey)
        expect(
            hasLabel("mini.tail1234.ts.net", in: content(of: controller)),
            "after which the row goes back to saying where that machine is"
        )

        print("PASS: a row connects on one click and reports its own attempts, with a Cancel that stops them")
    }

    do {
        // Forgetting a machine asks nothing and removes exactly that
        // entry. Nothing else about the list changes.
        let store = InMemorySavedHostStore(hosts: [mini, studio])
        let controller = YourMachinesWindowController(store: store)
        let selector = NSSelectorFromString("forgetRow:")
        guard controller.responds(to: selector) else {
            print("FAIL: YourMachinesWindowController no longer answers -forgetRow:")
            Foundation.exit(1)
        }
        let item = NSMenuItem(title: "Forget", action: nil, keyEquivalent: "")
        item.representedObject = mini.hostPublicKey
        controller.perform(selector, with: item)

        expect(
            store.loadAll().map(\.displayName) == ["Studio"],
            "forgetting removes exactly that machine from this machine's own list, got \(store.loadAll().map(\.displayName))"
        )
        expect(!hasLabel("Loft", in: content(of: controller)), "and its row is gone from the window")
        expect(hasLabel("Studio", in: content(of: controller)), "while every other row stays")

        print("PASS: forgetting a machine removes that entry and nothing else")
    }

    do {
        // Rename is a row action above Forget, opens a step holding the
        // current name, and writes only on Rename.
        let store = InMemorySavedHostStore(hosts: [mini, studio])
        let controller = YourMachinesWindowController(store: store)
        expect(
            rowMenuTitles(in: content(of: controller)).first == ["Pair Again", "Rename\u{2026}", "Forget"],
            "each row's menu offers Rename\u{2026} just above Forget, got \(rowMenuTitles(in: content(of: controller)))"
        )

        chooseRename(mini.hostPublicKey, in: controller)
        let field = storedValue("renameField", of: controller, as: NSTextField.self)
        expect(
            hasLabel(YourMachinesWindowModel.renameHeading, in: content(of: controller)),
            "choosing Rename\u{2026} opens the rename step in this window"
        )
        expect(field.stringValue == "Loft", "the field starts with the name shown now, got \(field.stringValue)")

        field.stringValue = "  Attic  "
        guard let rename = button(titled: "Rename", in: content(of: controller)) else {
            print("FAIL: the rename step offers no Rename button")
            Foundation.exit(1)
        }
        tap(rename)
        expect(store.load(hostPublicKey: mini.hostPublicKey)?.displayName == "Attic", "Rename stores the trimmed name")
        expect(store.load(hostPublicKey: studio.hostPublicKey)?.displayName == "Studio", "and no other machine changes")
        expect(hasLabel("Attic", in: content(of: controller)), "the row shows the new name")
        expect(!hasLabel(YourMachinesWindowModel.renameHeading, in: content(of: controller)), "and the list is back")

        chooseRename(mini.hostPublicKey, in: controller)
        field.stringValue = "Different"
        guard let cancel = button(titled: "Cancel", in: content(of: controller)) else {
            print("FAIL: the rename step offers no Cancel button")
            Foundation.exit(1)
        }
        tap(cancel)
        expect(store.load(hostPublicKey: mini.hostPublicKey)?.displayName == "Attic", "Cancel changes nothing")
        expect(hasLabel("Attic", in: content(of: controller)), "and the list is back")

        chooseRename(mini.hostPublicKey, in: controller)
        field.stringValue = String(repeating: "b", count: 80)
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        expect(field.stringValue.count == 64, "the field stops at 64 characters, got \(field.stringValue.count)")

        let editor = NSTextView()
        field.stringValue = "changed"
        expect(
            controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:))),
            "Escape is taken by the rename field"
        )
        expect(store.load(hostPublicKey: mini.hostPublicKey)?.displayName == "Attic", "and cancels")
        expect(!hasLabel(YourMachinesWindowModel.renameHeading, in: content(of: controller)), "back on the list")

        chooseRename(mini.hostPublicKey, in: controller)
        field.stringValue = "   "
        expect(
            controller.control(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:))),
            "Return is taken by the rename field"
        )
        expect(
            store.load(hostPublicKey: mini.hostPublicKey)?.displayName == "Loft",
            "and an empty name brings back the name pairing gave, got \(store.load(hostPublicKey: mini.hostPublicKey)?.displayName ?? "none")"
        )

        print("PASS: renaming from a row's menu writes on Rename, cancels on Cancel or Escape, and restores the default when empty")
    }

    do {
        // Pairing a renamed machine again keeps the name the person chose.
        let rekeyed = SavedHost(
            displayName: "Loft",
            host: "mini.tail1234.ts.net",
            port: 7777,
            hostPublicKey: Data([9]),
            tlsCertificateHash: Data([9, 9])
        )
        let store = InMemorySavedHostStore(hosts: [mini.withCustomName("Attic")])
        var connected: [String] = []
        let controller = YourMachinesWindowController(store: store)
        controller.sendPairIntent = { _ in .sent }
        controller.pair = { _, _ in .paired(rekeyed) }
        controller.onConnect = { connected.append($0.displayName) }
        controller.beginPairAgain(with: store.loadAll()[0])
        storedValue("codeField", of: controller, as: NSTextField.self).stringValue = "111111"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nil))
        triggerSubmit(controller)
        await pumpUntil { !connected.isEmpty }

        expect(
            store.loadAll().map(\.displayName) == ["Attic"] && store.loadAll().first?.hostPublicKey == Data([9]),
            "the machine paired again under a new key keeps its custom name, got \(store.loadAll().map(\.displayName))"
        )

        print("PASS: pairing a renamed machine again keeps its name")
    }

    do {
        // Add a Machine is two steps inside this same window: the tailnet
        // list, then the code. Neither opens a window of its own, and
        // Back returns to the list from either.
        let controller = YourMachinesWindowController(store: InMemorySavedHostStore(hosts: [mini]))
        controller.apply(deviceList: .devices([
            TailnetDevicePickerRow(peer: TailnetPeer(
                id: "1", displayName: "Studio", magicDNSName: "studio.tail1234.ts.net",
                tailnetIPv4: "100.64.1.7", tailnetIPv6: nil, isOnline: true, isThisMachine: false
            ))
        ]))
        expect(hasLabel("Add a Machine", in: content(of: controller)), "the add step names itself in a heading")
        expect(
            hasLabel(
                "Every other machine on your tailnet appears here, whether or not Sensorium Host is running on it.",
                in: content(of: controller)
            ),
            "the subtitle excludes this machine by name, since the list right below it does too"
        )
        expect(
            button(titled: "Enter Address Manually\u{2026}", in: content(of: controller)) != nil,
            "typing an address by hand is one click away, and never the first thing shown"
        )
        expect(button(titled: "Look Again", in: content(of: controller)) != nil, "a device list can be re-checked")
        expect(!hasLabel("Your Machines", in: content(of: controller)), "the list is replaced, not stacked beside")

        guard let back = button(titled: "Back", in: content(of: controller)) else {
            print("FAIL: the add step offers no way back to Your machines")
            Foundation.exit(1)
        }
        tap(back)
        expect(hasLabel("Your Machines", in: content(of: controller)), "Back returns to the list")

        controller.showCodeStep(for: ViewerPairingDevice(address: "studio.tail1234.ts.net", name: "Studio"))
        expect(
            hasLabel("Type the Code Shown on Studio", in: content(of: controller)),
            "the code step names the machine the code is on"
        )
        expect(
            hasLabel(
                "Shown by Sensorium Host on that machine under Show Pairing Code.",
                in: content(of: controller)
            ),
            "the code field's hint says where that code comes from"
        )
        expect(
            hasLabel("Name (optional)", in: content(of: controller)),
            "the optional name field is labelled as a sentence, not an uppercase eyebrow"
        )
        expect(button(titled: "Pair", in: content(of: controller)) != nil, "and the step's own button commits it")

        print("PASS: adding a machine is two steps inside the launch window, with a way back from each")
    }

    do {
        // Nothing in this window is labelled with an uppercase
        // eyebrow. Every label is a sentence, in every step.
        let controller = YourMachinesWindowController(store: InMemorySavedHostStore(hosts: [mini]))

        @MainActor
        func shoutedLabels(in view: NSView) -> [String] {
            var found: [String] = []
            for subview in view.subviews {
                if let field = subview as? NSTextField {
                    let text = field.stringValue
                    let letters = text.filter(\.isLetter)
                    if letters.count > 2, letters.allSatisfy(\.isUppercase) {
                        found.append(text)
                    }
                }
                found += shoutedLabels(in: subview)
            }
            return found
        }

        var shouted = shoutedLabels(in: content(of: controller))
        controller.apply(deviceList: .noOtherDevices)
        shouted += shoutedLabels(in: content(of: controller))
        controller.showCodeStep(for: ViewerPairingDevice(address: "mini.local", name: "Loft"))
        shouted += shoutedLabels(in: content(of: controller))
        controller.showCodeStep(for: nil)
        shouted += shoutedLabels(in: content(of: controller))

        expect(shouted.isEmpty, "no step shouts a label in capitals, got \(shouted)")

        print("PASS: every label in the launch window is a sentence, in every step")
    }

    do {
        // A hand-typed address adds the address field above the code,
        // and only that path shows one.
        let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
        controller.showCodeStep(for: ViewerPairingDevice(address: "mini.local", name: "Loft"))
        let addressField = storedValue("addressField", of: controller, as: NSTextField.self)
        expect(addressField.superview == nil, "a machine picked from the list is never asked for its address again")

        controller.showCodeStep(for: nil)
        expect(addressField.superview != nil, "typing an address by hand asks for one")
        expect(
            hasLabel("The address of the machine you want to add", in: content(of: controller)),
            "and labels it as a sentence"
        )

        print("PASS: only the hand-typed path asks for an address, above the code")
    }

    do {
        // Showing the code step for a picked device sends exactly one
        // pairIntent, and a wrong code retyped and resubmitted never
        // sends a second one.
        let recorder = PairIntentCallRecorder()
        let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
        controller.sendPairIntent = { _ in
            await recorder.record()
            return .sent
        }
        controller.pair = { _, _ in .failed(.refused(reason: "invalid-code")) }
        controller.showCodeStep(for: ViewerPairingDevice(address: "mini.local", name: "Loft"))

        await recorder.waitForFirstCall()
        expect(await recorder.callCount == 1, "the code step announces this machine exactly once as soon as it appears")

        let codeField = storedValue("codeField", of: controller, as: NSTextField.self)
        codeField.stringValue = "111111"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nil))
        triggerSubmit(controller)
        await pumpUntil { storedValue("isPairing", of: controller, as: Bool.self) == false }

        expect(
            await recorder.callCount == 1,
            "retyping a wrong code and resubmitting does not announce this machine a second time"
        )
        expect(
            label(containing: "did not", in: content(of: controller)) != nil
                || label(containing: "code", in: content(of: controller)) != nil,
            "the refusal is said in the window rather than only logged"
        )

        print("PASS: the code step announces this machine exactly once, unaffected by a wrong code resubmitted")
    }

    do {
        // Typing an address by hand has no machine to announce yet, so
        // nothing is sent at all.
        let recorder = PairIntentCallRecorder()
        let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
        controller.sendPairIntent = { _ in
            await recorder.record()
            return .sent
        }
        controller.showCodeStep(for: nil)
        // Nothing to wait on deterministically -- the assertion is that this
        // path never calls the closure at all, so give the window's own
        // startup work a few scheduling turns to prove that, not a positive.
        for _ in 0..<20 { await Task.yield() }
        expect(
            await recorder.callCount == 0,
            "typing an address by hand announces nothing -- there is no picked machine to announce"
        )

        print("PASS: the hand-typed address path never announces this machine before a code is submitted")
    }

    do {
        // A pairIntent that could not reach the machine says so in the
        // same words a failed pairing attempt already uses.
        let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
        controller.sendPairIntent = { _ in .failed(.unreachable) }
        controller.showCodeStep(for: ViewerPairingDevice(address: "mini.local", name: "Loft"))
        let expected = ViewerPairingFailureCopy.copy(for: .unreachable, hostLabel: "Loft")
        await pumpUntil { hasLabel(expected.headline, in: content(of: controller)) }
        expect(
            hasLabel(expected.headline, in: content(of: controller)),
            "an unreachable machine is reported on the code step instead of leaving it waiting silently"
        )

        print("PASS: a pairing announcement that cannot reach the machine is reported in the window")
    }

    do {
        // While a pairing attempt is in flight the button itself says
        // so -- a disabled button under the pointer where a second
        // click would land is easy to read as stuck rather than
        // working.
        let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
        controller.sendPairIntent = { _ in .sent }
        controller.pair = { _, _ in .failed(.unknown) }
        controller.showCodeStep(for: ViewerPairingDevice(address: "mini.local", name: "Loft"))
        let codeField = storedValue("codeField", of: controller, as: NSTextField.self)
        codeField.stringValue = "111111"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nil))
        triggerSubmit(controller)

        expect(
            storedValue("isPairing", of: controller, as: Bool.self) == true,
            "the attempt is marked in flight before its result can arrive"
        )
        let pairButton = storedValue("pairButton", of: controller, as: NSButton.self)
        expect(
            pairButton.attributedTitle.string == "Pairing\u{2026}",
            "the button relabels itself during the attempt, got \(pairButton.attributedTitle.string)"
        )
        expect(!pairButton.isEnabled, "and disables so a second press cannot start a second attempt")

        await pumpUntil { storedValue("isPairing", of: controller, as: Bool.self) == false }
        expect(
            pairButton.attributedTitle.string == "Pair",
            "the button returns to its resting name once the attempt ends, got \(pairButton.attributedTitle.string)"
        )

        print("PASS: the Pair button reads Pairing\u{2026} during an in-flight attempt and Pair once it ends")
    }

    do {
        // A successful pairing saves the machine, returns to Your machines
        // with that row there, and connects to it without a second
        // click.
        let store = InMemorySavedHostStore()
        var connected: [String] = []
        let controller = YourMachinesWindowController(store: store)
        controller.sendPairIntent = { _ in .sent }
        controller.pair = { _, _ in .paired(studio) }
        controller.onConnect = { connected.append($0.displayName) }
        controller.showCodeStep(for: ViewerPairingDevice(address: "studio.tail1234.ts.net", name: "Studio"))
        let codeField = storedValue("codeField", of: controller, as: NSTextField.self)
        codeField.stringValue = "111111"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nil))
        triggerSubmit(controller)
        await pumpUntil { !connected.isEmpty }

        expect(
            store.loadAll().map(\.displayName) == ["Studio"],
            "the newly paired machine is saved, got \(store.loadAll().map(\.displayName))"
        )
        expect(hasLabel("Your Machines", in: content(of: controller)), "and the window is back on the list")
        expect(connected == ["Studio"], "which then connects to it without a second click, got \(connected)")

        print("PASS: pairing saves the machine, returns to the list, and connects to it")
    }

    do {
        // The address hint/error slot always reserves the two-line
        // height: letting an error shrink that row moved the code
        // field, name field and Pair button by the missing line's own
        // height every time an error appeared or cleared.
        let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
        controller.showCodeStep(for: nil)
        let window = storedValue("window", of: controller, as: NSWindow.self)
        window.contentView?.layoutSubtreeIfNeeded()
        let addressHint = storedValue("addressHint", of: controller, as: NSTextField.self)
        let addressField = storedValue("addressField", of: controller, as: NSTextField.self)
        let reservedHintHeight = addressHint.frame.height

        addressField.stringValue = "http://mini.local"
        controller.controlTextDidChange(Notification(name: Notification.Name("test")))
        window.contentView?.layoutSubtreeIfNeeded()
        expect(
            addressHint.frame.height == reservedHintHeight,
            "a one-line error keeps the two-line reserved height instead of moving every field below it -- "
                + "reserved \(reservedHintHeight), with the error showing \(addressHint.frame.height)"
        )

        addressField.stringValue = ""
        controller.controlTextDidChange(Notification(name: Notification.Name("test")))
        window.contentView?.layoutSubtreeIfNeeded()
        expect(
            addressHint.frame.height == reservedHintHeight,
            "and the plain hint still holds it, got \(addressHint.frame.height)"
        )

        print("PASS: the address hint/error slot always reserves the two-line height")
    }

    do {
        // The add step's own Tailscale states, driven only through the
        // injected lookup and opener closures -- the same shape the
        // host's setup window is verified with.
        let fakeAppURL = URL(fileURLWithPath: "/Applications/Tailscale.app")
        let unreachableReason = TailnetDevicePickerFetchError.tailscaledUnreachable.reason

        let notInstalled = YourMachinesWindowController(
            store: InMemorySavedHostStore(), tailscaleAppURLLookup: { nil }, onOpenTailscaleApp: { _ in }
        )
        notInstalled.apply(deviceList: .unreachable(reason: unreachableReason))
        expect(
            button(titled: "Open Tailscale", in: content(of: notInstalled)) == nil,
            "with Tailscale not installed, offering to open it would only lead nowhere, so the button is absent"
        )

        var openedURL: URL?
        let installed = YourMachinesWindowController(
            store: InMemorySavedHostStore(), tailscaleAppURLLookup: { fakeAppURL }, onOpenTailscaleApp: { openedURL = $0 }
        )
        installed.apply(deviceList: .unreachable(reason: unreachableReason))
        guard let openTailscale = button(titled: "Open Tailscale", in: content(of: installed)) else {
            print("FAIL: Tailscale is installed, so tailscaled-unreachable must offer a button to open it")
            Foundation.exit(1)
        }
        tap(openTailscale)
        expect(openedURL == fakeAppURL, "tapping passes exactly the looked-up URL, not a reconstructed one")

        let emptyTailnet = YourMachinesWindowController(
            store: InMemorySavedHostStore(), tailscaleAppURLLookup: { fakeAppURL }, onOpenTailscaleApp: { _ in }
        )
        emptyTailnet.apply(deviceList: .noOtherDevices)
        expect(
            button(titled: "Open Tailscale", in: content(of: emptyTailnet)) == nil,
            "an empty tailnet is answered fine, not a reason to suggest opening Tailscale"
        )
        expect(
            hasLabel(
                "Nothing else is on your tailnet yet. Sign in to Tailscale on the machine you want to work "
                    + "on, then choose Look Again.",
                in: content(of: emptyTailnet)
            ),
            "an empty tailnet points at the actual fix -- getting the other machine onto the tailnet"
        )

        let loading = YourMachinesWindowController(store: InMemorySavedHostStore())
        loading.apply(deviceList: .loading)
        expect(
            hasLabel("Looking for machines on your tailnet\u{2026}", in: content(of: loading)),
            "the loading line says devices, matching the unfiltered list it precedes"
        )

        print("PASS: the add step offers Open Tailscale only where it leads somewhere")
    }

    do {
        // Before the first picture there is no canvas window to say
        // anything in, so the first dial and every attempt it makes
        // are reported here. The picture arriving is what puts this
        // window away, and the overlay's own "Your machines" is what
        // brings it back -- on the list, wherever it had been left.
        let controller = YourMachinesWindowController(store: InMemorySavedHostStore(hosts: [mini, studio]))
        controller.connectStarted(hostPublicKey: mini.hostPublicKey)
        expect(
            hasLabel("mini.tail1234.ts.net \u{2014} connecting\u{2026}", in: content(of: controller)),
            "a first dial is reported on this window's own row, not in a canvas nobody can see yet"
        )
        controller.attemptFailed(reason: "no answer")
        expect(
            hasLabel("mini.tail1234.ts.net \u{2014} no answer", in: content(of: controller)),
            "and so is an attempt that failed"
        )
        controller.stoppedTrying()
        expect(
            hasLabel("mini.tail1234.ts.net \u{2014} no answer", in: content(of: controller)),
            "a run that gave up leaves its reason where the person is looking"
        )

        controller.connectStarted(hostPublicKey: mini.hostPublicKey)
        // What a session going live does to this window: the row has nothing
        // left to report, and the list steps aside for the picture.
        controller.stoppedConnecting()
        controller.hide()
        expect(!controller.isVisible, "a session that went live leaves this window off screen")
        expect(
            hasLabel("mini.tail1234.ts.net", in: content(of: controller)),
            "and the row it dialled is back to saying where that machine is"
        )

        controller.beginPairAgain(with: studio)
        expect(
            hasLabel("Type the Code Shown on Studio", in: content(of: controller)),
            "the overlay's Pair again opens this window on that machine's code step"
        )
        controller.showList()
        expect(
            hasLabel(YourMachinesWindowModel.heading, in: content(of: controller)),
            "and the overlay's Your machines brings the list itself back"
        )

        print("PASS: the launch window reports every dial before the first picture, steps aside for it, and comes back on request")
    }

    do {
        // Pairing again with a machine that has a new key replaces that
        // machine's row. Its old key is dead -- that is why the pairing
        // happened -- and leaving it listed offers a row that can
        // never connect again.
        let rekeyed = SavedHost(
            displayName: "Loft",
            host: "mini.tail1234.ts.net",
            port: 7777,
            hostPublicKey: Data([9]),
            tlsCertificateHash: Data([9, 9])
        )
        let store = InMemorySavedHostStore(hosts: [mini, studio])
        var connected: [String] = []
        let controller = YourMachinesWindowController(store: store)
        controller.sendPairIntent = { _ in .sent }
        controller.pair = { _, _ in .paired(rekeyed) }
        controller.onConnect = { connected.append($0.displayName) }
        controller.beginPairAgain(with: mini)
        let codeField = storedValue("codeField", of: controller, as: NSTextField.self)
        codeField.stringValue = "111111"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nil))
        triggerSubmit(controller)
        await pumpUntil { !connected.isEmpty }

        let keys = store.loadAll().map(\.hostPublicKey)
        expect(
            keys.count == 2 && keys.contains(Data([9])) && !keys.contains(Data([1])),
            "the machine paired again keeps one row, under its new key and not its old one, got \(keys)"
        )
        expect(
            store.loadAll().contains { $0.hostPublicKey == Data([2]) && $0.displayName == "Studio" },
            "and every other saved machine is untouched"
        )

        print("PASS: pairing a machine again replaces its row rather than listing a dead one beside it")
    }

    do {
        // Every link on the add step starts at the same left edge.
        // Look Again was stretched the full width of the window and
        // drew centred, which read as a heading rather than as one of
        // the three things that can be done there.
        let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
        controller.apply(deviceList: .noOtherDevices)
        let window = storedValue("window", of: controller, as: NSWindow.self)
        window.contentView?.layoutSubtreeIfNeeded()
        guard let lookAgain = button(titled: "Look Again", in: content(of: controller)),
              let back = button(titled: "Back", in: content(of: controller)) else {
            print("FAIL: the add step no longer offers both Look Again and Back")
            Foundation.exit(1)
        }
        expect(
            abs(lookAgain.frame.minX - back.frame.minX) < 0.5,
            "Look Again starts where every other link on the step does, got \(lookAgain.frame.minX) against \(back.frame.minX)"
        )
        expect(
            lookAgain.frame.width < content(of: controller).frame.width / 2,
            "and is only as wide as its own words, got \(lookAgain.frame.width)"
        )

        print("PASS: every link on the add step starts at the same left edge")
    }

    do {
        // The Window menu's Minimize and Zoom items act on whichever window
        // is key; this one must be able to receive them like any other.
        let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
        let window = storedValue("window", of: controller, as: NSWindow.self)
        expect(
            window.styleMask.contains(.miniaturizable),
            "the Your Machines window can be minimized, got \(window.styleMask)"
        )

        print("PASS: the Your Machines window can be minimized")
    }
}

/// A row's "\u{2026}" button carries no text of its own, so VoiceOver reads
/// only whatever accessibility label it is given -- the same fact this row's
/// tooltip already states, and naming the machine, since a list of rows all
/// reading "More actions" with no machine named would leave a person unable
/// to tell one row's control from another's.
@MainActor
func testYourMachinesWindowMoreButtonAccessibilityLabelTests() {
    let mini = testMachine("Loft", key: 1, host: "mini.tail1234.ts.net")
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore(hosts: [mini]))
    guard let more = button(titled: "\u{2026}", in: content(of: controller)) else {
        print("FAIL: a saved machine's row has no \"\u{2026}\" button")
        Foundation.exit(1)
        return
    }
    expect(
        more.accessibilityLabel() == "More actions for Loft",
        "the \"\u{2026}\" button's accessibility label names the machine it acts on, "
            + "got \(more.accessibilityLabel() ?? "nil")"
    )
    expect(more.toolTip == more.accessibilityLabel(), "and its tooltip says the same thing")

    print("PASS: a saved machine's row's \"\u{2026}\" button carries an accessibility label naming that machine")
}

/// Every row draws a dot before its detail line, whatever it says, so the
/// addresses of an idle row, a failed one and one nothing is known about
/// start at the same place.
@MainActor
func testYourMachinesRowDetailLinesShareOneLeftEdgeTests() {
    let idle = testMachine("Loft", key: 1, host: "mini.tail1234.ts.net")
    let failing = testMachine("Studio", key: 2, host: "studio.tail1234.ts.net")
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore(hosts: [idle, failing]))
    controller.connectStarted(hostPublicKey: failing.hostPublicKey)
    controller.attemptFailed(reason: "no answer")
    let root = content(of: controller)
    root.layoutSubtreeIfNeeded()

    guard let idleDetail = label(containing: "mini.tail1234.ts.net", in: root),
          let failedDetail = label(containing: "studio.tail1234.ts.net", in: root) else {
        expect(false, "both rows show a detail line")
        return
    }
    let idleX = idleDetail.convert(idleDetail.bounds, to: root).minX
    let failedX = failedDetail.convert(failedDetail.bounds, to: root).minX
    expect(abs(idleX - failedX) < 0.5, "an idle row's address and a failed row's start together, got \(idleX) and \(failedX)")
    let beforeIdle = (idleDetail.superview as? NSStackView)?.arrangedSubviews.first
    expect(
        beforeIdle != nil && beforeIdle !== idleDetail && beforeIdle?.frame.size == NSSize(width: 6, height: 6),
        "a row nothing is known about still draws a dot before its address"
    )

    print("PASS: every row's detail line starts at the same x, dot or not")
}

/// The "..." glyph rides the text baseline, so its ink sits low in its own
/// frame; the button has to put the ink, not the frame, on its centre.
@MainActor
func testYourMachinesMoreButtonEllipsisIsCentredTests() {
    let mini = testMachine("Loft", key: 1, host: "mini.tail1234.ts.net")
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore(hosts: [mini]))
    let root = content(of: controller)
    root.layoutSubtreeIfNeeded()
    guard let more = button(titled: "\u{2026}", in: root) else {
        expect(false, "a saved machine's row has a \"\u{2026}\" button")
        return
    }
    let side = Int((more.bounds.width * 2).rounded())
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: Int((more.bounds.height * 2).rounded()),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = more.bounds.size
    more.cacheDisplay(in: more.bounds, to: rep)
    var minY = Int.max, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.3 {
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    expect(maxY >= 0, "the \"\u{2026}\" button draws its glyph")
    let offset = Double(minY + maxY + 1) / 2 - Double(rep.pixelsHigh) / 2
    expect(abs(offset) <= 1.0, "the \"\u{2026}\" ink is within half a point of its button's centre, got \(offset) px at 2x")

    print("PASS: the \"\u{2026}\" glyph sits on the middle of its button")
}

/// `ViewerFormControls.actionButton`'s own `>= 96` width floor only pads a
/// short title; a longer one, like the add step's own, otherwise hugs the
/// accent fill edge-to-edge with no horizontal margin at all.
@MainActor
func testViewerFormActionButtonPaddingTests() {
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
    guard let addButton = button(titled: YourMachinesWindowModel.addTitle, in: content(of: controller)) else {
        print("FAIL: the empty state's add button is missing")
        Foundation.exit(1)
        return
    }
    let titleWidth = ceil(addButton.attributedTitle.size().width)
    expect(
        addButton.intrinsicContentSize.width - titleWidth >= 2 * ViewerDesign.Space.md,
        "the add button's intrinsic width should exceed its title width by at least twice Space.md, "
            + "got \(addButton.intrinsicContentSize.width) against a title width of \(titleWidth)"
    )
    expect(
        addButton.intrinsicContentSize.width >= 96,
        "and still never falls below the button's own 96pt floor, got \(addButton.intrinsicContentSize.width)"
    )

    print("PASS: the add button pads its title rather than hugging the accent fill's own edge")
}

/// Form buttons share the 13pt medium label with status panel buttons
/// (`ViewerActionButton.titleFont`).
@MainActor
func testViewerFormControlsButtonFontSizeTests() {
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
    guard let addButton = button(titled: YourMachinesWindowModel.addTitle, in: content(of: controller)) else {
        print("FAIL: the empty state's add button is missing")
        Foundation.exit(1)
        return
    }
    guard let font = addButton.attributedTitle.attribute(.font, at: 0, effectiveRange: nil) as? NSFont else {
        print("FAIL: the add button's title carries no font attribute")
        Foundation.exit(1)
        return
    }
    expect(
        font.pointSize == 13,
        "the add button's title is 13pt, matching the status panel's own buttons, got \(font.pointSize)"
    )

    print("PASS: ViewerFormControls' own buttons are 13pt, matching the status panel's own buttons")
}

/// `ViewerPairingFieldCell`'s own title box: centred in the field's bounds,
/// and tall enough that a mono digit's own glyph -- taller than the font's
/// ascender/descender pair reports -- does not lose its top to a box sized
/// to look centred rather than to bound every glyph.
@MainActor
func testViewerPairingFieldCellCenteringTests() {
    // The cell class is module-internal, so this reaches the real fields
    // through the public window controller rather than constructing one
    // directly -- `NSTextFieldCell.titleRect(forBounds:)` still dispatches
    // to the override across the module boundary, the same trick the
    // add-button padding test above relies on for `intrinsicContentSize`.
    func titleRect(field: NSTextField, fieldHeight: CGFloat) -> (rect: NSRect, bounds: NSRect, font: NSFont) {
        guard let cell = field.cell as? NSTextFieldCell, let font = field.font else {
            print("FAIL: the pairing field has no cell or font to measure")
            Foundation.exit(1)
        }
        let bounds = NSRect(x: 0, y: 0, width: 200, height: fieldHeight)
        return (cell.titleRect(forBounds: bounds), bounds, font)
    }

    let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
    controller.showCodeStep(for: nil)
    let addressField = storedValue("addressField", of: controller, as: NSTextField.self)
    let codeField = storedValue("codeField", of: controller, as: NSTextField.self)
    let nameField = storedValue("nameField", of: controller, as: NSTextField.self)

    // The 44pt code field, at its own 20pt mono size -- the case the clipped
    // placeholder was reported in. The box is sized from the font's full
    // bounding rect, not its ascender/descender pair: on a machine without
    // JetBrains Mono installed (this fallback is `NSFont.monospacedSystemFont`),
    // that pair alone is visibly shorter than a mono digit's own glyph.
    do {
        let (rect, bounds, font) = titleRect(field: codeField, fieldHeight: 44)
        expect(
            rect.height == ceil(font.boundingRectForFont.height),
            "the title box is sized from the font's own bounding rect, got \(rect.height) against "
                + "\(ceil(font.boundingRectForFont.height))"
        )
        expect(
            abs(rect.midY - bounds.midY) < 0.5,
            "the title box is centred in the field's own bounds, got midY \(rect.midY) against \(bounds.midY)"
        )
    }

    // The 32pt address and name fields, at their own 14pt sizes, mono and not.
    for field in [addressField, nameField] {
        let (rect, bounds, font) = titleRect(field: field, fieldHeight: 32)
        expect(
            rect.height == ceil(font.boundingRectForFont.height),
            "a 32pt field's title box is sized from its font's bounding rect too"
        )
        expect(
            abs(rect.midY - bounds.midY) < 0.5,
            "and stays centred in a 32pt field, got midY \(rect.midY) against \(bounds.midY)"
        )
    }

    print("PASS: the pairing field cell centres its title box, tall enough not to clip a mono digit")
}

/// The code field's placeholder stays where it was when the field takes
/// focus: the field editor that draws it while editing is given the same
/// box the cell draws it in.
@MainActor
func testViewerPairingFieldPlaceholderStaysPutWhileEditingTests() {
    // The rows and the rightmost column the field's text inks, in points.
    func ink(_ field: NSTextField) -> (midY: CGFloat, maxX: CGFloat)? {
        field.displayIfNeeded()
        guard let rep = field.bitmapImageRepForCachingDisplay(in: field.bounds) else { return nil }
        field.cacheDisplay(in: field.bounds, to: rep)
        let scale = CGFloat(rep.pixelsHigh) / field.bounds.height
        // Past the caret, which stands at the start of an empty field, and
        // inside the border, which turns accent while editing.
        let firstColumn = Int(16 * scale)
        let border = Int(3 * scale)
        var rows: [Int] = []
        var maxX = 0
        for y in border..<(rep.pixelsHigh - border) {
            for x in firstColumn..<(rep.pixelsWide - border) {
                guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if color.brightnessComponent > 0.3 {
                    if rows.last != y { rows.append(y) }
                    maxX = max(maxX, x)
                }
            }
        }
        guard let top = rows.first, let bottom = rows.last else { return nil }
        return (CGFloat(top + bottom) / 2 / scale, CGFloat(maxX) / scale)
    }
    func placeholderMidY(_ field: NSTextField) -> CGFloat? { ink(field)?.midY }

    let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
    controller.showCodeStep(for: nil)
    let codeField = storedValue("codeField", of: controller, as: NSTextField.self)
    expect(codeField.currentEditor() == nil, "the code field is not being edited while the address field has focus")
    guard let resting = placeholderMidY(codeField) else {
        expect(false, "the resting code field draws its placeholder")
        return
    }
    codeField.window?.makeFirstResponder(codeField)
    expect(codeField.currentEditor() != nil, "the code field is being edited once it has focus")
    guard let editing = placeholderMidY(codeField) else {
        expect(false, "the focused, empty code field still draws its placeholder")
        return
    }
    expect(
        abs(editing - resting) <= 1,
        "the placeholder stays put when the field takes focus: \(resting)pt from the top at rest, \(editing)pt while editing"
    )

    guard let restingWidth = ink(codeField)?.maxX else { return }
    (codeField.currentEditor() as? NSTextView)?.insertText("4", replacementRange: NSRange(location: 0, length: 0))
    let typedWidth = ink(codeField)?.maxX ?? 0
    expect(
        typedWidth < restingWidth / 2,
        "the placeholder goes once a digit is typed: ink reaches \(typedWidth)pt, the placeholder \(restingWidth)pt"
    )
    codeField.window?.makeFirstResponder(nil)
    codeField.stringValue = ""
    expect(
        codeField.placeholderAttributedString?.string == "000 000",
        "the field has its placeholder back once editing ends"
    )

    print("PASS: the code field's placeholder does not move when the field takes focus")
}

/// Selected text and the caret in the viewer's fields take the design
/// tokens, the same ones the Linux viewer and the host's canvas editor use,
/// not the system highlight.
@MainActor
func testViewerPairingFieldSelectionColoursTests() {
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
    controller.showCodeStep(for: nil)
    let codeField = storedValue("codeField", of: controller, as: NSTextField.self)
    codeField.window?.makeFirstResponder(codeField)
    guard let editor = codeField.currentEditor() as? NSTextView else {
        expect(false, "the focused code field has a field editor")
        return
    }
    expect(
        editor.insertionPointColor == ViewerDesign.accentHi.nsColor,
        "the caret is accentHi -- got \(editor.insertionPointColor)"
    )
    expect(
        editor.selectedTextAttributes[.backgroundColor] as? NSColor == ViewerDesign.selection.nsColor
            && editor.selectedTextAttributes[.foregroundColor] as? NSColor == ViewerDesign.ink.nsColor,
        "selected text is ink on the selection token -- got \(editor.selectedTextAttributes)"
    )

    print("PASS: the viewer's fields draw selected text and the caret in the design tokens")
}

/// VoiceOver reads a field's placeholder through its accessibility API, so
/// the placeholder the cell holds while a field is being edited is still the
/// one reported for the focused, empty field.
@MainActor
func testViewerPairingFieldAccessibilityPlaceholderTests() {
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
    controller.showCodeStep(for: nil)
    for (name, placeholder) in [("codeField", "000 000"), ("addressField", "mini.local"), ("nameField", "Studio")] {
        let field = storedValue(name, of: controller, as: NSTextField.self)
        field.window?.makeFirstResponder(field)
        expect(field.currentEditor() != nil, "\(name) is being edited once it has focus")
        expect(
            field.accessibilityPlaceholderValue() == placeholder,
            "the focused, empty \(name) still reports \(placeholder) as its placeholder -- got "
                + "\(String(describing: field.accessibilityPlaceholderValue()))"
        )
    }

    print("PASS: a pairing field reports its placeholder to VoiceOver while it is being edited")
}

/// A field's placeholder comes back once its editing is over, even when the
/// view it sat in was taken down mid-edit or editing ended without the cell
/// being told.
@MainActor
func testViewerPairingFieldPlaceholderSurvivesTeardownTests() {
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
    controller.showCodeStep(for: nil)
    let codeField = storedValue("codeField", of: controller, as: NSTextField.self)
    codeField.window?.makeFirstResponder(codeField)
    expect(codeField.currentEditor() != nil, "the code field is being edited once it has focus")
    controller.showList()
    expect(codeField.currentEditor() == nil, "leaving the code step ends editing the code field")
    expect(
        codeField.placeholderAttributedString?.string == "000 000",
        "the code field has its placeholder back at rest -- got "
            + "\(String(describing: codeField.placeholderAttributedString?.string))"
    )
    expect(
        codeField.accessibilityPlaceholderValue() == "000 000",
        "and still reports it to VoiceOver -- got \(String(describing: codeField.accessibilityPlaceholderValue()))"
    )

    guard let cellType = codeField.cell.map({ type(of: $0) }) as? NSTextFieldCell.Type else {
        expect(false, "the code field has a text field cell")
        return
    }
    let cell = cellType.init(textCell: "")
    let field = NSTextField()
    field.cell = cell
    cell.placeholderAttributedString = NSAttributedString(string: "000 000")
    cell.edit(withFrame: field.bounds, in: field, editor: NSTextView(), delegate: nil, event: nil)
    expect(
        cell.placeholderAttributedString?.string == "000 000",
        "a field no longer being edited has its placeholder back even though endEditing never ran -- got "
            + "\(String(describing: cell.placeholderAttributedString?.string))"
    )

    print("PASS: a pairing field gets its placeholder back when its editing is cut short")
}

/// The observer a cell registers while its field is edited goes with the cell.
@MainActor
func testViewerPairingFieldObserverLifetimeTests() {
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
    controller.showCodeStep(for: nil)
    let codeField = storedValue("codeField", of: controller, as: NSTextField.self)
    guard let cellType = codeField.cell.map({ type(of: $0) }) as? NSTextFieldCell.Type else {
        expect(false, "the code field has a text field cell")
        return
    }
    weak var observer: AnyObject?
    autoreleasepool {
        let cell = cellType.init(textCell: "")
        let field = NSTextField()
        field.cell = cell
        cell.edit(withFrame: field.bounds, in: field, editor: NSTextView(), delegate: nil, event: nil)
        observer = storedValue("editorTextObserver", of: cell, as: NSObjectProtocol?.self) as AnyObject?
        expect(observer != nil, "a cell being edited observes its field editor")
    }
    expect(observer == nil, "the field editor observer is removed when its cell goes away")

    print("PASS: a pairing field cell's editor observer never outlives the cell")
}

/// The code step's fields sit on the same 24pt column as every other control
/// in the window, edge to edge, as the Linux viewer draws them.
@MainActor
func testYourMachinesCodeStepFieldsSitOnTheColumnTests() {
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
    controller.showCodeStep(for: nil)
    let view = content(of: controller)
    view.layoutSubtreeIfNeeded()
    let inset = ViewerDesign.Space.xl
    for name in ["addressField", "codeField", "nameField"] {
        let field = storedValue(name, of: controller, as: NSTextField.self)
        let frame = field.convert(field.bounds, to: view)
        expect(
            frame.minX == inset && frame.maxX == view.bounds.width - inset,
            "the \(name) spans \(inset)...\(view.bounds.width - inset), got \(frame.minX)...\(frame.maxX)"
        )
    }
    print("PASS: the code step's fields sit on the window's 24pt column")
}

@MainActor
private func isShown(_ view: NSView) -> Bool {
    var current: NSView? = view
    while let candidate = current {
        if candidate.isHidden { return false }
        current = candidate.superview
    }
    return true
}

private func studioPeerRow() -> TailnetDevicePickerRow {
    TailnetDevicePickerRow(peer: TailnetPeer(
        id: "1", displayName: "Studio", magicDNSName: "studio.tail1234.ts.net",
        tailnetIPv4: "100.64.1.7", tailnetIPv6: nil, isOnline: true, isThisMachine: false
    ))
}

/// A machine's address is set in one face wherever it is named: the picker
/// of tailnet devices and the list of saved machines read alike.
@MainActor
func testYourMachinesPickerAndListShareTheAddressFontTests() {
    let listed = YourMachinesWindowController(
        store: InMemorySavedHostStore(hosts: [testMachine("Studio", key: 1, host: "studio.tail1234.ts.net")])
    )
    let picker = YourMachinesWindowController(store: InMemorySavedHostStore())
    picker.apply(deviceList: .devices([studioPeerRow()]))

    guard let listAddress = label(containing: "studio.tail1234.ts.net", in: content(of: listed)),
          let pickerAddress = label(containing: "studio.tail1234.ts.net", in: content(of: picker)),
          let listFont = listAddress.font, let pickerFont = pickerAddress.font else {
        expect(false, "both the list and the picker show the machine's address")
        return
    }
    expect(
        pickerFont.fontName == listFont.fontName && pickerFont.pointSize == listFont.pointSize,
        "the picker sets the address in the list's \(listFont.fontName) \(listFont.pointSize), got "
            + "\(pickerFont.fontName) \(pickerFont.pointSize)"
    )

    print("PASS: the picker and the list set a machine's address in the same font")
}

/// The add step's three links start their words at one x, whatever the width
/// of the icon ahead of each.
@MainActor
func testYourMachinesAddStepLinkTitlesShareOneLeftEdgeTests() {
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
    controller.apply(deviceList: .devices([studioPeerRow()]))
    let root = content(of: controller)
    root.layoutSubtreeIfNeeded()

    var edges: [(String, CGFloat)] = []
    for title in ["Look Again", "Enter Address Manually\u{2026}", "Back"] {
        guard let link = button(titled: title, in: root), let cell = link.cell as? NSButtonCell else {
            expect(false, "the add step offers \(title)")
            return
        }
        let titleRect = cell.titleRect(forBounds: link.bounds)
        edges.append((title, link.convert(NSPoint(x: titleRect.minX, y: 0), to: root).x))
    }
    let reference = edges[0].1
    for (title, x) in edges {
        expect(abs(x - reference) < 0.5, "\(title) starts its word at \(x), where Look Again starts at \(reference)")
    }

    print("PASS: the add step's links start their words on one edge")
}

/// A pairing that fails leaves the caret after the code that was typed, not
/// the whole code selected.
@MainActor
func testYourMachinesCodeFieldIsNotSelectedAfterAFailedPairingTests() async {
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
    controller.sendPairIntent = { _ in .sent }
    controller.pair = { _, _ in .failed(.refused(reason: "invalid-code")) }
    controller.showCodeStep(for: ViewerPairingDevice(address: "studio.tail1234.ts.net", name: "Studio"))
    let codeField = storedValue("codeField", of: controller, as: NSTextField.self)
    codeField.stringValue = "418297"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nil))
    triggerSubmit(controller)
    await pumpUntil { storedValue("isPairing", of: controller, as: Bool.self) == false }

    guard let editor = codeField.currentEditor() as? NSTextView else {
        expect(false, "the code field takes focus again so the code can be corrected")
        return
    }
    let selection = editor.selectedRange()
    expect(
        selection.length == 0 && selection.location == (editor.string as NSString).length,
        "the caret sits after the code with nothing selected, got \(selection) in \"\(editor.string)\""
    )

    print("PASS: after a refused code the caret is at the end of the code, nothing selected")
}

/// What went wrong and what to do about it read as one message: the detail
/// sits right under its headline, not a section's gap below.
@MainActor
func testYourMachinesPairingMessageHeadlineAndDetailSitTogetherTests() async {
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore())
    controller.sendPairIntent = { _ in .sent }
    controller.pair = { _, _ in .failed(.refused(reason: "invalid-code")) }
    controller.showCodeStep(for: ViewerPairingDevice(address: "studio.tail1234.ts.net", name: "Studio"))
    let headline = storedValue("messageHeadline", of: controller, as: NSTextField.self)
    let detail = storedValue("messageDetail", of: controller, as: NSTextField.self)
    expect(!isShown(headline) && !isShown(detail), "before anything goes wrong there is no message on the step")

    let codeField = storedValue("codeField", of: controller, as: NSTextField.self)
    codeField.stringValue = "418297"
    controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: nil))
    triggerSubmit(controller)
    await pumpUntil { storedValue("isPairing", of: controller, as: Bool.self) == false }

    let root = content(of: controller)
    root.layoutSubtreeIfNeeded()
    expect(isShown(headline) && isShown(detail), "a refused code shows its headline and its detail")
    let headlineFrame = headline.convert(headline.bounds, to: root)
    let detailFrame = detail.convert(detail.bounds, to: root)
    let gap = headlineFrame.minY - detailFrame.maxY
    expect(
        gap >= 0 && gap <= ViewerDesign.Space.xs,
        "the detail starts at most \(ViewerDesign.Space.xs) below its headline, got \(gap)"
    )

    print("PASS: a pairing message's headline and detail sit together")
}

/// The update line sits beneath the list, on every step, and carries
/// **Restart Now** only when it is asked to.
@MainActor
func testYourMachinesWindowUpdateLineTests() {
    let mini = testMachine("Loft", key: 1, host: "mini.tail1234.ts.net")
    let controller = YourMachinesWindowController(store: InMemorySavedHostStore(hosts: [mini]))
    let window = storedValue("window", of: controller, as: NSWindow.self)
    let heightWithoutLine = window.frame.height
    let ready = "Sensorium 0.5.0 is ready."
    expect(label(containing: ready, in: content(of: controller)).map(isShown) != true, "there is no update line until there is something to say")
    expect(
        button(titled: "Restart Now", in: content(of: controller)).map(isShown) != true,
        "and no Restart Now"
    )

    var restarts = 0
    controller.onRestartNow = { restarts += 1 }
    controller.setUpdateLine(ViewerUpdateLine(text: ready, offersRestartNow: true))
    guard let line = label(containing: ready, in: content(of: controller)),
          let restart = button(titled: "Restart Now", in: content(of: controller)) else {
        print("FAIL: the update line or its Restart Now button is missing")
        Foundation.exit(1)
        return
    }
    expect(isShown(line) && isShown(restart), "a ready update shows its line with Restart Now")
    expect(window.frame.height > heightWithoutLine, "and the window grows to hold it rather than clipping the list")
    content(of: controller).layoutSubtreeIfNeeded()
    if let row = label(containing: "Loft", in: content(of: controller)) {
        let lineTop = line.convert(line.bounds, to: nil).maxY
        let rowBottom = row.convert(row.bounds, to: nil).minY
        expect(lineTop <= rowBottom, "the line sits beneath the list, got line top \(lineTop) and row bottom \(rowBottom)")
    } else {
        expect(false, "the saved machine's row is missing")
    }
    tap(restart)
    expect(restarts == 1, "Restart Now asks for the restart")

    controller.setUpdateLine(ViewerUpdateLine(text: ready, offersRestartNow: false))
    expect(isShown(line), "during a session the line stays")
    expect(!isShown(restart), "and Restart Now does not")

    controller.showAddAMachine()
    expect(
        label(containing: ready, in: content(of: controller)).map(isShown) == true,
        "the line stays on every step of adding a machine"
    )

    controller.setUpdateLine(nil)
    expect(!isShown(line), "nothing to say hides the line")
    print("PASS: Your Machines shows the update line beneath the list on every step, with Restart Now only when offered")
}
#endif

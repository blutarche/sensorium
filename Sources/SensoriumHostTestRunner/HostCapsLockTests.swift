import AppKit
import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// Every event the injector built, in order.
private final class CapsLockPosts: @unchecked Sendable {
    private(set) var events: [CGEvent] = []

    func record(_ event: CGEvent) {
        events.append(event)
    }
}

private final class CapsLockHIDActivity: HostInjectedHIDActivity, @unchecked Sendable {
    func recordPost() {}
    func secondsSinceLastPost() -> TimeInterval? { nil }
    func sampleBeforePost() {}
    func secondsSinceProvenHardwareActivity() -> TimeInterval? { nil }
}

@MainActor
private func makeCapsLockInjector(post: @escaping (CGEvent) -> Void) -> CoreGraphicsInputInjector {
    try! CoreGraphicsInputInjector(
        canvasDisplayID: CGMainDisplayID(),
        sessionKind: .hostScreen,
        lockStateReader: FakeScreenLockState(locked: false),
        hostInjectedHIDActivity: CapsLockHIDActivity(),
        postEvent: { event, _ in post(event) },
        associateMouseAndCursor: { _ in },
        warpCursor: { _ in }
    )
}

/// The viewer's Caps Lock state reaches the host as a flag on each key, and
/// the host types capitals while it is on, without touching this machine's
/// own Caps Lock.
@MainActor
func runHostCapsLockTests() async {
    do {
        // Alpha Shift on the posted key is what makes the letter a capital
        let posts = CapsLockPosts()
        let injector = makeCapsLockInjector(post: posts.record)
        for capsLock: Bool? in [true, false, nil] {
            try! injector.inject(.key(keyCode: 0, isDown: true, modifiers: [], capsLock: capsLock))
            try! injector.inject(.key(keyCode: 0, isDown: false, modifiers: [], capsLock: capsLock))
        }
        try! injector.inject(.key(keyCode: 0, isDown: true, modifiers: [], capsLock: true))
        try! injector.inject(.pointerMoved(x: 10, y: 10))
        let alphaShift = posts.events.map { $0.flags.contains(.maskAlphaShift) }
        expect(
            alphaShift == [true, true, false, false, false, false, true, false],
            "only keys posted with Caps Lock on carry Alpha Shift, and a pointer event never picks it up, got \(alphaShift)"
        )
        let typed = posts.events.prefix(6).enumerated().compactMap { index, event in
            index.isMultiple(of: 2) ? NSEvent(cgEvent: event)?.characters : nil
        }
        expect(typed == ["A", "a", "a"], "key 0 reads as A with Caps Lock on and a otherwise, got \(typed)")
        print("PASS: a key posted with the viewer's Caps Lock on carries Alpha Shift and reads as a capital")
    }

    do {
        // The session remembers the last state it was told, until it ends
        let injector = FakeInputInjector()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            inputInjector: injector,
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        func openCanvas() {
            _ = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        }
        func press(_ capsLock: Bool?, modifiers: CanvasModifierFlags = []) {
            for isDown in [true, false] {
                _ = try! controller.handle(.input(
                    .key(keyCode: 0, isDown: isDown, modifiers: modifiers, capsLock: capsLock),
                    surfaceID: nil
                ))
            }
        }
        func injectedStates() -> [Bool?] {
            injector.events.compactMap { event -> Bool?? in
                guard case let .key(keyCode, _, _, capsLock) = event, keyCode == 0 else { return nil }
                return capsLock
            }
        }

        openCanvas()
        press(nil)
        expect(
            injectedStates() == [nil, nil],
            "a viewer that never says leaves every key as it was sent, got \(injectedStates())"
        )
        press(true)
        press(nil)
        press(false)
        press(nil)
        expect(
            injectedStates() == [nil, nil, true, true, true, true, false, false, false, false],
            "a key that does not say gets the last state the viewer gave, got \(injectedStates())"
        )
        press(true, modifiers: CanvasModifierFlags(rawValue: 0b0011_0000))
        expect(
            injectedStates().suffix(2) == [true, true],
            "masking a modifier bit this host does not know keeps the Caps Lock state, got \(injectedStates())"
        )

        _ = try! controller.handle(.goodbye(reason: "client-disconnected"))
        openCanvas()
        press(nil)
        expect(
            injectedStates().suffix(2) == [false, false],
            "the state is reset to off when the session ends, got \(injectedStates())"
        )
        print("PASS: a session keeps the viewer's last Caps Lock state for keys that do not say, and resets it at the end")
    }

    do {
        // A host-screen session does the same
        let list = FakeDisplayList([monitorSnapshot(id: 2)])
        let wake = DisplayWakeController(power: FakeDisplayPower(), displays: { list.read() }, wait: { _ in })
        let factory = FakeInputInjectorFactory()
        let controller = armedHostScreenController(
            displays: list, displayWake: wake, log: { _ in }, inputInjectorFactory: factory
        )
        guard case let .hostScreenList(entries, _) = try! controller.offerHostScreenList(),
              let entry = entries.first,
              case .hostScreenReady = try! controller.handle(.hostScreenRequest(token: entry.opaqueToken, resumeTicket: nil)) else {
            expect(false, "the host-screen session is admitted")
            return
        }
        for capsLock: Bool? in [true, nil] {
            _ = try! controller.handle(.input(.key(keyCode: 0, isDown: true, modifiers: [], capsLock: capsLock), surfaceID: nil))
            _ = try! controller.handle(.input(.key(keyCode: 0, isDown: false, modifiers: [], capsLock: capsLock), surfaceID: nil))
        }
        let states = factory.injector.events.compactMap { event -> Bool?? in
            guard case let .key(_, _, _, capsLock) = event else { return nil }
            return capsLock
        }
        expect(states == [true, true, true, true], "a host-screen session keeps the last Caps Lock state too, got \(states)")
        print("PASS: a host-screen session keeps the viewer's last Caps Lock state for keys that do not say")
    }
}

/// The same flag, typed into a real text field in a real window. The
/// injector builds the events as it does for a session; the test hands each
/// one to this process's own event queue instead of the system's, so it
/// reaches only this window and never whatever app has focus.
///
/// Synchronous throughout: it puts a real window on screen, after which a
/// later `Task.sleep` in this process never resumes (see `Entry.swift`).
@MainActor
func runHostCapsLockRealTextFieldTests() {
    NSApplication.shared.setActivationPolicy(.accessory)
    let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 240, height: 64),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
    )
    panel.setFrameOrigin(NSPoint(x: 160, y: 160))
    let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 24))
    panel.contentView?.addSubview(field)
    panel.makeKeyAndOrderFront(nil)
    expect(panel.makeFirstResponder(field), "the text field takes the keyboard")

    func pump(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while let event = NSApplication.shared.nextEvent(matching: .any, until: deadline, inMode: .default, dequeue: true) {
            NSApplication.shared.sendEvent(event)
        }
    }
    func typed() -> String {
        (field.currentEditor() as? NSTextView)?.string ?? field.stringValue
    }

    let injector = makeCapsLockInjector { event in
        guard let appKitEvent = NSEvent(cgEvent: event) else { return }
        NSApplication.shared.postEvent(appKitEvent, atStart: false)
    }
    pump(for: 0.1)
    try! injector.inject(.key(keyCode: 0, isDown: true, modifiers: [], capsLock: true))
    try! injector.inject(.key(keyCode: 0, isDown: false, modifiers: [], capsLock: true))
    pump(for: 0.3)
    let withCapsLock = typed()
    try! injector.inject(.key(keyCode: 0, isDown: true, modifiers: [], capsLock: false))
    try! injector.inject(.key(keyCode: 0, isDown: false, modifiers: [], capsLock: false))
    pump(for: 0.3)
    let thenWithout = typed()
    panel.orderOut(nil)

    expect(withCapsLock == "A", "key 0 with Caps Lock on types A into a real text field, got \"\(withCapsLock)\"")
    expect(thenWithout == "Aa", "and with it off types a, got \"\(thenWithout)\"")
    print("PASS: key 0 types A into a real text field with the viewer's Caps Lock on, and a with it off")
}

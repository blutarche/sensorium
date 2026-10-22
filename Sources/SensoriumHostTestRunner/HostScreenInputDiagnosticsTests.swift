import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// A host-screen session says in the session log what its input path is
/// doing: whether the screen is locked, which tap input is posted at, and
/// whether Accessibility is on, at the first forwarded event and again when
/// the lock state changes; and why input was dropped, once per cause. None
/// of it ever carries what was typed: while the screen is locked, typing is
/// a password.
@MainActor
func runHostScreenInputDiagnosticsTests() async {
    firstInputIsDescribed()
    lockChangesAreDescribed()
    dropsAreLoggedOncePerCause()
    noLineCarriesTypedContent()
    factoryForwardsItsLogToEveryController()
}

private let unlockedFirstLine = "host screen input: unlocked, posting at the session tap, Accessibility on"
private let lockedFirstLine = "host screen input: locked, posting at the HID tap, Accessibility on"
private let accessibilityOffFirstLine = "host screen input: unlocked, posting at the session tap, Accessibility off"
private let nowLockedLine = "host screen input: now locked, posting at the HID tap"
private let nowUnlockedLine = "host screen input: now unlocked, posting at the session tap"
private let accessibilityOffDropLine = "host screen input dropped: Accessibility is off"
private let eventNotCreatedDropLine = "host screen input dropped: an event could not be created"
private let eventNotPostedDropLine = "host screen input dropped: an event could not be posted"

@MainActor
private func firstInputIsDescribed() {
    do {
        let session = DiagnosticsSession(locked: false)
        session.send(.pointerMoved(x: 10, y: 10))
        session.send(.key(keyCode: 0, isDown: true, modifiers: []))
        session.send(.key(keyCode: 0, isDown: false, modifiers: []))
        expect(
            session.lines == [unlockedFirstLine],
            "the first forwarded event, and only it, is described while unlocked, got \(session.lines)"
        )
        expect(session.injected.count == 3, "every event still reaches the injector, got \(session.injected.count)")
    }
    do {
        let session = DiagnosticsSession(locked: true)
        session.send(.key(keyCode: 0, isDown: true, modifiers: []))
        session.send(.key(keyCode: 0, isDown: false, modifiers: []))
        expect(
            session.lines == [lockedFirstLine],
            "the first forwarded event is described while locked, got \(session.lines)"
        )
    }
    print("PASS: a host-screen session's first forwarded input names the lock state, the tap and Accessibility")
}

@MainActor
private func lockChangesAreDescribed() {
    let session = DiagnosticsSession(locked: false)
    session.send(.pointerMoved(x: 10, y: 10))
    session.lockState.setLocked(true)
    session.send(.pointerMoved(x: 11, y: 10))
    session.send(.pointerMoved(x: 12, y: 10))
    session.lockState.setLocked(false)
    session.send(.pointerMoved(x: 13, y: 10))
    session.send(.pointerMoved(x: 14, y: 10))
    expect(
        session.lines == [unlockedFirstLine, nowLockedLine, nowUnlockedLine],
        "each change of lock state during the session is logged once, with the new tap, got \(session.lines)"
    )
    print("PASS: a host-screen session logs each lock state change with the tap input now reaches")
}

@MainActor
private func dropsAreLoggedOncePerCause() {
    do {
        let session = DiagnosticsSession(locked: false, accessibilityTrusted: false)
        for _ in 0..<3 {
            session.send(.key(keyCode: 0, isDown: true, modifiers: []))
        }
        expect(session.injected.isEmpty, "nothing is injected while Accessibility is off")
        expect(
            session.lines == [accessibilityOffFirstLine, accessibilityOffDropLine],
            "input dropped for Accessibility is logged once however many events are dropped, got \(session.lines)"
        )
    }
    do {
        let session = DiagnosticsSession(locked: true)
        session.injector.failure = CoreGraphicsInputInjectorError.eventCreationFailed
        for _ in 0..<3 {
            session.send(.key(keyCode: 0, isDown: true, modifiers: []))
        }
        session.injector.failure = nil
        session.send(.pointerMoved(x: 10, y: 10))
        session.injector.failure = CoreGraphicsInputInjectorError.eventCreationFailed
        session.send(.pointerMoved(x: 11, y: 10))
        session.injector.failure = FakeInputInjector.InjectionFailure()
        session.send(.pointerMoved(x: 12, y: 10))
        session.send(.pointerMoved(x: 13, y: 10))
        expect(
            session.lines == [lockedFirstLine, eventNotCreatedDropLine, eventNotPostedDropLine],
            "each cause of a failed post is logged once per session, got \(session.lines)"
        )
    }
    print("PASS: dropped host-screen input is logged once per session for each cause")
}

/// Every key code this test types appears as decimal digits somewhere if a
/// line were to carry it, and every line the diagnostics can write has no
/// digit in it at all, so a digit anywhere is typed content leaking.
@MainActor
private func noLineCarriesTypedContent() {
    let session = DiagnosticsSession(locked: true)
    let modifierSets: [CanvasModifierFlags] = [[], [.shift], [.command], [.option], [.control], [.shift, .option]]
    for (index, keyCode) in (UInt16(0)...UInt16(50)).enumerated() {
        let modifiers = modifierSets[index % modifierSets.count]
        if keyCode == 17 {
            session.injector.failure = CoreGraphicsInputInjectorError.eventCreationFailed
        }
        if keyCode == 23 {
            session.lockState.setLocked(false)
        }
        if keyCode == 31 {
            session.lockState.setLocked(true)
            session.injector.failure = FakeInputInjector.InjectionFailure()
        }
        session.send(.key(keyCode: keyCode, isDown: true, modifiers: modifiers, capsLock: true))
        session.send(.key(keyCode: keyCode, isDown: false, modifiers: modifiers, capsLock: true))
        session.injector.failure = nil
    }
    session.send(.pointerButton(button: .left, isDown: true, x: 123.25, y: 456.5))
    session.send(.pointerButton(button: .left, isDown: false, x: 123.25, y: 456.5))
    session.send(.scrolled(deltaX: 7, deltaY: -9, x: 321, y: 654, phase: nil, momentumPhase: nil))

    expect(
        session.lines == [lockedFirstLine, eventNotCreatedDropLine, nowUnlockedLine, nowLockedLine, eventNotPostedDropLine],
        "a locked session typing keys writes only its fixed diagnostic lines, got \(session.lines)"
    )
    let forbidden = ["shift", "command", "option", "control", "caps", "key", "modifier", "pointer", "scroll"]
    for line in session.lines {
        expect(!line.contains(where: \.isNumber), "a diagnostic line carries no key code or coordinate: \(line)")
        for word in forbidden {
            expect(!line.lowercased().contains(word), "a diagnostic line says nothing about \(word): \(line)")
        }
    }
    print("PASS: typing at a locked host screen leaves no key code, modifier or position in the session log")
}

@MainActor
private func factoryForwardsItsLogToEveryController() {
    let identity = try! DeviceIdentity.generate()
    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(devicePublicKey: identity.publicKey, deviceName: "Kestrel Laptop Pro", armedAt: Date())
    ])
    var logged: [String] = []
    let factory = HostConnectionSessionFactory(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [identity.publicKey],
        requireAuthentication: true,
        inputInjectorFactory: FakeInputInjectorFactory(),
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [monitorSnapshot(id: 2)] },
        log: { logged.append($0) }
    )
    let controller = factory.makeController()
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, hostCertificateHash: nil
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: identity.publicKey, signature: try! identity.sign(transcript)
    ))
    _ = try! controller.offerHostScreenList()
    expect(
        logged.contains { $0.hasPrefix("Sensorium host: offered 1 host screens to Kestrel Laptop Pro") },
        "a controller the factory builds writes to the factory's log, got \(logged)"
    )
    print("PASS: every controller a session factory builds writes to the log the factory was given")
}

/// An admitted host-screen session whose lock state, Accessibility and
/// injector a test controls, recording every line logged after admission.
@MainActor
private final class DiagnosticsSession {
    let lockState: FlippableLockState
    let injector: FailingInputInjector
    private let controller: HostSessionController
    private var logged: [String] = []
    private var admitted = false

    var lines: [String] { logged }
    var injected: [SensoriumInputEvent] { injector.events }

    init(locked: Bool, accessibilityTrusted: Bool = true) {
        lockState = FlippableLockState(locked: locked)
        let list = FakeDisplayList([monitorSnapshot(id: 2)])
        let wake = DisplayWakeController(power: FakeDisplayPower(), displays: { list.read() }, wait: { _ in })
        let checker = FakeAccessibilityPermissionChecker()
        checker.isTrusted = accessibilityTrusted
        let injector = FailingInputInjector()
        self.injector = injector
        var record: (String) -> Void = { _ in }
        controller = armedHostScreenController(
            displays: list,
            displayWake: wake,
            log: { record($0) },
            inputInjectorFactory: AccessibilityGatedInputInjectorFactory(
                gate: AccessibilityPermissionGate(checker: checker),
                inner: FixedInputInjectorFactory(injector: injector)
            ),
            hostScreenLockStateReader: lockState
        )
        guard case let .hostScreenList(entries, _) = try! controller.offerHostScreenList(),
              let entry = entries.first,
              case .hostScreenReady = try! controller.handle(.hostScreenRequest(token: entry.opaqueToken, resumeTicket: nil)) else {
            expect(false, "the host-screen session is admitted")
            return
        }
        record = { [weak self] line in self?.logged.append(line) }
        admitted = true
    }

    func send(_ event: SensoriumInputEvent) {
        expect(admitted, "input is only sent to an admitted session")
        _ = try? controller.handle(.input(event, surfaceID: nil))
    }
}

/// Records each event it is given, or throws `failure` instead while one
/// is set.
@MainActor
private final class FailingInputInjector: InputInjecting {
    var failure: (any Error)?
    private(set) var events: [SensoriumInputEvent] = []

    func inject(_ event: SensoriumInputEvent) throws {
        if let failure {
            throw failure
        }
        events.append(event)
    }
}

@MainActor
private final class FixedInputInjectorFactory: InputInjectingFactory {
    private let injector: any InputInjecting
    init(injector: any InputInjecting) {
        self.injector = injector
    }
    func make(canvasDisplayID: UInt32, sessionKind: InputSessionKind) throws -> any InputInjecting {
        injector
    }
}

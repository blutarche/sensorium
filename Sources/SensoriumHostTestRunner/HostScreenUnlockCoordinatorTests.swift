import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

private final class UnlockTestVerifier: HostScreenPresenceProofVerifying, @unchecked Sendable {
    func verify(proof: HostScreenPresenceProof, devicePublicKey: Data, minimumStrength: HostScreenCredentialStrength?, challenge: Data) -> Bool {
        true
    }
}

private final class UnlockTestIdleSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

@MainActor
private func unlockTestDisplay() -> DisplaySnapshot {
    DisplaySnapshot(
        id: 7,
        pixelWidth: 5120,
        pixelHeight: 2880,
        modeWidth: 2560,
        modeHeight: 1440,
        modePixelWidth: 5120,
        modePixelHeight: 2880,
        bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

/// A controller (optionally already authenticated) and a coordinator with an
/// injected lock reader and unlocker -- the two seams the canvas fixtures do
/// not carry.
/// The fixed arming record every unlock fixture shares. Its `armedAt` is a
/// constant so two controllers built for the same device key compute the same
/// `HostScreenArmingFingerprint`, hence the same throttle key -- which is what
/// lets a test prove one budget is shared across two connections.
/// The strength defaults to `.softwarePresence`; the test that arms before every
/// guess runs both strengths, because neither one refills the wrong-guess
/// budget.
@MainActor
private func unlockTestArming(
    deviceKey: Data,
    strength: HostScreenCredentialStrength = .softwarePresence
) -> HostScreenArming {
    HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: deviceKey,
            deviceName: "Kestrel MacBook Pro",
            minimumCredentialStrength: strength,
            armedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    ])
}

@MainActor
private func makeUnlockFixture(
    authenticate: Bool,
    lockStateReader: any ScreenLockStateReading,
    unlocker: any LockScreenUnlocking,
    identity: DeviceIdentity? = nil,
    throttle: (any HostScreenUnlockThrottling)? = HostScreenUnlockThrottle(),
    strength: HostScreenCredentialStrength = .softwarePresence,
    liveSessionRegistry: (any HostScreenLiveSessionRegistering)? = nil,
    armingProvider: (() -> HostScreenArming)? = nil,
    inputInjectorFactory: any InputInjectingFactory = FakeInputInjectorFactory(),
    unlockChallengeNowSeconds: @escaping () -> Double = { Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000 },
    onEvent: (@Sendable (String) -> Void)? = nil
) -> (coordinator: HostSessionCoordinator, controller: HostSessionController) {
    let display = unlockTestDisplay()
    let identity = identity ?? (try! DeviceIdentity.generate())
    let deviceKey = identity.publicKey
    let armingProvider = armingProvider ?? { unlockTestArming(deviceKey: deviceKey, strength: strength) }
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        inputInjectorFactory: inputInjectorFactory,
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: armingProvider,
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenPresenceProofVerifier: UnlockTestVerifier(),
        hostScreenUnlockThrottle: throttle,
        hostScreenLiveSessionRegistry: liveSessionRegistry,
        hostScreenLocalActivitySignal: UnlockTestIdleSignal(),
        hostScreenPresenceGate: nil,
        hostScreenModeController: nil,
        unlockChallengeNowSeconds: unlockChallengeNowSeconds
    )
    if authenticate {
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey
        )
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
        ))
    }
    let coordinator = HostSessionCoordinator(
        controller: controller,
        media: CanvasSurfaceSlots { _ in FakeCanvasMedia() },
        videoSink: FakeVideoSink(),
        onEvent: onEvent,
        hostScreenMediaFactory: { _ in FakeScalableCanvasMedia() },
        lockStateReader: lockStateReader,
        lockScreenUnlocker: unlocker
    )
    return (coordinator, controller)
}

@MainActor
private func admitHostScreen(_ fixture: (coordinator: HostSessionCoordinator, controller: HostSessionController)) async -> [SensoriumMessage] {
    guard case let .hostScreenList(displays, _) = try! fixture.controller.offerHostScreenList(),
          let token = displays.first?.opaqueToken else {
        expect(false, "the fixture offers at least one display")
        return []
    }
    let log = MessageLog()
    _ = try! await fixture.coordinator.handleWritingResponse(
        .hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ),
        onWrite: { log.append($0) }
    )
    return log.all
}

private final class RecordingUnlocker: LockScreenUnlocking, @unchecked Sendable {
    let outcome: HostScreenUnlockOutcome
    private let lock = NSLock()
    private var count = 0
    init(outcome: HostScreenUnlockOutcome) { self.outcome = outcome }
    private func recordCall() { lock.lock(); count += 1; lock.unlock() }
    func unlock(password: Data) async -> HostScreenUnlockOutcome {
        recordCall()
        return outcome
    }
    var wasCalled: Bool { callCount > 0 }
    var callCount: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// A seconds source a test advances by hand, to age an unlock challenge past
/// its lifetime without waiting on a real clock.
private final class MutableSeconds {
    var value: Double
    init(_ value: Double) { self.value = value }
}

/// Collects the messages the coordinator writes. A reference type so the
/// `@Sendable` onWrite closure can append without capturing a mutable local.
private final class MessageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [SensoriumMessage] = []
    func append(_ message: SensoriumMessage) { lock.lock(); messages.append(message); lock.unlock() }
    var all: [SensoriumMessage] { lock.lock(); defer { lock.unlock() }; return messages }
}

@MainActor
func runHostScreenUnlockCoordinatorTests() async {
    // Valid-session gate and reserve refuse without an authenticated live
    // host-screen session
    do {
        let unauthenticated = makeUnlockFixture(
            authenticate: false,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .unlocked)
        )
        expect(!unauthenticated.controller.canObserveHostScreenLockState(), "an unauthenticated connection is no valid unlock session")
        expect(unauthenticated.controller.tryReserveUnlockAttempt() == nil, "and reserves no guess slot")

        let authenticatedNoHostScreen = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .unlocked)
        )
        expect(
            !authenticatedNoHostScreen.controller.canObserveHostScreenLockState(),
            "an authenticated connection with no live host-screen session is no valid unlock session"
        )
        expect(authenticatedNoHostScreen.controller.tryReserveUnlockAttempt() == nil, "and reserves no guess slot")

        let live = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .unlocked)
        )
        _ = await admitHostScreen(live)
        expect(
            live.controller.canObserveHostScreenLockState(),
            "an authenticated connection with a live host-screen session is a valid unlock session"
        )
        expect(live.controller.tryReserveUnlockAttempt() != nil, "and reserves a guess slot from its fresh budget")

        print("PASS: only an authenticated connection with a live host-screen session is a valid unlock session and can reserve a slot")
    }

    // Lock state is announced on host-screen bring-up
    do {
        let lockedFixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .unlocked)
        )
        let written = await admitHostScreen(lockedFixture)
        expect(
            written.contains(.hostScreenLockState(locked: true)),
            "host-screen bring-up tells the viewer the screen is locked so it can offer the prompt"
        )

        let unlockedFixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: false),
            unlocker: RecordingUnlocker(outcome: .unlocked)
        )
        let writtenUnlocked = await admitHostScreen(unlockedFixture)
        expect(
            writtenUnlocked.contains(.hostScreenLockState(locked: false)),
            "host-screen bring-up on an unlocked screen tells the viewer so, so it offers no prompt"
        )

        print("PASS: host-screen bring-up announces the current lock state to the viewer")
    }

    // not-authorized dispatch: no live host-screen session
    do {
        let unlocker = RecordingUnlocker(outcome: .unlocked)
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: unlocker
        )
        let log = MessageLog()
        _ = try! await fixture.coordinator.handleWritingResponse(
            .hostScreenUnlockRequest(password: Data("pw".utf8)),
            onWrite: { log.append($0) }
        )
        let written = log.all
        expect(written.contains(.hostScreenUnlockResult(.notAuthorized)), "an unlock with no host-screen session is refused as not authorized")
        expect(!unlocker.wasCalled, "a not-authorized unlock never reaches the typer")

        print("PASS: an unlock request with no live host-screen session is refused as not authorized and never types")
    }

    // not-locked dispatch: authorized but the screen is not locked
    do {
        let unlocker = RecordingUnlocker(outcome: .unlocked)
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: false),
            unlocker: unlocker
        )
        _ = await admitHostScreen(fixture)
        await armUnlock(fixture.coordinator)
        let log = MessageLog()
        _ = try! await fixture.coordinator.handleWritingResponse(
            .hostScreenUnlockRequest(password: Data("pw".utf8)),
            onWrite: { log.append($0) }
        )
        let written = log.all
        expect(written.contains(.hostScreenUnlockResult(.notLocked)), "an unlock of a screen that is not locked reports notLocked")
        expect(!unlocker.wasCalled, "a not-locked unlock never reaches the typer")

        print("PASS: an authorized unlock of an already-unlocked screen reports notLocked and never types")
    }

    // wrong-password and unlocked dispatch: authorized and locked, outcome from the typer
    do {
        for outcome in [HostScreenUnlockOutcome.wrongPassword, .unlocked] {
            let unlocker = RecordingUnlocker(outcome: outcome)
            let fixture = makeUnlockFixture(
                authenticate: true,
                lockStateReader: FakeScreenLockState(locked: true),
                unlocker: unlocker
            )
            _ = await admitHostScreen(fixture)
            await armUnlock(fixture.coordinator)
            let log = MessageLog()
            _ = try! await fixture.coordinator.handleWritingResponse(
                .hostScreenUnlockRequest(password: Data("pw".utf8)),
                onWrite: { log.append($0) }
            )
            let written = log.all
            expect(unlocker.wasCalled, "an authorized, locked unlock reaches the typer")
            expect(written.contains(.hostScreenUnlockResult(outcome)), "the typer's \(outcome) outcome is sent back to the viewer")
            expect(
                written.contains { if case .hostScreenLockState = $0 { return true }; return false },
                "an updated lock state follows every unlock attempt"
            )
        }

        print("PASS: an authorized, locked unlock runs the typer and returns its outcome plus an updated lock state")
    }

    // Operator record: one line per attempt, the outcome token only
    do {
        let events = DiagnosticsRecorder()
        let unlocker = RecordingUnlocker(outcome: .wrongPassword)
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: unlocker,
            onEvent: { events.record($0) }
        )
        _ = await admitHostScreen(fixture)
        await armUnlock(fixture.coordinator)
        let typedText = "correct-horse-battery-staple"
        _ = try! await fixture.coordinator.handleWritingResponse(
            .hostScreenUnlockRequest(password: Data(typedText.utf8)),
            onWrite: { _ in }
        )
        let attemptLines = events.messages.filter { $0.hasPrefix("host-screen unlock attempt:") }
        expect(
            attemptLines == ["host-screen unlock attempt: wrong-password"],
            "one attempt leaves one line naming the outcome token -- got: \(attemptLines)"
        )
        let line = attemptLines.first ?? ""
        expect(!line.contains(typedText), "the attempt line never carries the password -- got: \(line)")
        expect(
            !line.contains(where: \.isNumber),
            "and never a digit, so it cannot leak the password's length -- got: \(line)"
        )
        print("PASS: an unlock attempt leaves the operator one line naming its outcome, never the password")
    }

    // Device budget: repeated wrong-password attempts are capped, and the
    // attempt past the cap reports tooManyAttempts, distinct from notAuthorized
    do {
        let unlocker = RecordingUnlocker(outcome: .wrongPassword)
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: unlocker
        )
        _ = await admitHostScreen(fixture)

        let cap = HostScreenUnlockThrottle.maximumUnlockFailures
        var lastOutcome: HostScreenUnlockOutcome?
        for _ in 0..<(cap + 1) {
            lastOutcome = await unlockOutcome(fixture, password: "pw")
        }
        expect(lastOutcome == .tooManyAttempts, "the attempt past the device unlock-failure cap reports tooManyAttempts, not notAuthorized")
        expect(unlocker.callCount == cap, "the unlocker is never invoked once the device failure cap is reached")

        print("PASS: repeated wrong-password unlock attempts are capped at the device budget, and the attempt past the cap reports tooManyAttempts without typing")
    }

    // One budget is shared across two connections of the same device, so wrong
    // guesses split across reconnects still exhaust at the cap total
    do {
        let identity = try! DeviceIdentity.generate()
        let throttle = HostScreenUnlockThrottle()
        let cap = HostScreenUnlockThrottle.maximumUnlockFailures

        // First connection spends cap-1 wrong guesses, then hangs up.
        let first = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword),
            identity: identity,
            throttle: throttle
        )
        _ = await admitHostScreen(first)
        for _ in 0..<(cap - 1) {
            _ = await unlockOutcome(first, password: "pw")
        }

        // A fresh connection for the same device inherits the spent budget: it
        // gets one more guess, and the one after that is refused as
        // tooManyAttempts -- never a fresh five.
        let secondUnlocker = RecordingUnlocker(outcome: .wrongPassword)
        let second = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: secondUnlocker,
            identity: identity,
            throttle: throttle
        )
        _ = await admitHostScreen(second)
        expect(await unlockOutcome(second, password: "pw") == .wrongPassword, "the reconnect gets the last shared guess, not a fresh budget")
        expect(await unlockOutcome(second, password: "pw") == .tooManyAttempts, "the guess past the shared cap is refused even on a fresh connection")
        expect(secondUnlocker.callCount == 1, "the reconnect's typer runs only for the one guess the shared budget still allowed")

        print("PASS: the unlock budget is shared across reconnects of one device, so wrong guesses split across connections exhaust at the cap total, not per connection")
    }

    // A different device or a re-armed record gets its own budget
    do {
        let throttle = HostScreenUnlockThrottle()
        let cap = HostScreenUnlockThrottle.maximumUnlockFailures

        let one = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword),
            throttle: throttle
        )
        _ = await admitHostScreen(one)
        for _ in 0..<cap { _ = await unlockOutcome(one, password: "pw") }
        expect(await unlockOutcome(one, password: "pw") == .tooManyAttempts, "the first device is out of guesses")

        let otherUnlocker = RecordingUnlocker(outcome: .wrongPassword)
        let other = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: otherUnlocker,
            throttle: throttle
        )
        _ = await admitHostScreen(other)
        expect(await unlockOutcome(other, password: "pw") == .wrongPassword, "a different device has its own budget, untouched by the first")
        expect(otherUnlocker.wasCalled, "the second device's typer runs -- its budget is fresh")

        print("PASS: the shared budget is per device and arming record, so one device exhausting it does not spend another's")
    }

    // Charge accounting under the reserve model: only a confirmed wrong
    // password keeps its reserved slot; every other completed outcome, `.failed`
    // included, refunds; a success resets the whole budget.
    do {
        let cap = HostScreenUnlockThrottle.maximumUnlockFailures

        // failed now REFUNDS: it is reachable only after authenticate already
        // accepted the real password, so it carries no wrong-guess information
        // and must not consume budget. A run of failed attempts never exhausts
        // the budget, and every one reaches the typer.
        let throttle = HostScreenUnlockThrottle()
        let failedIdentity = try! DeviceIdentity.generate()
        let failedFingerprint = unlockTestFingerprint(deviceKey: failedIdentity.publicKey)
        let failedUnlocker = RecordingUnlocker(outcome: .failed(reason: "still locked after typing"))
        let failedFixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: failedUnlocker,
            identity: failedIdentity,
            throttle: throttle
        )
        _ = await admitHostScreen(failedFixture)
        _ = await unlockOutcome(failedFixture, password: "pw")
        expect(
            throttle.failureCount(devicePublicKey: failedIdentity.publicKey, armingFingerprint: failedFingerprint) == 0,
            "a failed outcome refunds its reserved slot, leaving the budget unchanged"
        )
        for _ in 0..<(cap + 1) { _ = await unlockOutcome(failedFixture, password: "pw") }
        expect(failedUnlocker.callCount == cap + 2, "a failed outcome refunds every time, so no failed attempt is ever refused as tooManyAttempts")

        // An unreachable screen-sharing service typed no password, so its slot
        // is refunded every time and the budget is never spent -- every attempt
        // reaches the typer, none is refused as tooManyAttempts.
        let unavailableUnlocker = RecordingUnlocker(outcome: .screenSharingUnavailable)
        let unavailableFixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: unavailableUnlocker
        )
        _ = await admitHostScreen(unavailableFixture)
        for _ in 0..<(cap + 2) { _ = await unlockOutcome(unavailableFixture, password: "pw") }
        expect(unavailableUnlocker.callCount == cap + 2, "an unreachable service refunds its slot every time, so no attempt is ever refused as tooManyAttempts")

        // A success resets: wrong guesses then a success clear the budget, so a
        // full fresh cap of guesses is available afterward.
        let flip = ResettableUnlocker()
        let resetFixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: flip
        )
        _ = await admitHostScreen(resetFixture)
        flip.outcome = .wrongPassword
        for _ in 0..<(cap - 1) { _ = await unlockOutcome(resetFixture, password: "pw") }
        flip.outcome = .unlocked
        expect(await unlockOutcome(resetFixture, password: "pw") == .unlocked, "the successful unlock is reported")
        flip.outcome = .wrongPassword
        var reachedAfterReset = 0
        for _ in 0..<cap where await unlockOutcome(resetFixture, password: "pw") == .wrongPassword {
            reachedAfterReset += 1
        }
        expect(reachedAfterReset == cap, "a successful unlock reset the budget to a full cap of fresh guesses")

        print("PASS: only a confirmed wrong password keeps its charge; failed and outcomes that typed nothing refund, and a successful unlock resets the budget")
    }

    // An unlock request from a connection with no earned session learns no lock
    // state
    do {
        let unlocker = RecordingUnlocker(outcome: .unlocked)
        let unauthenticated = makeUnlockFixture(
            authenticate: false,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: unlocker
        )
        let log = MessageLog()
        _ = try! await unauthenticated.coordinator.handleWritingResponse(
            .hostScreenUnlockRequest(password: Data("pw".utf8)),
            onWrite: { log.append($0) }
        )
        let written = log.all
        expect(written.contains(.hostScreenUnlockResult(.notAuthorized)), "an unearned unlock is refused as not authorized")
        expect(
            !written.contains { if case .hostScreenLockState = $0 { return true }; return false },
            "an unearned unlock request learns nothing about whether the host is locked"
        )
        expect(!unlocker.wasCalled, "and never reaches the typer")

        print("PASS: an unlock request from a connection with no host-screen session is refused and told no lock state")
    }

    // An empty password is refused without typing or charging
    do {
        let unlocker = RecordingUnlocker(outcome: .unlocked)
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: unlocker
        )
        _ = await admitHostScreen(fixture)
        expect(await unlockOutcome(fixture, password: "") == .wrongPassword, "an empty password reports wrongPassword")
        expect(!unlocker.wasCalled, "an empty password never opens the loopback channel")
        // Prove the count is truly unmoved: a full run of empty submits still
        // leaves a real guess able to reach the typer.
        for _ in 0..<(HostScreenUnlockThrottle.maximumUnlockFailures + 1) {
            _ = await unlockOutcome(fixture, password: "")
        }
        _ = await unlockOutcome(fixture, password: "pw")
        expect(unlocker.wasCalled, "empty submits do not spend the budget, so a real guess still types")

        print("PASS: an empty password is refused as wrongPassword without typing and without spending the budget")
    }

    // Many connections of one device racing past the reserve, against one
    // shared budget, must let at most the cap reach the typer. Each connection is armed once up front -- an arm is per-connection
    // and single-use, so the race that matters is between the reserves, not the
    // arms. The fake unlocker parks every caller at a barrier that opens only
    // once the cap have entered, so all callers interleave past the reserve
    // before any completes -- exactly the window a check and a later charge on
    // opposite sides of the attempt would leave open.
    do {
        let cap = HostScreenUnlockThrottle.maximumUnlockFailures
        let connections = cap + 3
        let identity = try! DeviceIdentity.generate()
        let throttle = HostScreenUnlockThrottle()
        let barrier = ConcurrencyBarrier(openAt: cap)
        let unlocker = BarrierUnlocker(barrier: barrier, outcome: .wrongPassword)

        var coordinators: [HostSessionCoordinator] = []
        for _ in 0..<connections {
            let fixture = makeUnlockFixture(
                authenticate: true,
                lockStateReader: FakeScreenLockState(locked: true),
                unlocker: unlocker,
                identity: identity,
                throttle: throttle
            )
            _ = await admitHostScreen(fixture)
            await armUnlock(fixture.coordinator)
            coordinators.append(fixture.coordinator)
        }

        var tasks: [Task<HostScreenUnlockOutcome?, Never>] = []
        for coordinator in coordinators {
            tasks.append(Task { @MainActor in await rawUnlockOutcome(coordinator, password: "pw") })
        }
        var outcomes: [HostScreenUnlockOutcome?] = []
        for task in tasks { outcomes.append(await task.value) }

        expect(unlocker.enteredCount == cap, "exactly the cap of concurrent attempts reach the typer, never more -- got \(unlocker.enteredCount)")
        let refused = outcomes.filter { $0 == .tooManyAttempts }.count
        expect(refused == connections - cap, "every attempt past the cap is refused as tooManyAttempts -- got \(refused)")

        print("PASS: concurrent unlock attempts sharing one budget let at most the cap reach the typer, and refuse the rest as tooManyAttempts")
    }

    // Refund on abandon: an attempt cancelled while the unlocker is still
    // parked releases its reserved slot, so a device that loses a connection
    // mid-unlock is not permanently charged for a guess it never completed.
    do {
        let throttle = HostScreenUnlockThrottle()
        let identity = try! DeviceIdentity.generate()
        let fingerprint = unlockTestFingerprint(deviceKey: identity.publicKey)
        let parked = ParkingUnlocker(outcomeOnResume: .screenSharingUnavailable)
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: parked,
            identity: identity,
            throttle: throttle
        )
        _ = await admitHostScreen(fixture)
        let coordinator = fixture.coordinator

        let attempt = Task { @MainActor in await unlockOutcome(coordinator, password: "pw") }
        _ = await waitUntil(timeoutSeconds: 2) { parked.isParked }
        expect(
            throttle.failureCount(devicePublicKey: identity.publicKey, armingFingerprint: fingerprint) == 1,
            "the parked attempt has reserved exactly one slot"
        )
        attempt.cancel()
        _ = await attempt.value
        expect(
            throttle.failureCount(devicePublicKey: identity.publicKey, armingFingerprint: fingerprint) == 0,
            "cancelling the attempt mid-unlock refunds its reserved slot"
        )

        print("PASS: an attempt cancelled mid-unlock refunds its reserved slot")
    }

    // Refund targets the key captured at reserve, not a live re-read of the
    // surface: a surface torn down mid-attempt still releases its own slot.
    do {
        let throttle = HostScreenUnlockThrottle()
        let identity = try! DeviceIdentity.generate()
        let fingerprint = unlockTestFingerprint(deviceKey: identity.publicKey)
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword),
            identity: identity,
            throttle: throttle
        )
        _ = await admitHostScreen(fixture)
        let reservation = fixture.controller.tryReserveUnlockAttempt()
        expect(reservation != nil, "the live session reserves a slot")
        expect(
            throttle.failureCount(devicePublicKey: identity.publicKey, armingFingerprint: fingerprint) == 1,
            "the reservation charged one slot"
        )
        // The host tears the surface down while the attempt is still in flight.
        _ = try! fixture.controller.handle(.goodbye(reason: GoodbyeReason.stoppedByHost))
        if let reservation { fixture.controller.refund(reservation) }
        expect(
            throttle.failureCount(devicePublicKey: identity.publicKey, armingFingerprint: fingerprint) == 0,
            "refund releases the captured key's slot even after the surface is gone"
        )
        print("PASS: a refund after the surface is torn down still releases the slot it reserved")
    }

    // Refund targets the captured key even when the surface is re-armed with a
    // new fingerprint mid-attempt: the wrong key is never decremented.
    do {
        let throttle = HostScreenUnlockThrottle()
        let identity = try! DeviceIdentity.generate()
        var armedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let armingProvider: () -> HostScreenArming = {
            HostScreenArming(devices: [
                HostScreenDeviceArming(
                    devicePublicKey: identity.publicKey,
                    deviceName: "Kestrel MacBook Pro",
                    minimumCredentialStrength: .hardwareBound,
                    armedAt: armedAt
                )
            ])
        }
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword),
            identity: identity,
            throttle: throttle,
            armingProvider: armingProvider
        )
        _ = await admitHostScreen(fixture)
        let fingerprintA = HostScreenArmingFingerprint(armingProvider().devices[0])
        let reservation = fixture.controller.tryReserveUnlockAttempt()
        expect(reservation != nil, "the live session reserves a slot under the first arming fingerprint")

        // The operator re-arms mid-attempt: tear the surface down, bump the
        // arming record's armedAt, re-admit -- the new surface carries a new
        // fingerprint.
        _ = try! fixture.controller.handle(.goodbye(reason: GoodbyeReason.stoppedByHost))
        armedAt = armedAt.addingTimeInterval(60)
        _ = await admitHostScreen(fixture)
        let fingerprintB = HostScreenArmingFingerprint(armingProvider().devices[0])
        expect(fingerprintA != fingerprintB, "re-arming produced a new fingerprint")

        if let reservation { fixture.controller.refund(reservation) }
        expect(
            throttle.failureCount(devicePublicKey: identity.publicKey, armingFingerprint: fingerprintA) == 0,
            "refund decremented the captured key, not the re-armed one"
        )
        expect(
            throttle.failureCount(devicePublicKey: identity.publicKey, armingFingerprint: fingerprintB) == 0,
            "and the re-armed key was never charged, so it is untouched"
        )
        print("PASS: a refund after a mid-attempt re-arm decrements the captured key, never the new one")
    }

    // An unlock with no fresh arm is refused as presenceRequired,
    // spending no budget and never reaching the typer -- the resume-ticket hole
    // where a password could be typed with nobody confirming at the viewer.
    do {
        let throttle = HostScreenUnlockThrottle()
        let identity = try! DeviceIdentity.generate()
        let fingerprint = unlockTestFingerprint(deviceKey: identity.publicKey)
        let unlocker = RecordingUnlocker(outcome: .wrongPassword)
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: unlocker,
            identity: identity,
            throttle: throttle
        )
        _ = await admitHostScreen(fixture)
        expect(await rawUnlockOutcome(fixture.coordinator, password: "pw") == .presenceRequired, "an unlock with no fresh arm is refused as presenceRequired")
        expect(!unlocker.wasCalled, "and never reaches the typer")
        expect(
            throttle.failureCount(devicePublicKey: identity.publicKey, armingFingerprint: fingerprint) == 0,
            "and spends no guess budget"
        )
        print("PASS: an unlock with no fresh presence arm is refused as presenceRequired, without typing or spending the budget")
    }

    // One arm authorises exactly one attempt -- the next needs a fresh
    // presence proof of its own.
    do {
        let unlocker = RecordingUnlocker(outcome: .wrongPassword)
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: unlocker
        )
        _ = await admitHostScreen(fixture)
        await armUnlock(fixture.coordinator)
        expect(await rawUnlockOutcome(fixture.coordinator, password: "pw") == .wrongPassword, "the armed attempt runs and reports the typer's outcome")
        expect(await rawUnlockOutcome(fixture.coordinator, password: "pw") == .presenceRequired, "the very next attempt, unarmed again, is refused as presenceRequired")
        expect(unlocker.callCount == 1, "only the one armed attempt reached the typer")
        print("PASS: a single arm authorises exactly one unlock attempt; the next needs a fresh presence proof")
    }

    // An arm with no prior challenge fails, and a challenge is consumed
    // on arm so it cannot be reused -- a captured arm is not replayable.
    do {
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword)
        )
        _ = await admitHostScreen(fixture)

        // An arm with no challenge minted first leaves the connection unarmed.
        expect(
            !fixture.controller.armUnlock(presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))),
            "an arm with no prior challenge does not arm"
        )
        expect(await rawUnlockOutcome(fixture.coordinator, password: "pw") == .presenceRequired, "so the unlock is still refused as presenceRequired")

        // Mint one challenge, arm it (consuming it), then a second arm reusing
        // the now-spent challenge fails: the challenge is strictly single-use.
        let challenge = fixture.controller.mintUnlockChallenge()
        expect(challenge != nil, "a valid session mints a challenge")
        expect(
            fixture.controller.armUnlock(presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))),
            "the first arm over that challenge succeeds"
        )
        expect(
            !fixture.controller.armUnlock(presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))),
            "a second arm reusing the already-consumed challenge fails"
        )
        // The first arm consumed the challenge but did arm exactly one attempt.
        expect(await rawUnlockOutcome(fixture.coordinator, password: "pw") == .wrongPassword, "the one arm the challenge authorised still runs its single attempt")
        print("PASS: an arm needs a prior challenge, and a challenge is single-use -- a captured arm cannot be replayed")
    }

    // An unlock challenge expires. An arm over a challenge minted more
    // than its lifetime ago is consumed and refused without verifying; one
    // within the lifetime still arms.
    do {
        let clock = MutableSeconds(1000)
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword),
            unlockChallengeNowSeconds: { clock.value }
        )
        _ = await admitHostScreen(fixture)

        _ = fixture.controller.mintUnlockChallenge()
        clock.value += HostSessionController.unlockChallengeTimeToLiveSeconds + 1
        expect(
            !fixture.controller.armUnlock(presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))),
            "an arm over a challenge older than its lifetime does not arm"
        )
        expect(
            await rawUnlockOutcome(fixture.coordinator, password: "pw") == .presenceRequired,
            "so the unlock is refused as presenceRequired, the expired challenge already consumed"
        )

        _ = fixture.controller.mintUnlockChallenge()
        clock.value += HostSessionController.unlockChallengeTimeToLiveSeconds - 1
        expect(
            fixture.controller.armUnlock(presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))),
            "an arm over a challenge still within its lifetime arms"
        )
        expect(
            await rawUnlockOutcome(fixture.coordinator, password: "pw") == .wrongPassword,
            "the armed attempt runs"
        )
        print("PASS: an unlock challenge older than its lifetime is consumed and refused; within it, an arm still works")
    }

    // A resume-ticket proof cannot arm an unlock -- only a fresh signed
    // presence proof can, so the resume path never types a password unattended.
    do {
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword)
        )
        _ = await admitHostScreen(fixture)
        _ = fixture.controller.mintUnlockChallenge()
        expect(
            !fixture.controller.armUnlock(presence: .resumeTicket(Data([0x09]))),
            "a resume ticket cannot arm an unlock"
        )
        expect(await rawUnlockOutcome(fixture.coordinator, password: "pw") == .presenceRequired, "so the unlock is still refused as presenceRequired")
        print("PASS: a resume ticket cannot arm an unlock; only a fresh signed presence proof can")
    }

    // The challenge request discloses nothing on an invalid session --
    // no challenge, so a host emitting one cannot become a lock-state oracle.
    do {
        let unauthenticated = makeUnlockFixture(
            authenticate: false,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword)
        )
        expect(unauthenticated.controller.mintUnlockChallenge() == nil, "an unauthenticated connection mints no unlock challenge")
        let reply = try! await unauthenticated.coordinator.handleWritingResponse(.hostScreenUnlockChallengeRequest)
        expect(reply == nil, "and a challenge request over the wire gets no reply at all")

        let authenticatedNoHostScreen = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword)
        )
        expect(authenticatedNoHostScreen.controller.mintUnlockChallenge() == nil, "an authenticated connection with no live host-screen session mints none either")
        print("PASS: an unlock challenge is minted only for a valid live host-screen session, disclosing nothing otherwise")
    }

    // A fresh presence arm never refills the wrong-guess budget, at either
    // registered credential strength. Every guess must arm first, so an arm
    // that reset the budget would make the cap unreachable and turn the login
    // window into an unbounded password oracle. Only a correct password clears
    // it.
    do {
        let cap = HostScreenUnlockThrottle.maximumUnlockFailures
        for strength in [HostScreenCredentialStrength.hardwareBound, .softwarePresence] {
            let throttle = HostScreenUnlockThrottle()
            let identity = try! DeviceIdentity.generate()
            let unlocker = RecordingUnlocker(outcome: .wrongPassword)
            let fixture = makeUnlockFixture(
                authenticate: true,
                lockStateReader: FakeScreenLockState(locked: true),
                unlocker: unlocker,
                identity: identity,
                throttle: throttle,
                strength: strength
            )
            _ = await admitHostScreen(fixture)
            // `unlockOutcome` arms before each submit, which is the production
            // sequence: challenge, arm, guess.
            var outcomes: [HostScreenUnlockOutcome?] = []
            for _ in 0..<(cap + 1) {
                outcomes.append(await unlockOutcome(fixture, password: "pw"))
            }
            expect(
                outcomes.prefix(cap).allSatisfy { $0 == .wrongPassword },
                "\(strength): the first \(cap) armed guesses each report wrongPassword"
            )
            expect(
                outcomes.last == .tooManyAttempts,
                "\(strength): the guess past the cap is refused as tooManyAttempts even though it armed first"
            )
            expect(unlocker.callCount == cap, "\(strength): the typer runs only for the guesses the budget allowed")
        }
        print("PASS: arming before every guess does not refill the unlock budget, at either registered credential strength")
    }
}

/// The outcome the coordinator sends back for one unlock request, or `nil` when
/// it sent none.
@MainActor
private func unlockOutcome(
    _ fixture: (coordinator: HostSessionCoordinator, controller: HostSessionController),
    password: String
) async -> HostScreenUnlockOutcome? {
    await unlockOutcome(fixture.coordinator, password: password)
}

/// A liveness flag a test can flip after the registry has captured its reader,
/// standing in for a session that later drops. A reference type so flipping it
/// does not mutate a value the escaping `isLive` closure already copied.
private final class SessionLiveness: @unchecked Sendable {
    private let lock = NSLock()
    private var live: Bool
    init(_ live: Bool) { self.live = live }
    var isLive: Bool { lock.lock(); defer { lock.unlock() }; return live }
    func set(_ value: Bool) { lock.lock(); live = value; lock.unlock() }
}

/// How one host-screen admission resolved: streaming, or refused with a reason.
private enum HostScreenAdmissionResult: Equatable {
    case admitted
    case refused(reason: String)
}

/// Drives one host-screen request through the coordinator and reports whether it
/// was admitted (a `hostScreenReady` written) or refused (a `hostScreenRefused`
/// returned), so a Part B test can assert the one-live-session rule on the same
/// path production uses.
@MainActor
private func admitHostScreenResult(
    _ fixture: (coordinator: HostSessionCoordinator, controller: HostSessionController)
) async -> HostScreenAdmissionResult {
    guard case let .hostScreenList(displays, _) = try! fixture.controller.offerHostScreenList(),
          let token = displays.first?.opaqueToken else {
        expect(false, "the fixture offers at least one display")
        return .refused(reason: "no-display")
    }
    let log = MessageLog()
    let reply = try! await fixture.coordinator.handleWritingResponse(
        .hostScreenRequest(
            token: token,
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        ),
        onWrite: { log.append($0) }
    )
    if case let .hostScreenRefused(reason) = reply {
        return .refused(reason: reason)
    }
    if log.all.contains(where: { if case .hostScreenReady = $0 { return true }; return false }) {
        return .admitted
    }
    return .refused(reason: "no-reply")
}

@MainActor
func runHostScreenLiveSessionTests() async {
    // The registry itself, deterministically: a live entry blocks a second
    // admit for the same device, a stale one (its session no longer live) is
    // evicted and the new session admitted, and a release only ever removes the
    // exact session it was minted for.
    do {
        let registry = HostScreenLiveSessionRegistry()
        let deviceA = Data([0xA1, 0xA2])
        let deviceB = Data([0xB1, 0xB2])

        let aLive = SessionLiveness(true)
        let claimA = registry.admit(devicePublicKey: deviceA) { aLive.isLive }
        expect(claimA != nil, "a first host-screen session for a device is admitted")
        expect(registry.admit(devicePublicKey: deviceA, isLive: { true }) == nil, "a second concurrent session for the same device is refused")
        expect(registry.admit(devicePublicKey: deviceB, isLive: { true }) != nil, "a different device is unaffected and admits")

        // The first session dies without releasing (a dropped connection). The
        // next admit sees the entry is no longer live, evicts it, and admits.
        aLive.set(false)
        let claimAAgain = registry.admit(devicePublicKey: deviceA) { true }
        expect(claimAAgain != nil, "a stale entry whose session is no longer live does not block a fresh admit")

        // A late release of the old, already-evicted claim must not evict the
        // new live session that replaced it.
        if let claimA { registry.release(claimA) }
        expect(registry.admit(devicePublicKey: deviceA, isLive: { true }) == nil, "releasing a stale claim never evicts the newer live session that replaced it")

        print("PASS: the live-session registry blocks a second concurrent session per device, self-heals a stale entry, and releases only the captured session")
    }

    // Through the real admission path: a second connection for a device already
    // streaming a host screen is refused with its own distinct reason -- not a
    // tooManyAttempts and not an unlock outcome. A different device is admitted.
    do {
        let registry = HostScreenLiveSessionRegistry()
        let identity = try! DeviceIdentity.generate()

        let first = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword),
            identity: identity,
            liveSessionRegistry: registry
        )
        expect(await admitHostScreenResult(first) == .admitted, "the first host-screen session for a device is admitted")

        let second = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword),
            identity: identity,
            liveSessionRegistry: registry
        )
        expect(
            await admitHostScreenResult(second) == .refused(reason: "host-screen-already-live"),
            "a second concurrent host-screen session for the same device is refused with its own distinct reason"
        )

        let otherDevice = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword),
            liveSessionRegistry: registry
        )
        expect(await admitHostScreenResult(otherDevice) == .admitted, "a different device is admitted while the first holds its one live session")

        print("PASS: a second concurrent host-screen session per device is refused distinctly, and a different device is unaffected")
    }

    // Teardown releases the device's entry, so the same device can start a fresh
    // session afterward -- and releases only the captured session's entry.
    do {
        let registry = HostScreenLiveSessionRegistry()
        let identity = try! DeviceIdentity.generate()

        let first = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword),
            identity: identity,
            liveSessionRegistry: registry
        )
        expect(await admitHostScreenResult(first) == .admitted, "the first session is admitted")
        _ = try! first.controller.handle(.goodbye(reason: "client-disconnected"))

        let again = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: true),
            unlocker: RecordingUnlocker(outcome: .wrongPassword),
            identity: identity,
            liveSessionRegistry: registry
        )
        expect(await admitHostScreenResult(again) == .admitted, "after the first session's teardown releases its entry, the same device admits a fresh session")

        print("PASS: a host-screen session teardown releases its device's live-session entry, so the device can start again")
    }

    // An admission whose injector construction fails releases the
    // live-session claim it took, so a leaked entry never holds the device busy.
    do {
        let registry = ReleaseCountingRegistry(HostScreenLiveSessionRegistry())
        let fixture = makeUnlockFixture(
            authenticate: true,
            lockStateReader: FakeScreenLockState(locked: false),
            unlocker: RecordingUnlocker(outcome: .unlocked),
            liveSessionRegistry: registry,
            inputInjectorFactory: ThrowingInputInjectorFactory()
        )
        guard case let .hostScreenList(displays, _) = try! fixture.controller.offerHostScreenList(),
              let token = displays.first?.opaqueToken else {
            expect(false, "the fixture offers at least one display")
            return
        }
        var threw = false
        do {
            _ = try await fixture.coordinator.handleWritingResponse(
                .hostScreenRequest(
                    token: token,
                    presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
                ),
                onWrite: { _ in }
            )
        } catch {
            threw = true
        }
        expect(threw, "an injector that fails to build fails the admission")
        expect(registry.releaseCount == 1, "the failed admission gives its live-session claim back deterministically")
        print("PASS: an admission whose injector fails to build releases the live-session claim it took")
    }
}

/// An injector factory whose build always fails, to exercise the admission's
/// own release-on-failure path.
private struct InjectorBuildFailure: Error {}
private final class ThrowingInputInjectorFactory: InputInjectingFactory {
    func make(canvasDisplayID: UInt32) throws -> any InputInjecting {
        throw InjectorBuildFailure()
    }
}

/// Wraps the real registry and counts `release` calls, so a test can assert a
/// claim was given back rather than left to self-heal on the next admission.
@MainActor
private final class ReleaseCountingRegistry: HostScreenLiveSessionRegistering {
    private let inner: HostScreenLiveSessionRegistry
    private(set) var releaseCount = 0
    init(_ inner: HostScreenLiveSessionRegistry) { self.inner = inner }
    func admit(devicePublicKey: Data, isLive: @escaping @MainActor () -> Bool) -> HostScreenLiveSessionClaim? {
        inner.admit(devicePublicKey: devicePublicKey, isLive: isLive)
    }
    func release(_ claim: HostScreenLiveSessionClaim) {
        releaseCount += 1
        inner.release(claim)
    }
}

/// Arms one unlock attempt through the production path: asks for a challenge
/// and returns a signed presence proof for it. The fixture's verifier accepts
/// any signature, so the exact bytes do not matter here -- what is exercised is
/// the challenge/arm handshake and its single-use consumption, not the
/// signature check, which is the presence verifier's own test.
@MainActor
private func armUnlock(_ coordinator: HostSessionCoordinator) async {
    let reply = try! await coordinator.handleWritingResponse(.hostScreenUnlockChallengeRequest)
    guard case .hostScreenUnlockChallenge = reply else {
        expect(false, "a valid host-screen session mints an unlock challenge on request")
        return
    }
    _ = try! await coordinator.handleWritingResponse(
        .hostScreenUnlockArm(
            presence: .signed(credentialID: Data([0x01]), credentialFormat: "apple-secure-enclave-p256", signature: Data([0x02]))
        )
    )
}

/// One unlock request as the wire delivers it, with no arm of its own -- for the
/// tests that arm deliberately (or deliberately do not) and drive the request
/// themselves.
@MainActor
private func rawUnlockOutcome(
    _ coordinator: HostSessionCoordinator,
    password: String
) async -> HostScreenUnlockOutcome? {
    let log = MessageLog()
    _ = try! await coordinator.handleWritingResponse(
        .hostScreenUnlockRequest(password: Data(password.utf8)),
        onWrite: { log.append($0) }
    )
    return log.all.compactMap { message -> HostScreenUnlockOutcome? in
        if case let .hostScreenUnlockResult(outcome) = message { return outcome }
        return nil
    }.first
}

/// A freshly armed unlock attempt: every unlock now needs a single-use presence
/// arm, so the common helper arms and then submits, one arm per attempt.
@MainActor
private func unlockOutcome(
    _ coordinator: HostSessionCoordinator,
    password: String
) async -> HostScreenUnlockOutcome? {
    await armUnlock(coordinator)
    return await rawUnlockOutcome(coordinator, password: password)
}

/// An unlocker whose next outcome a test can flip between calls -- to run a
/// stretch of wrong guesses and then a success against one live session.
private final class ResettableUnlocker: LockScreenUnlocking, @unchecked Sendable {
    private let lock = NSLock()
    private var next: HostScreenUnlockOutcome = .wrongPassword
    var outcome: HostScreenUnlockOutcome {
        get { lock.lock(); defer { lock.unlock() }; return next }
        set { lock.lock(); next = newValue; lock.unlock() }
    }
    func unlock(password: Data) async -> HostScreenUnlockOutcome { outcome }
}

/// The throttle key `makeUnlockFixture` forms for a device, so a test that
/// injects its own throttle can read the count that fixture will charge.
@MainActor
private func unlockTestFingerprint(deviceKey: Data) -> HostScreenArmingFingerprint {
    HostScreenArmingFingerprint(unlockTestArming(deviceKey: deviceKey).devices[0])
}

/// Holds every caller inside `unlock` until `openAt` of them have arrived, then
/// releases them all at once. This is what forces concurrent unlock attempts to
/// interleave past the atomic reserve before any completes -- the exact
/// condition under which a non-atomic check-then-charge would let more than the
/// cap through.
private actor ConcurrencyBarrier {
    private let openAt: Int
    private var arrived = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(openAt: Int) { self.openAt = openAt }

    func arrive() async {
        arrived += 1
        if arrived >= openAt {
            let toResume = waiters
            waiters = []
            for waiter in toResume { waiter.resume() }
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }
}

/// An unlocker that counts how many callers reached it and parks each at a
/// shared barrier, so a test can assert that no more than the cap ever got past
/// the reserve.
private final class BarrierUnlocker: LockScreenUnlocking, @unchecked Sendable {
    private let barrier: ConcurrencyBarrier
    private let outcome: HostScreenUnlockOutcome
    private let lock = NSLock()
    private var entered = 0

    init(barrier: ConcurrencyBarrier, outcome: HostScreenUnlockOutcome) {
        self.barrier = barrier
        self.outcome = outcome
    }

    var enteredCount: Int { lock.lock(); defer { lock.unlock() }; return entered }

    private func recordEntry() { lock.lock(); entered += 1; lock.unlock() }

    func unlock(password: Data) async -> HostScreenUnlockOutcome {
        recordEntry()
        await barrier.arrive()
        return outcome
    }
}

/// An unlocker that parks its caller until the surrounding task is cancelled,
/// then returns `outcomeOnResume`. Lets a test cancel an attempt while it is
/// mid-unlock and observe that its reserved slot is refunded.
private final class ParkingUnlocker: LockScreenUnlocking, @unchecked Sendable {
    private let outcomeOnResume: HostScreenUnlockOutcome
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HostScreenUnlockOutcome, Never>?
    private var cancelled = false
    private var parked = false

    init(outcomeOnResume: HostScreenUnlockOutcome) { self.outcomeOnResume = outcomeOnResume }

    var isParked: Bool { lock.lock(); defer { lock.unlock() }; return parked }

    func unlock(password: Data) async -> HostScreenUnlockOutcome {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<HostScreenUnlockOutcome, Never>) in
                lock.lock()
                if cancelled {
                    lock.unlock()
                    cont.resume(returning: outcomeOnResume)
                } else {
                    continuation = cont
                    parked = true
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            cancelled = true
            let cont = continuation
            continuation = nil
            parked = false
            lock.unlock()
            cont?.resume(returning: outcomeOnResume)
        }
    }
}

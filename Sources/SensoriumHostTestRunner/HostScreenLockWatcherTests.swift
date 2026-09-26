import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// `HostSessionCoordinator.tickHostScreenLockState()` is the change watcher's
/// whole behavior: a poll loop elsewhere calls it on a timer and writes
/// whatever it returns, so driving it directly here exercises exactly what
/// that loop would see, deterministically and without a real clock.
private final class LockWatcherTestIdleSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

@MainActor
private func lockWatcherTestDisplay() -> DisplaySnapshot {
    DisplaySnapshot(
        id: 9,
        pixelWidth: 2560,
        pixelHeight: 1440,
        modeWidth: 1280,
        modeHeight: 720,
        modePixelWidth: 2560,
        modePixelHeight: 1440,
        bounds: CGRect(x: 0, y: 0, width: 1280, height: 720),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

private final class LockWatcherTestUnlocker: LockScreenUnlocking, @unchecked Sendable {
    let outcome: HostScreenUnlockOutcome
    init(outcome: HostScreenUnlockOutcome) { self.outcome = outcome }
    func unlock(password: Data) async -> HostScreenUnlockOutcome { outcome }
}

/// Parks its caller mid-`unlock` until a test calls `resume()`, so a test can
/// hold the coordinator suspended inside its own `await unlock(password:)`
/// long enough to fire a tick from outside and observe what it does while
/// the attempt is still in flight.
private final class ParkingLockWatcherUnlocker: LockScreenUnlocking, @unchecked Sendable {
    private let outcomeOnResume: HostScreenUnlockOutcome
    private let lock = NSLock()
    private var continuation: CheckedContinuation<HostScreenUnlockOutcome, Never>?
    private var parked = false

    init(outcomeOnResume: HostScreenUnlockOutcome) { self.outcomeOnResume = outcomeOnResume }

    var isParked: Bool { lock.lock(); defer { lock.unlock() }; return parked }

    func unlock(password: Data) async -> HostScreenUnlockOutcome {
        await withCheckedContinuation { (cont: CheckedContinuation<HostScreenUnlockOutcome, Never>) in
            lock.lock()
            continuation = cont
            parked = true
            lock.unlock()
        }
    }

    func resume() {
        lock.lock()
        let cont = continuation
        continuation = nil
        parked = false
        lock.unlock()
        cont?.resume(returning: outcomeOnResume)
    }
}

/// A controller and coordinator admitted (or not) into a live host-screen
/// session, with an injected, flippable lock reader -- the one seam
/// `tickHostScreenLockState()` reads from.
@MainActor
private func makeLockWatcherFixture(
    lockStateReader: any ScreenLockStateReading,
    unlocker: any LockScreenUnlocking = LockWatcherTestUnlocker(outcome: .unlocked)
) -> (coordinator: HostSessionCoordinator, controller: HostSessionController) {
    let display = lockWatcherTestDisplay()
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        inputInjectorFactory: FakeInputInjectorFactory(),
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: {
            HostScreenArming(devices: [
                HostScreenDeviceArming(
                    devicePublicKey: deviceKey,
                    deviceName: "Lock Watcher Probe",
                    armedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ])
        },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenUnlockThrottle: HostScreenUnlockThrottle(),
        hostScreenLiveSessionRegistry: nil,
        hostScreenPresenceActivitySignal: LockWatcherTestIdleSignal(),
        hostScreenPresenceGate: nil,
        hostScreenModeController: nil
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey,
        hostCertificateHash: nil
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))
    let coordinator = HostSessionCoordinator(
        controller: controller,
        media: CanvasSurfaceSlots { _ in FakeCanvasMedia() },
        videoSink: FakeVideoSink(),
        hostScreenMediaFactory: { _ in FakeScalableCanvasMedia() },
        lockStateReader: lockStateReader,
        lockScreenUnlocker: unlocker
    )
    return (coordinator, controller)
}

@MainActor
private func admitLockWatcherHostScreen(
    _ fixture: (coordinator: HostSessionCoordinator, controller: HostSessionController)
) async {
    guard case let .hostScreenList(displays, _) = try! fixture.controller.offerHostScreenList(),
          let token = displays.first?.opaqueToken else {
        expect(false, "the fixture offers at least one display")
        return
    }
    _ = try! await fixture.coordinator.handleWritingResponse(
        .hostScreenRequest(token: token, resumeTicket: nil),
        onWrite: { _ in }
    )
}

@MainActor
func runHostScreenLockWatcherTests() async {
    // Never sends outside a host-screen session: before admission, a tick
    // reports nothing at all, whatever the lock reader says.
    do {
        let fixture = makeLockWatcherFixture(lockStateReader: FakeScreenLockState(locked: true))
        expect(
            fixture.coordinator.tickHostScreenLockState() == nil,
            "a tick before any host-screen session is admitted reports nothing"
        )
        print("PASS: a lock-state tick outside a host-screen session reports nothing")
    }

    // Bring-up itself already announced the current reading, so the first
    // tick against an unchanged lock state sends nothing: the baseline is
    // seeded by bring-up, not left at nil.
    do {
        let reader = FakeScreenLockState(locked: true)
        let fixture = makeLockWatcherFixture(lockStateReader: reader)
        await admitLockWatcherHostScreen(fixture)
        expect(
            fixture.coordinator.tickHostScreenLockState() == nil,
            "a tick against a lock state bring-up already announced reports nothing"
        )
        print("PASS: a tick right after bring-up, with no real change, reports nothing")
    }

    // Sends on change only: a flip is reported exactly once, and repeating
    // the same reading afterward reports nothing again.
    do {
        let reader = FlippableLockState(locked: true)
        let fixture = makeLockWatcherFixture(lockStateReader: reader)
        await admitLockWatcherHostScreen(fixture)

        reader.setLocked(false)
        expect(
            fixture.coordinator.tickHostScreenLockState() == .hostScreenLockState(locked: false),
            "a tick after the screen unlocks reports the new state"
        )
        expect(
            fixture.coordinator.tickHostScreenLockState() == nil,
            "a second tick against the same, already-reported state reports nothing"
        )

        reader.setLocked(true)
        expect(
            fixture.coordinator.tickHostScreenLockState() == .hostScreenLockState(locked: true),
            "a tick after the screen locks again reports that change too"
        )
        expect(
            fixture.coordinator.tickHostScreenLockState() == nil,
            "and a further tick with no change again reports nothing"
        )
        print("PASS: a lock-state tick reports a real change exactly once and repeats nothing")
    }

    // An unlock attempt's own announcement seeds the same baseline a tick
    // reads, so a tick right after an unlock does not repeat what the unlock
    // reply already told the viewer.
    do {
        let reader = FlippableLockState(locked: true)
        let fixture = makeLockWatcherFixture(
            lockStateReader: reader,
            unlocker: LockWatcherTestUnlocker(outcome: .unlocked)
        )
        await admitLockWatcherHostScreen(fixture)

        // The unlocker's fake outcome does not itself change the reader;
        // flip it the way a real successful unlock would leave the screen.
        reader.setLocked(false)
        _ = try! await fixture.coordinator.handleWritingResponse(
            .hostScreenUnlockRequest(password: Data("pw".utf8)),
            onWrite: { _ in }
        )
        expect(
            fixture.coordinator.tickHostScreenLockState() == nil,
            "a tick right after an unlock attempt does not repeat the state that attempt already announced"
        )
        print("PASS: a lock-state tick after an unlock attempt does not duplicate its announcement")
    }

    // A tick racing an in-flight unlock attempt must never write its own
    // `hostScreenLockState` ahead of that attempt's `hostScreenUnlockResult`:
    // it reports nothing while the attempt is still out, nothing new right
    // after the attempt's own announcement, and only a change after that.
    do {
        let reader = FlippableLockState(locked: true)
        let unlocker = ParkingLockWatcherUnlocker(outcomeOnResume: .unlocked)
        let fixture = makeLockWatcherFixture(lockStateReader: reader, unlocker: unlocker)
        await admitLockWatcherHostScreen(fixture)

        let attempt = Task { @MainActor in
            try! await fixture.coordinator.handleWritingResponse(
                .hostScreenUnlockRequest(password: Data("pw".utf8)),
                onWrite: { _ in }
            )
        }
        _ = await waitUntil(timeoutSeconds: 2) { unlocker.isParked }
        expect(unlocker.isParked, "the attempt is parked mid-unlock before the tick runs")

        // The screen is unlocked for real while the attempt is still out --
        // exactly the moment a racing tick must not report on its own.
        reader.setLocked(false)
        expect(
            fixture.coordinator.tickHostScreenLockState() == nil,
            "a tick during an in-flight unlock attempt reports nothing, even though the reader now says unlocked"
        )

        unlocker.resume()
        _ = await attempt.value

        expect(
            fixture.coordinator.tickHostScreenLockState() == nil,
            "a tick right after the attempt's own announcement reports nothing new"
        )

        reader.setLocked(true)
        expect(
            fixture.coordinator.tickHostScreenLockState() == .hostScreenLockState(locked: true),
            "a real change after the attempt is still reported, exactly once"
        )
        expect(
            fixture.coordinator.tickHostScreenLockState() == nil,
            "and a further tick with no change reports nothing"
        )
        print("PASS: a lock-state tick never races an in-flight unlock attempt's own announcement")
    }

    // Stops at session end: once the host-screen session ends, a tick
    // reports nothing more, even though the lock reader has since changed.
    do {
        let reader = FlippableLockState(locked: true)
        let fixture = makeLockWatcherFixture(lockStateReader: reader)
        await admitLockWatcherHostScreen(fixture)
        _ = try! fixture.controller.handle(.goodbye(reason: GoodbyeReason.stoppedByHost))

        reader.setLocked(false)
        expect(
            fixture.coordinator.tickHostScreenLockState() == nil,
            "a tick after the host-screen session has ended reports nothing, whatever the reader now says"
        )
        print("PASS: a lock-state tick after the host-screen session ends reports nothing")
    }
}

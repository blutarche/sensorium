import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// `HostSessionCoordinator`'s wiring of `HostScreenRelockTracker` and
/// `HostScreenRelocking`: a host-screen session that found the machine
/// unlocked during a lock-then-unlock cycle relocks it when the session
/// ends, and nothing else does.
private final class RecordingRelockPoster: HostScreenRelocking, @unchecked Sendable {
    private(set) var relockCount = 0
    func relock() -> Bool {
        relockCount += 1
        return true
    }
}

private final class RelockWiringTestUnlocker: LockScreenUnlocking, @unchecked Sendable {
    func unlock(password: Data) async -> HostScreenUnlockOutcome { .unlocked }
}

@MainActor
private func relockWiringTestDisplay() -> DisplaySnapshot {
    DisplaySnapshot(
        id: 11,
        pixelWidth: 1920,
        pixelHeight: 1080,
        modeWidth: 960,
        modeHeight: 540,
        modePixelWidth: 1920,
        modePixelHeight: 1080,
        bounds: CGRect(x: 0, y: 0, width: 960, height: 540),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 42
    )
}

@MainActor
private func makeRelockWiringFixture(
    lockStateReader: any ScreenLockStateReading,
    relockPoster: RecordingRelockPoster,
    localActivitySignal: any HostLocalActivitySignal = FlippableLocalActivitySignal()
) -> (coordinator: HostSessionCoordinator, controller: HostSessionController) {
    let display = relockWiringTestDisplay()
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
                    deviceName: "Relock Wiring Probe",
                    armedAt: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ])
        },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenUnlockThrottle: HostScreenUnlockThrottle(),
        hostScreenLiveSessionRegistry: nil,
        hostScreenPresenceActivitySignal: AlwaysIdleRelockWiringSignal(),
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
        lockScreenUnlocker: RelockWiringTestUnlocker(),
        hostScreenRelockPoster: relockPoster,
        hostScreenRelockActivitySignal: localActivitySignal
    )
    return (coordinator, controller)
}

private final class AlwaysIdleRelockWiringSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

/// Starts reading as "nobody home" -- past `HostScreenPresenceRule`'s own
/// threshold -- and can be flipped to "just active" mid-test, the same way
/// `FlippableLockState` stands in for a real lock-state reader.
private final class FlippableLocalActivitySignal: HostLocalActivitySignal, @unchecked Sendable {
    private var reading: HostLocalActivityReading

    init(reading: HostLocalActivityReading = .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)) {
        self.reading = reading
    }

    func currentReading() -> HostLocalActivityReading { reading }

    func setActiveNow() {
        reading = .idleFor(0)
    }

    func setIdle() {
        reading = .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

/// Reports raw idle time as though hardware activity had just happened --
/// standing in for what `hidSystemState` reads right after this host's own
/// forwarded keystroke disturbs it, with no genuinely newer activity behind it.
private final class AlwaysJustActiveRawSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading { .idleFor(0) }
}

/// Reports a fixed, constant time since this host's own last hid-tap post,
/// so a test can line it up exactly against `AlwaysJustActiveRawSignal`'s
/// raw reading without racing a real clock.
private final class FakeRelockWiringHIDActivity: HostInjectedHIDActivity, @unchecked Sendable {
    private let seconds: TimeInterval?
    init(secondsSinceLastPost seconds: TimeInterval?) { self.seconds = seconds }
    func recordPost() {}
    func secondsSinceLastPost() -> TimeInterval? { seconds }
    func sampleBeforePost() {}
    /// No pre-post sample has ever proven genuine hardware activity in this
    /// scenario -- only our own post, which `secondsSinceLastPost` above
    /// stands in for.
    func secondsSinceProvenHardwareActivity() -> TimeInterval? { nil }
}

private enum RelockWiringRealKey {
    case none
    case afterLastForwardedKey
    case betweenForwardedKeys
}

private final class WiringScriptedClock: @unchecked Sendable {
    var time: TimeInterval
    init(time: TimeInterval) { self.time = time }
    func now() -> TimeInterval { time }
}

private final class WiringScriptedRawSignal: HostLocalActivitySignal, @unchecked Sendable {
    var reading: HostLocalActivityReading
    init(reading: HostLocalActivityReading) { self.reading = reading }
    func currentReading() -> HostLocalActivityReading { reading }
}

@MainActor
private func admitRelockWiringHostScreen(
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
func runHostScreenRelockWiringTests() async {
    // A host-screen session that never saw the screen locked ends without relocking.
    do {
        let poster = RecordingRelockPoster()
        let fixture = makeRelockWiringFixture(lockStateReader: FakeScreenLockState(locked: false), relockPoster: poster)
        await admitRelockWiringHostScreen(fixture)
        _ = try! await fixture.coordinator.handleWritingResponse(.goodbye(reason: GoodbyeReason.stoppedByHost))
        expect(poster.relockCount == 0, "a session that never found the screen locked does not relock it")
        print("PASS: a host-screen session that never saw the screen locked ends without relocking")
    }

    // Locked at bring-up, then observed unlocked by a later tick: ending the session relocks.
    do {
        let poster = RecordingRelockPoster()
        let reader = FlippableLockState(locked: true)
        let fixture = makeRelockWiringFixture(lockStateReader: reader, relockPoster: poster)
        await admitRelockWiringHostScreen(fixture)

        reader.setLocked(false)
        expect(
            fixture.coordinator.tickHostScreenLockState() == .hostScreenLockState(locked: false),
            "the tick reports the unlock, and also feeds the relock tracker"
        )

        _ = try! await fixture.coordinator.handleWritingResponse(.goodbye(reason: GoodbyeReason.stoppedByHost))
        expect(poster.relockCount == 1, "a session locked and then found unlocked relocks exactly once at session end")
        print("PASS: a host-screen session locked then found unlocked relocks the machine when it ends")
    }

    // A person at the machine unlocked it themselves: hardware activity is
    // present at the very tick that observes the unlock. Even with nothing
    // active by session end, the transition itself must veto the relock.
    do {
        let poster = RecordingRelockPoster()
        let reader = FlippableLockState(locked: true)
        let activity = FlippableLocalActivitySignal()
        let fixture = makeRelockWiringFixture(lockStateReader: reader, relockPoster: poster, localActivitySignal: activity)
        await admitRelockWiringHostScreen(fixture)

        reader.setLocked(false)
        activity.setActiveNow()
        _ = fixture.coordinator.tickHostScreenLockState()
        activity.setIdle()

        _ = try! await fixture.coordinator.handleWritingResponse(.goodbye(reason: GoodbyeReason.stoppedByHost))
        expect(poster.relockCount == 0, "hardware activity at the unlock itself means a person unlocked the machine")
        print("PASS: a screen a person at the machine unlocked, with nothing local since, is not relocked")
    }

    // A remote unlock, but someone is at the machine using it by the time
    // the session ends: the final, fresh reading at teardown must catch it.
    do {
        let poster = RecordingRelockPoster()
        let reader = FlippableLockState(locked: true)
        let activity = FlippableLocalActivitySignal()
        let fixture = makeRelockWiringFixture(lockStateReader: reader, relockPoster: poster, localActivitySignal: activity)
        await admitRelockWiringHostScreen(fixture)

        reader.setLocked(false)
        _ = fixture.coordinator.tickHostScreenLockState()
        activity.setActiveNow()

        _ = try! await fixture.coordinator.handleWritingResponse(.goodbye(reason: GoodbyeReason.stoppedByHost))
        expect(poster.relockCount == 0, "a remote unlock followed by local use before disconnect is not relocked")
        print("PASS: a remotely unlocked screen someone is using by session end is not relocked")
    }

    // Locked at bring-up and never observed unlocked: the screen is already locked, so no relock.
    do {
        let poster = RecordingRelockPoster()
        let fixture = makeRelockWiringFixture(lockStateReader: FakeScreenLockState(locked: true), relockPoster: poster)
        await admitRelockWiringHostScreen(fixture)
        _ = try! await fixture.coordinator.handleWritingResponse(.goodbye(reason: GoodbyeReason.stoppedByHost))
        expect(poster.relockCount == 0, "a session locked for its whole life leaves the screen already locked")
        print("PASS: a host-screen session locked for its whole life does not relock")
    }

    // A canvas-only session (no host screen ever streamed) never relocks, whatever the reader says.
    do {
        let poster = RecordingRelockPoster()
        let reader = FlippableLockState(locked: true)
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            inputInjector: FakeInputInjector(),
            keyConfinement: .unconfined
        )
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: CanvasSurfaceSlots { _ in FakeCanvasMedia() },
            videoSink: FakeVideoSink(),
            lockStateReader: reader,
            lockScreenUnlocker: RelockWiringTestUnlocker(),
            hostScreenRelockPoster: poster
        )
        _ = try! await coordinator.handleWritingResponse(
            .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
        )
        reader.setLocked(false)
        _ = try! await coordinator.handleWritingResponse(.goodbye(reason: GoodbyeReason.stoppedByHost))
        expect(poster.relockCount == 0, "a session canvas has no login window and is never relocked, whatever the reader says")
        print("PASS: a canvas-only session never relocks, whatever the real machine's lock state is")
    }

    // The host quitting reaches the same teardown as goodbye, and relocks the same way.
    do {
        let poster = RecordingRelockPoster()
        let reader = FlippableLockState(locked: true)
        let fixture = makeRelockWiringFixture(lockStateReader: reader, relockPoster: poster)
        await admitRelockWiringHostScreen(fixture)

        reader.setLocked(false)
        _ = fixture.coordinator.tickHostScreenLockState()

        await fixture.coordinator.sessionDidEnd(reason: "host-quit")
        expect(poster.relockCount == 1, "the host quitting mid-session relocks the machine the same way a goodbye does")
        print("PASS: the host quitting a live, locked-then-unlocked host-screen session relocks it")
    }

    // The person at the host unlocks the machine themselves, and the session ends before the
    // next two-second poll ever reads that change: session end must still catch it.
    do {
        let poster = RecordingRelockPoster()
        let reader = FlippableLockState(locked: true)
        let fixture = makeRelockWiringFixture(lockStateReader: reader, relockPoster: poster)
        await admitRelockWiringHostScreen(fixture)

        reader.setLocked(false)
        _ = try! await fixture.coordinator.handleWritingResponse(.goodbye(reason: GoodbyeReason.stoppedByHost))
        expect(
            poster.relockCount == 1,
            "an unlock the session never polled for is still caught by session end's own fresh read"
        )
        print("PASS: an unlock with no poll in between is still caught at session end")
    }

    // Same gap, through the host-quit path instead of goodbye.
    do {
        let poster = RecordingRelockPoster()
        let reader = FlippableLockState(locked: true)
        let fixture = makeRelockWiringFixture(lockStateReader: reader, relockPoster: poster)
        await admitRelockWiringHostScreen(fixture)

        reader.setLocked(false)
        await fixture.coordinator.sessionDidEnd(reason: "host-quit")
        expect(
            poster.relockCount == 1,
            "the host quitting also takes a fresh read rather than trusting a stale poll"
        )
        print("PASS: the host quitting with no poll in between is still caught by its own fresh read")
    }

    // A remote unlock, with the only hid-tap traffic since being this host's
    // own forwarded keystrokes to the lock screen: `SelfPostDiscountingLocalActivitySignal`,
    // wired in for real rather than stubbed, must not let that self-posted
    // input read as a person at the machine.
    do {
        let poster = RecordingRelockPoster()
        let reader = FlippableLockState(locked: true)
        let ownActivity = FakeRelockWiringHIDActivity(secondsSinceLastPost: 0)
        let activity = SelfPostDiscountingLocalActivitySignal(
            raw: AlwaysJustActiveRawSignal(),
            ownActivity: ownActivity
        )
        let fixture = makeRelockWiringFixture(lockStateReader: reader, relockPoster: poster, localActivitySignal: activity)
        await admitRelockWiringHostScreen(fixture)

        reader.setLocked(false)
        _ = fixture.coordinator.tickHostScreenLockState()

        _ = try! await fixture.coordinator.handleWritingResponse(.goodbye(reason: GoodbyeReason.stoppedByHost))
        expect(
            poster.relockCount == 1,
            "our own hid-tap typing alone, with nothing genuinely newer, does not count as local activity and still relocks"
        )
        print("PASS: a remote unlock with only this host's own forwarded keystrokes since is still relocked")
    }

    // The same masking gap `MutableHostInjectedHIDActivityTests` covers directly,
    // exercised end to end through the real `CoreGraphicsInputInjector` and
    // `MutableHostInjectedHIDActivity` rather than fakes standing in for their
    // sampling and discounting: a real person's input, proven by the pre-post
    // sample the injector's own locked-screen post takes, must still veto the
    // relock its tracker would otherwise call for -- even though that later post
    // of ours leaves the raw reading looking like nothing but our own typing.
    do {
        let poster = RecordingRelockPoster()
        let reader = FlippableLockState(locked: true)
        let clock = WiringScriptedClock(time: 100)
        // `hidSystemState` still shows the last real touch, 100 seconds ago.
        let rawSignal = WiringScriptedRawSignal(reading: .idleFor(100))
        let ownActivity = MutableHostInjectedHIDActivity(rawActivity: rawSignal, now: clock.now)
        let injector = try! CoreGraphicsInputInjector(
            canvasDisplayID: CGMainDisplayID(),
            sessionKind: .hostScreen,
            lockStateReader: FakeScreenLockState(locked: true),
            hostInjectedHIDActivity: ownActivity,
            postEvent: { _, _ in }
        )
        let signal = SelfPostDiscountingLocalActivitySignal(raw: rawSignal, ownActivity: ownActivity)
        let fixture = makeRelockWiringFixture(lockStateReader: reader, relockPoster: poster, localActivitySignal: signal)
        await admitRelockWiringHostScreen(fixture)

        // The locked-screen key itself, posted through the real injector: this
        // is what actually calls `sampleBeforePost()`, catching the real
        // person's input above before `recordPost()` lets this post mask it.
        try! injector.inject(.key(keyCode: 0, isDown: true, modifiers: []))
        // What that post itself leaves `hidSystemState` reading, moments later.
        rawSignal.reading = .idleFor(0)

        reader.setLocked(false)
        _ = fixture.coordinator.tickHostScreenLockState()
        clock.time = 110
        // Ten seconds after our post, nothing else has touched `hidSystemState`
        // since -- the raw reading alone would read as our post alone.
        rawSignal.reading = .idleFor(10)

        _ = try! await fixture.coordinator.handleWritingResponse(.goodbye(reason: GoodbyeReason.stoppedByHost))
        expect(
            poster.relockCount == 0,
            "the real person's input the injector's own pre-post sample proved, a hundred and ten seconds ago, "
                + "still vetoes the relock, even though the injector's own later post masks it from the raw reading"
        )
        print("PASS: a real person's input the real injector's pre-post sample proved still vetoes relock, masked or not")
    }

    // The field case: the viewer types the password into the lock screen,
    // the machine unlocks, and the viewer keeps typing before it quits.
    // Every forwarded key after the unlock reaches the session tap, and a
    // key posted there resets the `hidSystemState` idle counter, as a real
    // host showed. With nothing else touching the machine, teardown must
    // relock.
    for realKeyAtMachine in [RelockWiringRealKey.none, .afterLastForwardedKey, .betweenForwardedKeys] {
        let poster = RecordingRelockPoster()
        let reader = FlippableLockState(locked: true)
        let clock = WiringScriptedClock(time: 1000)
        // Nobody has touched this machine for well past the presence threshold.
        let rawSignal = WiringScriptedRawSignal(reading: .idleFor(1000))
        let ownActivity = MutableHostInjectedHIDActivity(rawActivity: rawSignal, now: clock.now)
        let injector = try! CoreGraphicsInputInjector(
            canvasDisplayID: CGMainDisplayID(),
            sessionKind: .hostScreen,
            lockStateReader: reader,
            hostInjectedHIDActivity: ownActivity,
            postEvent: { _, _ in }
        )
        let signal = SelfPostDiscountingLocalActivitySignal(raw: rawSignal, ownActivity: ownActivity)
        let fixture = makeRelockWiringFixture(lockStateReader: reader, relockPoster: poster, localActivitySignal: signal)
        await admitRelockWiringHostScreen(fixture)

        // The password's last key, typed into the lock screen.
        try! injector.inject(.key(keyCode: 0, isDown: true, modifiers: []))
        rawSignal.reading = .idleFor(0)

        clock.time = 1002
        rawSignal.reading = .idleFor(2)
        reader.setLocked(false)
        _ = fixture.coordinator.tickHostScreenLockState()

        // Forwarded keys while unlocked, each resetting the raw counter.
        var lastForwardedKey: TimeInterval = 1000
        for keyTime: TimeInterval in [1010, 1020] {
            if realKeyAtMachine == .betweenForwardedKeys, keyTime == 1020 {
                // A real key at 1015, then masked by the forwarded key at 1020.
                rawSignal.reading = .idleFor(keyTime - 1015)
            } else {
                rawSignal.reading = .idleFor(keyTime - lastForwardedKey)
            }
            clock.time = keyTime
            try! injector.inject(.key(keyCode: 0, isDown: true, modifiers: []))
            rawSignal.reading = .idleFor(0)
            lastForwardedKey = keyTime
        }

        clock.time = 1030
        rawSignal.reading = realKeyAtMachine == .afterLastForwardedKey ? .idleFor(3) : .idleFor(10)

        _ = try! await fixture.coordinator.handleWritingResponse(.goodbye(reason: GoodbyeReason.stoppedByHost))
        switch realKeyAtMachine {
        case .none:
            expect(
                poster.relockCount == 1,
                "a raw idle reading fully explained by this host's own forwarded keys after unlock relocks at session end"
            )
            print("PASS: a remote unlock followed by forwarded typing while unlocked is relocked at session end")
        case .afterLastForwardedKey:
            expect(
                poster.relockCount == 0,
                "a real key at the machine after the last forwarded key still vetoes the relock"
            )
            print("PASS: a real key at the machine after the last forwarded key still vetoes the relock")
        case .betweenForwardedKeys:
            expect(
                poster.relockCount == 0,
                "a real key at the machine between two forwarded keys, proven by the later key's pre-post sample, "
                    + "still vetoes the relock"
            )
            print("PASS: a real key at the machine masked by a later forwarded key still vetoes the relock")
        }
    }

    // The person locks it again themselves after the last poll, with no further poll before
    // session end: the machine is already locked, so session end's fresh read must not relock it.
    do {
        let poster = RecordingRelockPoster()
        let reader = FlippableLockState(locked: true)
        let fixture = makeRelockWiringFixture(lockStateReader: reader, relockPoster: poster)
        await admitRelockWiringHostScreen(fixture)

        reader.setLocked(false)
        _ = fixture.coordinator.tickHostScreenLockState()
        reader.setLocked(true)
        _ = try! await fixture.coordinator.handleWritingResponse(.goodbye(reason: GoodbyeReason.stoppedByHost))
        expect(
            poster.relockCount == 0,
            "session end's fresh read finds the screen locked again and does not relock an already-locked screen"
        )
        print("PASS: a screen locked again after the last poll, with no further poll, is not relocked")
    }
}

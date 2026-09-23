import Foundation
import SensoriumCore
import SensoriumHost

/// A controllable clock: tests advance it explicitly rather than racing a
/// real five-minute or twelve-hour window, the same seam
/// `HostScreenResumeTicketStore` itself documents wanting.
private final class FakeClock {
    var seconds: Double = 1_000
    func now() -> Double { seconds }
    func advance(by delta: Double) { seconds += delta }
}

private func fingerprint(
    armedAt: Date = Date(timeIntervalSince1970: 1_700_000_000),
    asksWhenInUse: Bool = false
) -> HostScreenArmingFingerprint {
    HostScreenArmingFingerprint(HostScreenDeviceArming(
        devicePublicKey: Data([0xAA]),
        deviceName: "Probe",
        armedAt: armedAt,
        asksWhenSomeoneIsUsingThisMachine: asksWhenInUse
    ))
}

/// Design §6.5: a resume ticket's own validity, entirely pure over an
/// injected clock -- minting, the five-minute grace window (refreshed on
/// every successful resume), the twelve-hour ceiling (never refreshed), and
/// the bind to device/display/arming that makes "a different display was
/// requested" or "the arming record changed" (§6.5's own named
/// invalidations) refuse rather than silently resume something else.
@MainActor
func runHostScreenResumeTicketStoreTests() async {
    let deviceKey = Data([0xAA])
    let display = HostScreenDisplayIdentity(vendorNumber: 1552, modelNumber: 40)
    let otherDisplay = HostScreenDisplayIdentity(vendorNumber: 1552, modelNumber: 41)

    do {
        // The happy path: mint, then validate immediately
        let clock = FakeClock()
        let store = HostScreenResumeTicketStore(now: clock.now)
        let token = store.mint(devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint())
        expect(!token.isEmpty, "a minted ticket is real, non-empty opaque data")
        expect(
            store.validate(token: token, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint()),
            "a freshly minted ticket, presented immediately for the exact device/display/arming it was minted for, validates"
        )

        print("PASS: a freshly minted resume ticket validates for the exact device, display, and arming record it was minted under")
    }

    do {
        // An unknown token is refused, indistinguishable from a forgery
        let store = HostScreenResumeTicketStore(now: FakeClock().now)
        expect(
            !store.validate(token: Data([0x01, 0x02]), devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint()),
            "a token this store never minted refuses"
        )

        print("PASS: a token this store never minted is refused")
    }

    do {
        // Refusal never degrades: wrong device, wrong display, wrong arming
        let clock = FakeClock()
        let store = HostScreenResumeTicketStore(now: clock.now)
        let token = store.mint(devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint())

        expect(
            !store.validate(token: token, devicePublicKey: Data([0xBB]), displayIdentity: display, armingFingerprint: fingerprint()),
            "a ticket presented by a different device key refuses"
        )
        expect(
            !store.validate(token: token, devicePublicKey: deviceKey, displayIdentity: otherDisplay, armingFingerprint: fingerprint()),
            "a ticket presented for a different display refuses -- design §6.5's 'a different display was requested'"
        )
        expect(
            !store.validate(token: token, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint(asksWhenInUse: true)),
            "a ticket presented against a changed arming record refuses -- design §6.5's 'the arming record changed'"
        )
        expect(
            !store.validate(token: token, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint(armedAt: Date(timeIntervalSince1970: 1_800_000_000))),
            "an arming record that changed only in when it was armed still counts as changed"
        )
        // None of the four failed presentations above consumed the ticket:
        // a mismatched attempt is not itself an expiry.
        expect(
            store.validate(token: token, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint()),
            "a still-valid ticket survives being presented incorrectly by someone else first"
        )

        print("PASS: a resume ticket refuses a wrong device, display, or changed arming, and a failed presentation does not expire it")
    }

    do {
        // The five-minute grace window, and its boundary
        let clock = FakeClock()
        let store = HostScreenResumeTicketStore(now: clock.now)
        let token = store.mint(devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint())

        clock.advance(by: HostScreenResumeTicketStore.graceWindowSeconds)
        expect(
            store.validate(token: token, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint()),
            "exactly at the grace window's own boundary, the ticket still resumes -- the boundary favours the person already granted access, the convention every boundary in this repository follows"
        )

        clock.advance(by: HostScreenResumeTicketStore.graceWindowSeconds + 0.001)
        expect(
            !store.validate(token: token, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint()),
            "a hair past the grace window since the last successful resume refuses -- a fresh prompt, not silent resumption"
        )

        print("PASS: the five-minute grace window resumes silently up to and including its own boundary, and refuses a hair past it")
    }

    do {
        // The grace window refreshes on every successful resume
        let clock = FakeClock()
        let store = HostScreenResumeTicketStore(now: clock.now)
        let token = store.mint(devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint())

        // Resume just before the window would have closed, twice, each time
        // pushing the window forward rather than measuring from the
        // original mint -- exactly what makes a long-lived, intermittently
        // used session keep resuming silently.
        for _ in 0..<2 {
            clock.advance(by: HostScreenResumeTicketStore.graceWindowSeconds - 1)
            expect(
                store.validate(token: token, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint()),
                "a resume just inside the window succeeds and refreshes it"
            )
        }

        print("PASS: a successful resume refreshes the grace window instead of measuring only from the original mint")
    }

    do {
        // The twelve-hour ceiling never refreshes
        let clock = FakeClock()
        let store = HostScreenResumeTicketStore(now: clock.now)
        let token = store.mint(devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint())

        // Resume frequently -- well inside the grace window every time --
        // until the total elapsed time since the *original* mint exceeds
        // the twelve-hour ceiling. The ceiling must still bite, even though
        // no single gap between resumes ever came close to the grace
        // window closing.
        let step = HostScreenResumeTicketStore.graceWindowSeconds / 2
        var elapsed = 0.0
        var lastResult = true
        while elapsed < HostScreenResumeTicketStore.ceilingSeconds + step {
            clock.advance(by: step)
            elapsed += step
            lastResult = store.validate(token: token, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint())
        }
        expect(
            !lastResult,
            "once total elapsed time since the original mint passes the twelve-hour ceiling, the next reconnect prompts, however often the grace window was refreshed along the way"
        )
        expect(
            !store.validate(token: token, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint()),
            "the ceiling stays expired, not merely the one tick that crossed it"
        )

        print("PASS: the twelve-hour ceiling measures from the original mint and is never reset by a resume, unlike the grace window")
    }

    do {
        // invalidateAll(for:)
        let clock = FakeClock()
        let store = HostScreenResumeTicketStore(now: clock.now)
        let mine = store.mint(devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint())
        let someoneElses = store.mint(devicePublicKey: Data([0xBB]), displayIdentity: display, armingFingerprint: fingerprint())

        store.invalidateAll(for: deviceKey)

        expect(
            !store.validate(token: mine, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint()),
            "every ticket the invalidated device held stops resuming anything -- design §6.4's Stop control and §6.5's surface-teardown case"
        )
        expect(
            store.validate(token: someoneElses, devicePublicKey: Data([0xBB]), displayIdentity: display, armingFingerprint: fingerprint()),
            "invalidating one device's tickets never touches another device's"
        )

        print("PASS: invalidateAll(for:) removes every ticket for exactly the named device, and no other device's")
    }

    do {
        // Minting a second ticket never invalidates the first
        let clock = FakeClock()
        let store = HostScreenResumeTicketStore(now: clock.now)
        let first = store.mint(devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint())
        let second = store.mint(devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint())
        expect(first != second, "two mints for the same device and display produce two distinct tokens")
        expect(
            store.validate(token: first, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint()),
            "the first ticket still resumes after a second one was minted for the same device"
        )
        expect(
            store.validate(token: second, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint()),
            "the second ticket resumes too -- a device may hold more than one live grant"
        )

        print("PASS: minting a further ticket for the same device never invalidates an earlier, still-valid one")
    }

    do {
        // A restarted host starts every ticket store empty
        // Design §6.5's "the host restarted" invalidation, satisfied by
        // construction: nothing here is ever written to disk, so a fresh
        // process (a fresh store instance, standing in for one) has never
        // minted the token being presented.
        let clock = FakeClock()
        let mintingStore = HostScreenResumeTicketStore(now: clock.now)
        let token = mintingStore.mint(devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint())
        let restartedStore = HostScreenResumeTicketStore(now: clock.now)
        expect(
            !restartedStore.validate(token: token, devicePublicKey: deviceKey, displayIdentity: display, armingFingerprint: fingerprint()),
            "a ticket minted before a restart means nothing to the store a restarted host starts with"
        )

        print("PASS: a resume ticket does not survive a host restart, because nothing here is ever persisted to disk")
    }
}

import Foundation
import SensoriumCore
import SensoriumHost

@MainActor
private func fingerprint(armedAt: Date, asksWhenInUse: Bool = false) -> HostScreenArmingFingerprint {
    HostScreenArmingFingerprint(
        HostScreenDeviceArming(
            devicePublicKey: Data([0xFF]),
            deviceName: "device",
            armedAt: armedAt,
            asksWhenSomeoneIsUsingThisMachine: asksWhenInUse
        )
    )
}

@MainActor
func runHostScreenUnlockThrottleTests() {
    let keyA = Data([1, 2, 3])
    let keyB = Data([4, 5, 6])
    let armedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let printA = fingerprint(armedAt: armedAt)

    // A fresh store charges nothing.
    do {
        let throttle = HostScreenUnlockThrottle()
        expect(throttle.failureCount(devicePublicKey: keyA, armingFingerprint: printA) == 0, "a never-charged key starts at zero")
        print("PASS: an unlock throttle starts every device at zero")
    }

    // tryReserve consumes a slot and refuses the one past the cap.
    do {
        let throttle = HostScreenUnlockThrottle()
        for slot in 0..<HostScreenUnlockThrottle.maximumUnlockFailures {
            expect(throttle.tryReserve(devicePublicKey: keyA, armingFingerprint: printA), "slot \(slot) is within the cap and is granted")
        }
        expect(
            throttle.failureCount(devicePublicKey: keyA, armingFingerprint: printA) == HostScreenUnlockThrottle.maximumUnlockFailures,
            "each granted reservation adds one to the key's count"
        )
        expect(
            !throttle.tryReserve(devicePublicKey: keyA, armingFingerprint: printA),
            "the reservation past the cap is refused"
        )
        expect(
            throttle.failureCount(devicePublicKey: keyA, armingFingerprint: printA) == HostScreenUnlockThrottle.maximumUnlockFailures,
            "and a refused reservation charges nothing"
        )
        print("PASS: tryReserve consumes slots up to the cap and refuses the one past it, charging nothing on refusal")
    }

    // refund releases exactly one slot and never underflows.
    do {
        let throttle = HostScreenUnlockThrottle()
        _ = throttle.tryReserve(devicePublicKey: keyA, armingFingerprint: printA)
        _ = throttle.tryReserve(devicePublicKey: keyA, armingFingerprint: printA)
        throttle.refund(devicePublicKey: keyA, armingFingerprint: printA)
        expect(throttle.failureCount(devicePublicKey: keyA, armingFingerprint: printA) == 1, "refund releases exactly one slot")
        throttle.refund(devicePublicKey: keyA, armingFingerprint: printA)
        throttle.refund(devicePublicKey: keyA, armingFingerprint: printA)
        expect(throttle.failureCount(devicePublicKey: keyA, armingFingerprint: printA) == 0, "refund never drops a count below zero")
        print("PASS: refund releases one slot and floors at zero")
    }

    // A refunded slot is reusable: reserve to the cap, refund one, reserve
    // again succeeds -- the released slot is genuinely free.
    do {
        let throttle = HostScreenUnlockThrottle()
        for _ in 0..<HostScreenUnlockThrottle.maximumUnlockFailures {
            _ = throttle.tryReserve(devicePublicKey: keyA, armingFingerprint: printA)
        }
        expect(!throttle.tryReserve(devicePublicKey: keyA, armingFingerprint: printA), "at the cap, the next reservation is refused")
        throttle.refund(devicePublicKey: keyA, armingFingerprint: printA)
        expect(throttle.tryReserve(devicePublicKey: keyA, armingFingerprint: printA), "a refunded slot is free to reserve again")
        print("PASS: a refunded slot becomes reservable again")
    }

    // A different device key has an independent budget.
    do {
        let throttle = HostScreenUnlockThrottle()
        _ = throttle.tryReserve(devicePublicKey: keyA, armingFingerprint: printA)
        _ = throttle.tryReserve(devicePublicKey: keyA, armingFingerprint: printA)
        expect(throttle.failureCount(devicePublicKey: keyB, armingFingerprint: printA) == 0, "a different device key is charged nothing by the first's reservations")
        expect(throttle.tryReserve(devicePublicKey: keyB, armingFingerprint: printA), "and reserves from a full, fresh budget of its own")
        print("PASS: two device keys hold independent unlock budgets")
    }

    // A different arming fingerprint -- as a re-arm produces with a new
    // armedAt -- is an independent budget, so a re-arm starts fresh with no
    // explicit reset.
    do {
        let throttle = HostScreenUnlockThrottle()
        _ = throttle.tryReserve(devicePublicKey: keyA, armingFingerprint: printA)
        let reArmed = fingerprint(armedAt: armedAt.addingTimeInterval(1))
        expect(printA != reArmed, "a new armedAt is a different fingerprint")
        expect(throttle.failureCount(devicePublicKey: keyA, armingFingerprint: reArmed) == 0, "a re-armed record's budget is fresh, with no leftover count")
        print("PASS: a re-arm's new fingerprint starts a fresh unlock budget for the same device")
    }

    // Reset clears a key's count, as a successful unlock does.
    do {
        let throttle = HostScreenUnlockThrottle()
        _ = throttle.tryReserve(devicePublicKey: keyA, armingFingerprint: printA)
        _ = throttle.tryReserve(devicePublicKey: keyA, armingFingerprint: printA)
        throttle.reset(devicePublicKey: keyA, armingFingerprint: printA)
        expect(throttle.failureCount(devicePublicKey: keyA, armingFingerprint: printA) == 0, "reset clears the key's count")
        print("PASS: resetting an unlock budget clears the device's count")
    }
}

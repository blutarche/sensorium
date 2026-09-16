import Foundation
import SensoriumCore
import SensoriumHost

/// `HostOperatorStatusStore.recordPairingRequest` -- design's own "shown
/// the moment a new machine asks to pair," and the two rules that follow:
/// revealing an already-active code is always safe, minting
/// a fresh one is not (it would let a peer cancel the code a person at the
/// viewer is mid-typing), and the requesting machine's name is never a queue,
/// only ever the latest one.
@MainActor
func runPairingCodeRevealTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    do {
        // No code currently valid: a fresh one is issued
        let store = HostOperatorStatusStore(permissions: granted)
        store.beginHosting(address: "100.100.0.4")
        var issueCodeCallCount = 0
        let now = Date()
        store.recordPairingRequest(deviceName: "Kestrel Laptop Pro", now: now) {
            issueCodeCallCount += 1
            return ("135791", now.addingTimeInterval(PairingAuthority.defaultLifetime))
        }
        expect(issueCodeCallCount == 1, "with no code currently valid, a pairRequest issues exactly one fresh code")
        guard case let .showing(code, expiresAt, requestingDeviceName) = store.status.pairing else {
            expect(false, "recording a pairing request with nothing currently valid puts a code on screen")
            return
        }
        expect(code == "135791" && expiresAt == now.addingTimeInterval(PairingAuthority.defaultLifetime), "the freshly issued code and its own expiry are recorded")
        expect(requestingDeviceName == "Kestrel Laptop Pro", "the requesting device's own name is recorded alongside the fresh code")

        print("PASS: a pairRequest with no code currently valid issues exactly one fresh code and names the requester")
    }

    do {
        // A still-valid code is revealed, never rotated
        let store = HostOperatorStatusStore(permissions: granted)
        let issuedAt = Date()
        store.showPairingCode("246810", expiresAt: issuedAt.addingTimeInterval(PairingAuthority.defaultLifetime))
        var issueCodeCallCount = 0
        store.recordPairingRequest(deviceName: "Kestrel Laptop Pro", now: issuedAt.addingTimeInterval(10)) {
            issueCodeCallCount += 1
            return ("999999", issuedAt.addingTimeInterval(PairingAuthority.defaultLifetime))
        }
        expect(
            issueCodeCallCount == 0,
            "a code still valid when the request arrives is never rotated -- issueCode is not called at all, so a peer's pairRequest cannot cancel a code a person is already typing"
        )
        guard case let .showing(code, expiresAt, requestingDeviceName) = store.status.pairing else {
            expect(false, "recording a pairing request while one is already open leaves the code on screen")
            return
        }
        expect(
            code == "246810" && expiresAt == issuedAt.addingTimeInterval(PairingAuthority.defaultLifetime),
            "the code and its expiry are exactly what was already active, untouched"
        )
        expect(requestingDeviceName == "Kestrel Laptop Pro", "the requester's name is still recorded, even though the code itself was not")

        print("PASS: a pairRequest arriving while a code is still valid reveals that same code and never rotates it")
    }

    do {
        // An expired code is not "currently valid" -- a fresh one is issued
        let store = HostOperatorStatusStore(permissions: granted)
        let issuedAt = Date()
        store.showPairingCode("111222", expiresAt: issuedAt.addingTimeInterval(60))
        var issueCodeCallCount = 0
        store.recordPairingRequest(deviceName: "Kestrel Laptop Pro", now: issuedAt.addingTimeInterval(61)) {
            issueCodeCallCount += 1
            return ("333444", issuedAt.addingTimeInterval(61 + PairingAuthority.defaultLifetime))
        }
        expect(issueCodeCallCount == 1, "a code that has already expired is not something to reveal -- a fresh one is issued instead")
        guard case let .showing(code, _, _) = store.status.pairing else {
            expect(false, "recording a pairing request past an expired code leaves the fresh code on screen")
            return
        }
        expect(code == "333444", "the newly issued code, not the expired one, is what is now recorded")

        print("PASS: an expired code is treated as none currently valid, and a fresh one is issued")
    }

    do {
        // One at a time, no queue: a later request replaces the name, never adds to it
        let store = HostOperatorStatusStore(permissions: granted)
        let issuedAt = Date()
        store.showPairingCode("555666", expiresAt: issuedAt.addingTimeInterval(PairingAuthority.defaultLifetime))
        store.recordPairingRequest(deviceName: "Kestrel Laptop Pro", now: issuedAt.addingTimeInterval(5)) {
            expect(false, "the code is still valid; this closure must not run")
            return ("000000", issuedAt)
        }
        store.recordPairingRequest(deviceName: "Kestrel Laptop Air", now: issuedAt.addingTimeInterval(10)) {
            expect(false, "the code is still valid; this closure must not run")
            return ("000000", issuedAt)
        }
        guard case let .showing(code, _, requestingDeviceName) = store.status.pairing else {
            expect(false, "two pairing requests against the same open code leave it on screen")
            return
        }
        expect(code == "555666", "the code itself is unaffected by either request")
        expect(
            requestingDeviceName == "Kestrel Laptop Air",
            "only the latest requester's name is recorded -- the first is simply overwritten, not queued or listed alongside it"
        )

        print("PASS: a second pairing request replaces the first requester's name outright, one at a time, never a queue")
    }

    do {
        // Presentation: the requester's name appears in detail, and only there
        let issuedAt = Date()
        let named = HostOperatorStatus(
            connection: .hosting(address: "100.100.0.4"),
            pairing: .showing(
                code: "777888",
                expiresAt: issuedAt.addingTimeInterval(PairingAuthority.defaultLifetime),
                requestingDeviceName: "Kestrel Laptop Pro"
            ),
            permissions: granted
        ).presentation(now: issuedAt.addingTimeInterval(1))
        expect(
            named.eyebrow == "READY" && named.headline == "Waiting for a machine to connect",
            "the eyebrow and headline stay exactly as they were before this field existed -- a code being asked for is not the same fact as a machine connecting"
        )
        expect(
            named.detail == "Kestrel Laptop Pro is asking to pair.",
            "detail names the requester in plain words once one has asked"
        )

        let unnamed = HostOperatorStatus(
            connection: .hosting(address: "100.100.0.4"),
            pairing: .showing(code: "777888", expiresAt: issuedAt.addingTimeInterval(PairingAuthority.defaultLifetime)),
            permissions: granted
        ).presentation(now: issuedAt.addingTimeInterval(1))
        expect(
            unnamed.detail.isEmpty,
            "with nobody asking yet -- a person revealed the code themselves -- detail reads exactly as it always did, empty"
        )

        print("PASS: the presentation names the requester in detail once one exists, and reads as a plain sentence when none does")
    }
}

import AppKit
import Foundation
import SensoriumCore
import SensoriumHost

/// The host's own recovery from a key it cannot read: the words
/// `HostIdentityFailureCopy` shows, `HostOperatorStatusStore`'s typed
/// identity problem, and `HostSetupWindowController`'s "Try again" and
/// "Make a new key" buttons, exercised only through injected closures --
/// the same discipline `HostSetupTailscaleButtonTests` uses for the
/// Tailscale button beside it.
@MainActor
func runHostIdentityFailureTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    func replaceIdentityButton(in controller: HostSetupWindowController) -> NSButton {
        for child in Mirror(reflecting: controller).children {
            if child.label == "replaceIdentityButton", let button = child.value as? NSButton {
                return button
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named replaceIdentityButton")
    }

    func tap(_ button: NSButton) {
        guard let action = button.action, let target = button.target as? NSObject else {
            fatalError("the Make a new key button has no target/action wired")
        }
        _ = target.perform(action, with: button)
    }

    func retryIdentityButton(in controller: HostSetupWindowController) -> NSButton {
        for child in Mirror(reflecting: controller).children {
            if child.label == "retryIdentityButton", let button = child.value as? NSButton {
                return button
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named retryIdentityButton")
    }

    func controller(
        status: HostOperatorStatus,
        onReplaceIdentity: @escaping @MainActor () -> Void = {},
        onRetryIdentityRead: @escaping @MainActor () -> Void = {}
    ) -> HostSetupWindowController {
        HostSetupWindowController(
            status: status,
            onRevealPairingCode: {},
            onStop: {},
            onReplaceIdentity: onReplaceIdentity,
            onRetryIdentityRead: onRetryIdentityRead,
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
    }

    do {
        // The copy itself: worded for the host, not the viewer
        let copy = HostIdentityFailureCopy.cannotReadKey
        expect(
            copy.headline == "Sensorium Host cannot read its own key",
            "the headline names Sensorium Host, not the viewer app -- got: \(copy.headline)"
        )
        expect(
            !copy.detail.contains("--") && !copy.detail.contains("Keychain Access"),
            "the detail names no command-line flag and no other app to open -- got: \(copy.detail)"
        )
        expect(
            copy.replaceButtonTitle == "Make a new key",
            "the button title matches the spec's own wording exactly -- got: \(copy.replaceButtonTitle)"
        )
        expect(
            copy.replaceConsequence.contains("replaces the key")
                && copy.replaceConsequence.contains("no longer recognize this machine")
                && copy.replaceConsequence.contains("Host screen settings are kept"),
            "the consequence states plainly that the key is replaced, that pairing breaks, and what does "
                + "not break (already-armed host-screen sharing) -- got: \(copy.replaceConsequence)"
        )

        print("PASS: HostIdentityFailureCopy.cannotReadKey is worded for the host and names both consequences")
    }

    do {
        // The first thing to try is repeating the read, not throwing the key away
        let copy = HostIdentityFailureCopy.cannotReadKey
        expect(
            copy.retryButtonTitle == "Try again",
            "the primary button repeats the read that already ran once to reach this screen -- got: \(copy.retryButtonTitle)"
        )
        expect(
            copy.detail == "The file that holds the key identifying this machine could not be read. Click Try "
                + "again. If that keeps failing, make a new key.",
            "the body names what failed and the next click -- got: \(copy.detail)"
        )

        print("PASS: HostIdentityFailureCopy offers Try again first and says which file could not be read")
    }

    do {
        // The typed problem, not a string match
        let store = HostOperatorStatusStore(permissions: granted)
        var observed: [HostOperatorStatus] = []
        store.addObserver { observed.append($0) }
        store.reportIdentityProblem(.cannotReadKey)
        expect(
            store.status.connection == .notHosting && store.status.identityProblem == .cannotReadKey
                && store.status.problem == nil,
            "reportIdentityProblem records the typed copy, leaves activity not-hosting, and never also sets the plain problem string"
        )
        expect(observed.count == 1, "reporting an identity problem notifies every observer")

        let presentation = store.status.presentation(now: Date())
        expect(
            presentation.eyebrow == "COULD NOT START"
                && presentation.headline == HostIdentityFailureCopy.cannotReadKey.headline
                && presentation.detail == HostIdentityFailureCopy.cannotReadKey.detail
                && presentation.identityProblem == .cannotReadKey,
            "the presentation shows the identity copy's own headline and detail under the usual could-not-start eyebrow -- got headline \(presentation.headline), detail \(presentation.detail)"
        )

        store.clearIdentityProblem()
        expect(
            store.status.identityProblem == nil,
            "clearIdentityProblem removes the typed problem so a retry does not still read as broken"
        )

        store.beginHosting(address: "100.100.0.4")
        let hostingAfterProblem = HostOperatorStatusStore(permissions: granted)
        hostingAfterProblem.reportIdentityProblem(.cannotReadKey)
        hostingAfterProblem.beginHosting(address: "100.100.0.4")
        expect(
            hostingAfterProblem.status.identityProblem == nil,
            "starting hosting successfully clears a stale identity problem on its own, the same as it already clears the plain problem string"
        )

        let reportedThenPlain = HostOperatorStatusStore(permissions: granted)
        reportedThenPlain.reportIdentityProblem(.cannotReadKey)
        reportedThenPlain.reportProblem("address already in use")
        expect(
            reportedThenPlain.status.identityProblem == nil && reportedThenPlain.status.problem == "address already in use",
            "a later plain problem replaces an identity problem rather than leaving both set"
        )

        print("PASS: the operator status store carries the identity problem as a typed value and clears it on request or a fresh start")
    }

    do {
        // The window: hidden by default, shown and titled for an identity problem
        let ordinary = controller(status: HostOperatorStatus(connection: .notHosting, permissions: granted))
        expect(replaceIdentityButton(in: ordinary).isHidden, "the replace-identity button is hidden with no identity problem")

        let bindFailure = controller(status: HostOperatorStatus(
            connection: .notHosting, permissions: granted, problem: "address already in use"
        ))
        expect(
            replaceIdentityButton(in: bindFailure).isHidden,
            "an ordinary bind failure is not this machine's identity, so the button stays hidden"
        )

        let identityBroken = controller(status: HostOperatorStatus(
            connection: .notHosting, permissions: granted, identityProblem: .cannotReadKey
        ))
        let button = replaceIdentityButton(in: identityBroken)
        expect(!button.isHidden, "an identity problem shows the replace button")
        expect(
            button.title == HostIdentityFailureCopy.cannotReadKey.replaceButtonTitle,
            "the button reads the copy's own title -- got: \(button.title)"
        )

        var tapped = false
        let tappable = controller(
            status: HostOperatorStatus(connection: .notHosting, permissions: granted, identityProblem: .cannotReadKey),
            onReplaceIdentity: { tapped = true }
        )
        tap(replaceIdentityButton(in: tappable))
        expect(tapped, "tapping the button runs onReplaceIdentity")

        print("PASS: HostSetupWindowController shows the replace-identity button only for an identity problem, titled from its copy, wired to onReplaceIdentity")
    }

    do {
        // Try again sits above the replace button
        let ordinary = controller(status: HostOperatorStatus(connection: .notHosting, permissions: granted))
        expect(
            retryIdentityButton(in: ordinary).isHidden,
            "the try-again button is hidden with no identity problem"
        )

        let identityBroken = controller(status: HostOperatorStatus(
            connection: .notHosting, permissions: granted, identityProblem: .cannotReadKey
        ))
        let button = retryIdentityButton(in: identityBroken)
        expect(!button.isHidden, "an identity problem shows the try-again button")
        expect(
            button.title == HostIdentityFailureCopy.cannotReadKey.retryButtonTitle,
            "the button reads the copy's own title -- got: \(button.title)"
        )
        expect(
            !replaceIdentityButton(in: identityBroken).isHidden,
            "Make a new key stays on screen beside it, as the second thing to try"
        )
        expect(
            replaceIdentityButton(in: identityBroken).isEnabled,
            "both buttons are pressable: reading a file is synchronous, so neither can race a read still running"
        )

        var retried = false
        let tappable = controller(
            status: HostOperatorStatus(connection: .notHosting, permissions: granted, identityProblem: .cannotReadKey),
            onRetryIdentityRead: { retried = true }
        )
        tap(retryIdentityButton(in: tappable))
        expect(retried, "tapping the button runs onRetryIdentityRead")

        print("PASS: HostSetupWindowController shows the try-again button for an identity problem, titled from its copy, wired to onRetryIdentityRead")
    }
}

/// "Make a new key" on the host, driven against fakes: both identities are
/// replaced through the same seam, a store that throws is reported as a
/// failure rather than mistaken for a fresh key, and a failure partway
/// leaves both old files in place.
func runHostIdentityReplacementTests() {
    do {
        let device = FakeHostDeviceIdentityReplacer()
        device.minted = .success(try! DeviceIdentity.generate())
        let tls = FakeHostTLSIdentityReplacer()
        tls.minted = .success(try! HostTLSIdentity.generate(commonName: "Sensorium Host"))

        expect(
            HostIdentityRecovery.replaceIdentities(device: device, tls: tls) == .replaced,
            "one press that mints and stores both identities is reported as replaced"
        )
        expect(device.storedCount == 1, "exactly one device key written for one press")
        expect(tls.storedCount == 1, "exactly one TLS identity written for one press")

        print("PASS: the host's Make a new key writes a fresh device key and a fresh TLS identity for one press")
    }

    do {
        let device = FakeHostDeviceIdentityReplacer()
        device.minted = .failure(FakeHostReplaceError.unwritable)
        let tls = FakeHostTLSIdentityReplacer()
        tls.minted = .success(try! HostTLSIdentity.generate(commonName: "Sensorium Host"))

        guard case let .deviceIdentityFailed(reason) = HostIdentityRecovery.replaceIdentities(device: device, tls: tls) else {
            expect(false, "a device key replacement that throws must never be reported as replaced")
            return
        }
        expect(reason.contains("unwritable"), "the failure carries the store's own reason -- got: \(reason)")
        expect(tls.storedCount == 0, "a device key that could not be made leaves the TLS identity file untouched")

        print("PASS: the host reports a device key replacement that throws as a failure carrying its reason")
    }

    do {
        // The half-replaced host is the case worth guarding: a machine
        // carrying a new device key and its old TLS identity can neither be
        // recognised by a paired viewer nor repaired by retrying.
        let device = FakeHostDeviceIdentityReplacer()
        device.minted = .success(try! DeviceIdentity.generate())
        let tls = FakeHostTLSIdentityReplacer()
        tls.minted = .failure(FakeHostReplaceError.unwritable)

        guard case let .hostTLSIdentityFailed(reason) = HostIdentityRecovery.replaceIdentities(device: device, tls: tls) else {
            expect(false, "a TLS identity replacement that throws must never be reported as replaced")
            return
        }
        expect(reason.contains("unwritable"), "the failure carries the store's own reason -- got: \(reason)")
        expect(
            device.storedCount == 0,
            "a TLS identity that could not be made leaves the device key file as it was, so the pair on disk still matches"
        )

        print("PASS: a TLS identity that cannot be made leaves the old device key on disk rather than half-replacing the host")
    }
}

private enum FakeHostReplaceError: Error, LocalizedError {
    case unwritable

    var errorDescription: String? { "the identity file is unwritable" }
}

private final class FakeHostDeviceIdentityReplacer: DeviceIdentityReplacing, @unchecked Sendable {
    var minted: Result<DeviceIdentity, Error> = .failure(FakeHostReplaceError.unwritable)
    private(set) var storedCount = 0

    func makeReplacementIdentity() throws -> DeviceIdentity {
        try minted.get()
    }

    func store(_ identity: DeviceIdentity) throws {
        storedCount += 1
    }
}

private final class FakeHostTLSIdentityReplacer: HostTLSIdentityReplacing, @unchecked Sendable {
    var minted: Result<HostTLSIdentity, Error> = .failure(FakeHostReplaceError.unwritable)
    private(set) var storedCount = 0

    func makeReplacementIdentity() throws -> HostTLSIdentity {
        try minted.get()
    }

    func store(_ identity: HostTLSIdentity) throws {
        storedCount += 1
    }
}

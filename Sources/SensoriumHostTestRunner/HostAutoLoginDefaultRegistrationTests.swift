import Foundation
import SensoriumHost

/// `HostAutoLoginDefaultRegistration.applyIfNeeded` registers the "open at
/// login" default exactly once, using `HostAutoLoginDefaultAppliedStore` to
/// remember whether that has already happened -- mirroring how
/// `HostScreenArmingStore` remembers its own one-time arming.
func runHostAutoLoginDefaultRegistrationTests() {
    do {
        // First launch: no file at all, the ordinary first run.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-autologin-default-first-run-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostAutoLoginDefaultAppliedStore(url: url)
        let registering = SpyAutoLoginRegistering(status: .notRegistered)

        let error = HostAutoLoginDefaultRegistration.applyIfNeeded(registering: registering, store: store)
        expect(error == nil, "a first launch that registers successfully reports no error")
        expect(registering.registerCallCount == 1, "a first launch registers exactly once")
        expect(store.load().applied, "a first launch marks the default applied")
        print("PASS: a first launch registers the default and marks it applied")
    }

    do {
        // A later launch: the store already says the default was applied.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-autologin-default-later-run-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostAutoLoginDefaultAppliedStore(url: url)
        try! store.markApplied()
        let registering = SpyAutoLoginRegistering(status: .notRegistered)

        let error = HostAutoLoginDefaultRegistration.applyIfNeeded(registering: registering, store: store)
        expect(error == nil, "a later launch reports no error without touching registration at all")
        expect(registering.registerCallCount == 0, "a later launch never re-registers, whatever the owner has since chosen")
        print("PASS: a later launch never re-registers over the owner's own choice")
    }

    do {
        // A `register()` failure is surfaced, and the flag is still marked
        // applied -- this app tries the default exactly once, not on every
        // later launch; the switch in the host window is how the owner
        // retries by hand.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-autologin-default-error-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = HostAutoLoginDefaultAppliedStore(url: url)
        let registering = SpyAutoLoginRegistering(status: .notRegistered)
        registering.registerError = AutoLoginRegistrationTestError.denied

        let error = HostAutoLoginDefaultRegistration.applyIfNeeded(registering: registering, store: store)
        expect(error != nil, "a register() failure is surfaced to the caller, not swallowed")
        expect(store.load().applied, "the default is still marked applied after a failed attempt")
        print("PASS: a register() failure is surfaced, and the default is still marked applied")
    }

    do {
        // The applied flag cannot be persisted at all -- a file sits where
        // the store needs a directory. `register()` must not run this
        // launch: registering without being able to record it would
        // re-register on every later launch too, since the flag can never
        // be marked applied.
        let blocker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-autologin-default-blocker-\(UUID().uuidString)")
        try! Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let url = blocker.appendingPathComponent("applied.json")
        let store = HostAutoLoginDefaultAppliedStore(url: url)
        let registering = SpyAutoLoginRegistering(status: .notRegistered)

        let error = HostAutoLoginDefaultRegistration.applyIfNeeded(registering: registering, store: store)
        expect(error != nil, "a store that cannot persist the applied flag surfaces that failure")
        expect(registering.registerCallCount == 0, "register() never runs when the flag cannot be persisted")
        print("PASS: a store that cannot persist the applied flag skips register() and surfaces the failure")
    }

    do {
        // An unreadable file counts as already applied, the same as
        // `HostScreenArmingStore`'s own unreadable-file rule, so a launch
        // can never re-register behind the owner's back.
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sensorium-autologin-default-unreadable-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try! Data("{ not the applied record".utf8).write(to: url)
        var reported: [String] = []
        let store = HostAutoLoginDefaultAppliedStore(url: url, log: { reported.append($0) })
        expect(store.load().applied, "an unreadable file counts as already applied")
        expect(reported.count == 1 && reported[0].contains(url.path), "the unreadable file is named once in the log")

        let registering = SpyAutoLoginRegistering(status: .notRegistered)
        let error = HostAutoLoginDefaultRegistration.applyIfNeeded(registering: registering, store: store)
        expect(error == nil, "an unreadable file never registers, so there is nothing to surface an error for")
        expect(registering.registerCallCount == 0, "an unreadable file never registers")
        print("PASS: an unreadable applied-record file counts as already applied and never re-registers")
    }
}

private enum AutoLoginRegistrationTestError: Error {
    case denied
}

private final class SpyAutoLoginRegistering: HostAutoLoginRegistering, @unchecked Sendable {
    private let status_: HostAutoLoginStatus
    private(set) var registerCallCount = 0
    var registerError: Error?

    init(status: HostAutoLoginStatus) {
        self.status_ = status
    }

    func status() -> HostAutoLoginStatus { status_ }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
    }

    func unregister() throws {}
}

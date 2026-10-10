import Foundation
import SensoriumHost

private struct UnlockedLockState: ScreenLockStateReading {
    func isScreenLocked() -> Bool { false }
}

private final class IdleSinceBootSignal: HostLocalActivitySignal, @unchecked Sendable {
    private(set) var readCount = 0
    func currentReading() -> HostLocalActivityReading {
        readCount += 1
        return .idleFor(10_000)
    }
}

private final class CountingRelockPoster: HostScreenRelocking, @unchecked Sendable {
    private(set) var relockCount = 0
    func relock() -> Bool {
        relockCount += 1
        return true
    }
}

/// The host reads the update arguments before any other: `--update-self-test`
/// and `--replacing` must never reach the `pair`/`serve` parsing, which ends
/// any launch it does not recognise with a usage message.
func runHostUpdateLaunchRouteTests() {
    expect(
        HostLaunchRoute.route(["--update-self-test"]) == .selfTest,
        "--update-self-test is the self-test, not an argument for the CLI verbs"
    )
    print("PASS: --update-self-test routes to the self-test")

    let readyFile = URL(fileURLWithPath: "/private/tmp/staging/update-ready.json")
    expect(
        HostLaunchRoute.route(["--replacing", "4242", readyFile.path])
            == .updateRelaunch(HostUpdateRelaunch(replacedProcess: 4242, readyFile: readyFile)),
        "--replacing <pid> <ready file> starts the GUI host as the replacement for that process"
    )
    print("PASS: --replacing routes to the GUI host as an update relaunch")

    expect(HostLaunchRoute.route([]) == .normal([]), "no arguments is the ordinary launch, parsed as before")
    expect(
        HostLaunchRoute.route(["serve", "100.64.1.5", "7000"]) == .normal(["serve", "100.64.1.5", "7000"]),
        "a CLI verb reaches the existing parsing untouched"
    )
    expect(
        HostLaunchRoute.route(["--bogus"]) == .normal(["--bogus"]),
        "an unknown argument reaches the existing parsing, which ends it with a usage message"
    )
    expect(
        HostLaunchRoute.route(["--update-self-test", "serve"]) == .normal(["--update-self-test", "serve"]),
        "the self-test argument with anything after it is not the self-test"
    )
    expect(
        HostLaunchRoute.route(["--replacing", "4242", "relative/update-ready.json"])
            == .normal(["--replacing", "4242", "relative/update-ready.json"]),
        "a malformed --replacing is left to the existing parsing rather than trusted"
    )
    print("PASS: every other launch reaches the existing argument parsing unchanged")
}

/// An update relaunch is not a login: the lock at start must not run, so an
/// update leaves the screen locked or unlocked as it was.
func runHostUpdateRelaunchLockTests() {
    do {
        let signal = IdleSinceBootSignal()
        let poster = CountingRelockPoster()
        let outcome = HostAutoLoginLockAtStart.applyIfNeeded(
            lockStateReader: UnlockedLockState(),
            activitySignal: signal,
            systemUptime: 10_000,
            relockPoster: poster,
            isUpdateRelaunch: false
        )
        expect(outcome == .locked, "the fixture reads as an unattended auto-login, which an ordinary launch locks")
        expect(poster.relockCount == 1, "an ordinary launch posts the relock once")
    }

    do {
        let signal = IdleSinceBootSignal()
        let poster = CountingRelockPoster()
        let outcome = HostAutoLoginLockAtStart.applyIfNeeded(
            lockStateReader: UnlockedLockState(),
            activitySignal: signal,
            systemUptime: 10_000,
            relockPoster: poster,
            isUpdateRelaunch: true
        )
        expect(outcome == .skippedForUpdateRelaunch, "an update relaunch skips the lock at start, got \(outcome)")
        expect(poster.relockCount == 0, "an update relaunch never posts the relock")
        expect(signal.readCount == 0, "an update relaunch does not even read local activity")
    }
    print("PASS: an update relaunch skips the lock at start that an ordinary launch applies")

    let route = HostLaunchRoute.route(["--replacing", "77", "/private/tmp/staging/update-ready.json"])
    guard case let .updateRelaunch(relaunch) = route else {
        expect(false, "--replacing routes to an update relaunch, got \(route)")
        return
    }
    expect(relaunch.replacedProcess == 77, "the relaunch names the process it replaces")
    print("PASS: the --replacing route is the one that carries the update relaunch")
}

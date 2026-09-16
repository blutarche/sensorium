# How this repository is verified

Four executables assert and exit non-zero on the first failure, instead of XCTest.

## Runners

The toolchain this project targets is Swift from Command Line Tools without Xcode, where `XCTest` and the `Testing` module are not importable.

```sh
./Scripts/run-unit-tests.sh
```

| Runner | Covers |
|---|---|
| `SensoriumCoreTestRunner` | Lifecycle state machine, codecs, pairing, backoff, metrics, lock-screen unlock wire messages and outcome tokens |
| `SensoriumHostTestRunner` | Canvas ownership, capture guard, input gate, pairing ceremony, ingress policy, unlock challenge/arm/throttle, the loopback RFB unlock client |
| `SensoriumClientTestRunner` | Viewport, surface events, frame admission, saved host, key pinning, the unlock panel and its arm flow |
| `SensoriumIntegrationTestRunner` | Authenticated loopback, recovery scenarios, end-to-end input path |

The script builds and runs all four twice, once in `debug` and once in `release`. An optimized build can release an object at its last use, so assertions that depend on a pipeline's lifetime hold it with `withExtendedLifetime`.

The runners never open a window, start `NSApplication`, bind a socket, capture a screen, inject an event, read a stored key, or touch a display. Every such boundary goes through a fake.

## Pre-publish gate

`Scripts/audit-public-repo.py` runs first, before any runner, as part of `run-unit-tests.sh`. It fails safely if a public-bound repository candidate contains sensitive material, checking tracked files and any nonignored untracked file, and prints only paths and rule categories, never matching content.

## Other verification scripts

| Script | Exercises |
|---|---|
| `Scripts/run-loopback-integration.sh` | The in-process host/client loopback -- pairing, authenticated handshake, canvas lifecycle, input path, recovery scenarios -- over an in-memory transport and a fake display adapter. No socket, no permission |
| `Scripts/verify-tailscale-route.sh` | Prints the `tailscale ping --verbose` command to run by hand before a latency claim, and how to read direct versus DERP-relayed |
| `Scripts/benchmark-session.sh` | A placeholder that does nothing yet and exits non-zero, naming the steps a real benchmark needs, rather than publish a number this project has not measured |
| `Scripts/test-package-apps.sh` | The packager, `Scripts/package-apps.sh`, run only with signing identities guaranteed absent from the machine, so it never touches a real keychain identity |
| `Scripts/test-documentation-status.py` | That README.md and docs/install.md still state the verified local and pending cross-machine boundaries, and do not regress to an earlier, stale claim |

## Test order

Each runner is one `main()` that runs its assertions top to bottom. Nothing depends on that order, except two `SensoriumHostTestRunner` tests that pump the main run loop to model the canvas-readiness wait. Swift's async `main` starts the main run loop once any earlier test suspends on `await`, and a nested pump can no longer get CoreFoundation to service the main dispatch queue, so those two tests run first, each calling `expectRunLoopPumpCanDispatchQueuedWork` before it pumps. A test moved below a suspending one fails, naming that cause.

## Building a runner

`swift build --target <Runner>` compiles but does not link an executable, so a green `--target` build proves nothing about a runner. Use `swift build --product <Runner>` or `swift run`, as the script does.

## Opt-in real-machine smokes

These need a granted Screen Recording or Accessibility permission and a real display, so nothing runs them automatically. Each prints what it did and classifies the host log.

| Script | Exercises |
|---|---|
| `Scripts/run-real-local-video-smoke.sh` | Real capture, encode, decode of one session canvas |
| `Scripts/run-real-local-workspace-input-smoke.sh` | Typed input landing in the canvas workspace |
| `Scripts/run-real-local-resize-smoke.sh` | Viewer-driven stream resolution change |
| `Scripts/run-real-local-focus-release-smoke.sh` | No key held down after a session ends |
| `Scripts/run-real-local-host-screen-smoke.sh` | Host screen arming, presence check, and capture |

Each has a matching `Scripts/test-*.sh` script that checks its own logic without touching hardware. Those run as part of `run-unit-tests.sh`.

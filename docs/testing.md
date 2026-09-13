# How this repository is verified

Four executables assert and exit non-zero on the first failure, instead of XCTest.

## Runners

The toolchain this project targets is Swift from Command Line Tools without Xcode, where `XCTest` and the `Testing` module are not importable.

```sh
./Scripts/run-unit-tests.sh
```

| Runner | Covers |
|---|---|
| `SensoriumCoreTestRunner` | Lifecycle state machine, codecs, pairing, backoff, metrics |
| `SensoriumHostTestRunner` | Canvas ownership, capture guard, input gate, pairing ceremony, ingress policy |
| `SensoriumClientTestRunner` | Viewport, surface events, frame admission, saved host, key pinning |
| `SensoriumIntegrationTestRunner` | Authenticated loopback, recovery scenarios, end-to-end input path |

The script builds and runs all four twice, once in `debug` and once in `release`. An optimized build can release an object at its last use, so assertions that depend on a pipeline's lifetime hold it with `withExtendedLifetime`.

The runners never open a window, start `NSApplication`, bind a socket, capture a screen, inject an event, read a stored key, or touch a display. Every such boundary goes through a fake.

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

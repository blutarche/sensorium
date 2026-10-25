# How this repository is verified

Five executables assert and exit non-zero on the first failure, instead of XCTest.

## Runners

The toolchain this project targets is Swift from Command Line Tools without Xcode, where `XCTest` and the `Testing` module are not importable.

```sh
./Scripts/run-unit-tests.sh
```

| Runner | Covers |
|---|---|
| `SensoriumCoreTestRunner` | Lifecycle state machine, codecs, pairing, backoff, metrics, lock-screen unlock wire messages and outcome tokens |
| `SensoriumHostTestRunner` | Canvas ownership, capture guard, input gate, pairing ceremony, ingress policy, unlock throttle, the loopback RFB unlock client |
| `SensoriumClientTestRunner` | Viewport, surface events, frame admission, saved host, key pinning, locked-host key routing, and that no unlock request is sent |
| `SensoriumIntegrationTestRunner` | Authenticated loopback, recovery scenarios, end-to-end input path |
| `SensoriumUpdateTestRunner` | The macOS update core: manifest, signature, version decision, failure record, staging, swap and handoff, against a local fake of the release page. Signs temporary app bundles ad hoc with `codesign -s -`; makes no network request and launches no app |

The script builds and runs all five twice, once in `debug` and once in `release`. An optimized build can release an object at its last use, so assertions that depend on a pipeline's lifetime hold it with `withExtendedLifetime`.

The runners never open a window, start `NSApplication`, bind a socket, capture a screen, inject an event, read a stored key, or touch a display. Every such boundary goes through a fake.

## Pre-publish gate

`Scripts/audit-public-repo.py` runs first, before any runner, as part of `run-unit-tests.sh`. It fails safely if a public-bound repository candidate contains sensitive material, checking tracked files and any nonignored untracked file, and prints only paths and rule categories, never matching content.

## Other verification scripts

| Script | Exercises |
|---|---|
| `Scripts/run-loopback-integration.sh` | The in-process host/client loopback -- pairing, authenticated handshake, canvas lifecycle, input path, recovery scenarios -- over an in-memory transport and a fake display adapter. No socket, no permission |
| `Scripts/verify-tailscale-route.sh` | Prints the `tailscale ping --verbose` command to run by hand before a latency claim, and how to read direct versus DERP-relayed |
| `Scripts/benchmark-session.sh` | A latency run between the stand-in host on this machine and a Linux viewer over SSH, with scripted pointer motion. See the stand-in section below. Needs a second machine, so nothing runs it automatically |
| `Scripts/test-package-apps.sh` | The packager, `Scripts/package-apps.sh`, run only with signing identities guaranteed absent from the machine, so it never touches a real keychain identity |
| `Scripts/test-release-macos.sh` | The release script `Scripts/release-macos.sh` in a scratch copy, with a stub packager and a generated key: zips, disk images and the window each opens to, the signed manifest, and every refusal. Signs nothing with a real identity |
| `Scripts/test-make-dmg-background.sh` | The disk image backgrounds `Scripts/make-dmg-background.swift` draws for the viewer and the host: a 1x and 2x pair `tiffutil` joins, one window layout for both, identical bytes on every run, two different pictures that draw each machine pixel for pixel the same, a refused unknown role, and a light, clean panel wherever Finder draws an icon and its black label |
| `Scripts/test-make-dmg-layout.sh` | The Finder window file `Scripts/make-dmg-layout.swift` writes into a scratch disk image: icon positions, window size and chrome, the background picture it points at, and that it names no path or disk of the machine that built it |
| `Scripts/test-package-linux.sh` | The Fedora package `Scripts/package-linux.sh` builds: its desktop entry, its metainfo, its icons, the libraries it asks for, and that removing it leaves nothing behind. Runs only inside the CI Fedora container, where installing a package is safe |
| `Scripts/test-documentation-status.py` | That README.md and docs/install.md still state the verified local and pending cross-machine boundaries, and do not regress to an earlier, stale claim |
| `Scripts/test-clean-build-output.py` | `Scripts/clean-build-output.py` against throwaway repositories with a bare remote and agent worktrees: what it removes, every guard that keeps a worktree or a build directory, and that it never follows a symbolic link |

## Cleaning up agent worktrees

Coding agents work in git worktrees under `.claude/worktrees/agent-*`, each on a `worktree-agent-*` branch. A finished agent's worktree stays behind, and its `.build` grows past a gigabyte.

```sh
python3 Scripts/clean-build-output.py [--apply] [--min-idle MINUTES] [--min-free SIZE] [--quiet]
```

Run it from anywhere inside the repository. Without `--apply` it only prints what it would do, why it keeps each item, and how much space it would reclaim.

It removes an agent worktree, then its branch, only when all of these hold:

| Guard | Kept when |
|---|---|
| Lock | The worktree is locked. A running agent's worktree is |
| Changes | `git status` shows a modified, staged or untracked file |
| Commits | Its HEAD is on neither `main` nor any remote-tracking branch |
| Processes | A process works in it or holds a file open in it |
| Build lock | A SwiftPM build holds the lock on one of its `.build` directories |
| Idle | A file in it changed within `--min-idle` minutes, 60 by default. `.build` does not count |

It uses `git worktree remove` and `git branch -d`, so git refuses anything unmerged on its own as well. Worktrees outside `.claude/worktrees` are never touched.

With `--min-free 40G`, and only while the disk has less than that free, it also deletes gitignored `.build` and `DerivedData` directories in unlocked agent worktrees and in the main checkout. Each one is kept while a process works in its checkout or holds a file open in it, while SwiftPM holds its lock, or while a file in it changed within `--min-idle` minutes. The script and the shell that runs it do not count. Any other process working in the main checkout keeps its build output. Work inside an agent worktree does not.

SwiftPM locks a scratch directory for the whole build, with a lock file in the build's temporary directory rather than inside `.build`. The script takes that lock itself while it deletes, so a build that starts meanwhile waits.

A guard it cannot evaluate keeps the item and makes the script exit 1.

## Stand-in host for latency benchmarks

`SensoriumBenchHost` is test scaffolding for an unattended latency run. It is not bundled into either app, and `Scripts/package-apps.sh` does not build it.

It streams synthetic frames through the real host media pipeline (VideoToolbox encoder, admission gates, fidelity control, latency recorder) and over the real QUIC listener to a real viewer on another machine. The picture is a fixed, dense pattern of small text-like rectangles that shifts with the pointer position the viewer sends. A frame is sent only when the picture changed, as ScreenCaptureKit does, so the still-screen refresh runs while the pointer rests.

```sh
SensoriumBenchHost <tailnet-address> <port> --state-dir <dir> --trace <path> [--max-seconds N]
```

It prints `bench-host pairing-code <code>` once at start. Its keys and paired devices live in `--state-dir`. It appends the host stage traces to `--trace`, prints `bench-host session-ended`, and exits after the first session that ends, after `--max-seconds` (default 180), or on SIGTERM.

It never captures or lists a display, calls ScreenCaptureKit or any permission-gated API, creates a private desktop, posts input events, locks or unlocks the screen, holds a display awake, opens a window or menu-bar item, listens on port 7777, touches the clipboard, or reads or writes outside `--state-dir` and `--trace`. It accepts only a tailnet address.

### Running the benchmark

```sh
Scripts/benchmark-session.sh --viewer <ssh-destination> [--runs N] [--ab] [--plan move:20,still:40,move:20] [--seconds 85] [--out <dir>]
```

Run it on the macOS machine that hosts the stand-in. It needs one thing from the other side: an SSH-reachable Linux machine with a Swift toolchain, KWin, `spectacle` and a GPU. That machine is never paired to anything real. The probe keeps its keys and its one paired host in a scratch directory under `--remote-dir` (default `sensorium-bench` in the remote home), and the stand-in keeps its own in the output directory.

What it does:

1. Builds `SensoriumBenchHost` in release mode under `.build/bench`.
2. Copies the source tree to the viewer machine with `rsync` and builds `SensoriumViewerProbe` there.
3. Starts the stand-in on this machine's Tailscale address and pairs the probe with it once, using the pairing code the stand-in prints.
4. For each run, starts a fresh stand-in, runs `SensoriumViewerProbe view` inside a nested virtual KWin (`Scripts/linux-headless-session.sh`) while the pointer follows `--plan`, and waits for it to finish.
5. Prints one line per run: viewer end-to-end, receive and present delays, presented and dropped frames, the longest freeze during motion, the time to the first frame after motion resumes, the stand-in's captured frame count and its encode delay.

With `--ab` each run makes two sessions, one with the viewer's normal release-on-interaction behaviour and one with `--no-interaction-release`. The raw viewer and stand-in logs, the stand-in trace files, the screenshots and the `bench-viewer` JSON of every run stay in `--out`. They contain the real tailnet address, so keep them out of the repository; the script prints addresses as `<addr>`.

The stand-in listens on port 7790 by default and refuses 7777. Interrupting the script stops the stand-in.

### On one machine

```sh
SensoriumBenchHost motion-bench [--size 1773x997] [--plan scroll:2,still:1.5] [--speed 12] [--interaction] [--repeat 3]
```

This runs the host media pipeline and the macOS viewer's decoder in one process. No network, no listener, no permission. The synthetic page is encoded at twice `--size`. It scrolls and rests on `--plan`, and every packet is decoded as the viewer would decode it. `--interaction` also tells the pipeline about viewer scroll input while the page scrolls, as a viewer's scrolling would. It prints the encode delay, the frames encoded a second while scrolling, the delay from capture to decoded frame, the delay from the page starting to move to its first decoded frame, and that delay split into capture, encode and decode. It also prints the median key frame and delta size for each decoded size, the key frames and bytes sent, and the size of the last decoded frame after each rest.

The link, the viewer's presentation and the fidelity controller are not in it. Its numbers compare two builds on the same machine. They are not a session's end-to-end delay.

## Linux

The viewer also runs on Fedora 44 with Wayland. There is no Linux host, so
only the two portable runners apply there.

| Check | What it does |
|---|---|
| `SensoriumCoreTestRunner` | The same suite as on macOS. Nothing in it is platform-specific |
| `SensoriumClientTestRunner` | The portable half of the viewer suite. The Apple-framework tests are skipped by `Entry+Darwin.swift`, which is empty off Darwin |
| `Scripts/test-linux-gui-reachable.sh` | Every capability `docs/ux-spec.md` names is reachable from the Linux window layer. `Scripts/linux-gui-pending.txt` lists the ones not brought over yet, and the script also fails when a pending capability has landed, so the list stays honest |
| `Scripts/test-package-linux.sh` | The Fedora package, installed and removed inside the CI container |

The `linux-build-and-test` job in `.github/workflows/ci.yml` builds the four
Linux products and runs the two runners and the reachability check in a
`fedora:44` container. The `linux-package` job builds the RPM in the same
image and runs the packaging test against it.

Two things need a real compositor, so neither runs in CI:

```sh
Scripts/linux-headless-session.sh -- <command>
SensoriumViewerProbe render-chrome <output-directory>
```

`Scripts/linux-headless-session.sh` runs one viewer command inside a nested
virtual KWin on a private bus and a Wayland socket of its own, then
screenshots it. It refuses to start against the desktop the person running
it is using. `SensoriumViewerProbe render-chrome` paints every session-window
overlay to a PNG without a compositor at all, so the chrome can be looked at
without a session.

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
| `Scripts/run-real-local-host-screen-smoke.sh` | Host screen arming and capture |

Each has a matching `Scripts/test-*.sh` script that checks its own logic without touching hardware. Those run as part of `run-unit-tests.sh`.

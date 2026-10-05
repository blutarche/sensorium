---
name: verify-sensorium
description: Drive and prove Sensorium's two macOS apps (Sensorium viewer and Sensorium Host) the way a user meets them — offscreen renders of every real window and state, the in-process host/viewer loopback, and gated opt-in real-machine smokes — and capture evidence under Artifacts/verify/. Use when a change to either app's UI, pairing, session, host-screen or settings behavior must be shown working, not just unit-tested. The Linux viewer is secondary and noted at the end.
---

# Verify Sensorium

Sensorium is two double-clickable macOS apps: **Sensorium** (the viewer, where the person sits) and **Sensorium Host** (the machine being worked on). Users only click; CLI verbs (`pair`, `serve`, `enter`) exist as test scaffolding. Read `CONTEXT.md` for the product words and `CLAUDE.md` for the safety boundary before anything here.

The machine you are on may be the owner's real host. An installed `/Applications/Sensorium Host.app` may be serving on port 7777 with live pairing records. It is never stopped, restarted, signalled, or connected to by a verification run. Other agent sessions may be running smokes at the same time; `doctor.sh` shows them.

## Three tiers, in order of safety

| Tier | What it proves | Gate |
|---|---|---|
| Renders | Every window and state of both apps, drawn by the production view types | None. Always allowed |
| Loopback | Authenticated handshake of an already-approved viewer, session lifecycle, input path, resize, recovery, over an in-memory transport and a fake display | None. Always allowed |
| Real-machine smoke | Real capture, encode, decode, input injection, host-screen mode change and restore | Explicit approval for an opt-in macOS integration test, plus doctor's smoke verdict |

Outside an approved opt-in macOS integration test, agents do not screenshot or script a live window: `CLAUDE.md` forbids `screencapture` except in such a test. Inside one, an agent may click a live window through an Accessibility grant that already exists and capture it with `screencapture`, but never requests or grants a new permission. When no grant exists, the visual proof is the renders, and the behavioral proof is loopback output or smoke logs. Say which one you used; never present a render as a driven user action.

## Launch

No server to keep alive. Every helper builds what it needs and exits. All Bash calls that run `swift`, a runner, or a helper need `dangerouslyDisableSandbox: true`; sandboxed, the runners hang at 0% CPU and SwiftPM cannot build.

- Renders: `.claude/skills/verify-sensorium/scripts/render.sh <label> [expected.png ...]` — about 40 s warm. Ready when it prints `renderer exit=0` and `N PNGs`.
- Loopback: `.claude/skills/verify-sensorium/scripts/loopback.sh <label>` — builds debug, runs `SensoriumIntegrationTestRunner`. Ready means exit 0.
- Smokes (gated, see Drive): `Scripts/run-real-local-host-screen-smoke.sh`. Ready means it prints `PASS: real local host screen smoke`; `BLOCKED:` (exit 3) is a precondition, not a defect.

## Doctor

```sh
.claude/skills/verify-sensorium/scripts/doctor.sh
```

Read-only. Reports commit and dirty state, whether release products are older than `Sources/`, every running Sensorium process tagged installed / repo build / other, smoke ports 7781 7782 7783 7787 7788, screen lock, active display count, tailnet address present (never printed), and the owner's last host-screen log line (addresses redacted). Last line: `real-machine smoke: NO (<reasons>)` or `preconditions met`. Run it first, and again whenever anything looks off. A `REPO BUILD` process you did not start belongs to someone else: leave it and report it.

## Drive

### Renders (the GUI harness)

`render.sh` runs `swift Scripts/render-ui-previews.swift <dir>`, which constructs the real `NSView`s from `Sources/` in each state and draws them offscreen. Pass the file names that prove your feature; the helper fails on a missing file or one whose `non-bg` (fraction of non-background pixels) is 0. To check more files against a render already made this session, skip the 40 s render with `render.sh --check <evidence-dir> <file.png> ...`.

```sh
.claude/skills/verify-sensorium/scripts/render.sh rename viewer-rename-1.png host-rename-sheet.png
```

Then open the PNGs with the Read tool and look at them. `previews/index.txt` names every file with the exact state it shows and lists what is not rendered (menus: their content is pure and covered by `SensoriumClientTestRunner`). File name prefixes:

- `host-window-*` Host setup window states. `host-menu-panel-*` host menu-bar panel. `host-rename-sheet`.
- `host-screen-badge-*` the on-host "being viewed" indicator. `host-screen-presence-prompt-*` the ask-first prompt.
- `viewer-machines-*`, `viewer-add-*`, `viewer-rename-*`, `viewer-identity-*` the Your Machines window.
- `viewer-status-*` session status overlays. `viewer-hud-*` stream HUD. `viewer-shortcuts-*` shortcut strip. `viewer-notice-*` display-menu refusal banners.
- `host-launcher-*`, `host-workspace-content-*` the private-desktop (session canvas) workspace; the launcher lists this machine's real `/Applications`.

Files with `-natural`/`-stream1.0x`/`-stream1.5x` are canvas content resampled to stream sizes; viewer-local UI has a single pass.

A new UI state counts as verified only if a render of it exists. If the state you changed is not in `index.txt`, add it to `Scripts/render-ui-previews.swift` (delegated, like any shipping change) rather than describing it.

### Loopback

```sh
.claude/skills/verify-sensorium/scripts/loopback.sh pairing
```

Proof is exit 0 and its `PASS:` lines in `loopback.log`. It drives the real host and viewer controllers against each other, not the windows, and it does not pair: the pairing ceremony's wire is covered by `SensoriumCoreTestRunner` and `SensoriumHostTestRunner` (`./Scripts/run-unit-tests.sh`), and live by the host-screen smoke's first step.

### Real-machine smokes (opt-in only)

Run one only when the task explicitly approves an opt-in macOS integration test. Preconditions, all checked by `doctor.sh` except the last two:

1. Screen unlocked and a display active. Never unlock it, never type a password.
2. Ports 7781, 7782, 7783, 7787, 7788 free; a tailnet address present.
3. The packaged host `Artifacts/Sensorium/Sensorium Host.app` holds Screen Recording and Accessibility. A rebuild with a different signature leaves a stale grant that looks on but is not; see `docs/install.md`.
4. Nobody using the machine: the host-screen smoke waits up to 15 minutes for 5 minutes of input idle before it starts.

Every smoke points each process at a throwaway home with both `HOME` and `CFFIXED_USER_HOME` (`HOME` alone does not move Foundation's Application Support directory), and none binds 7777; `Scripts/assert-smoke-isolated.sh` enforces both in every smoke's contract test. Pick the smoke that matches the claim. `Scripts/run-real-local-host-screen-smoke.sh` binds port 7783, pairs a probe, writes the arming record inside that throwaway home, streams this machine's display, moves the pointer, types into a probe window, changes the display mode, restores it, and compares the display inventory before and after.

The other four are session-canvas smokes: `video` (port 7782, capture to presented frame), `workspace-input` (7781, typing lands in the canvas workspace), `resize` (7787, viewer-driven stream resolution) and `focus-release` (7788, no key left held after a session). Each creates a virtual display. A host stopped mid-session can leave that display behind until logout, so let each script end on its own and never interrupt it. Before running any smoke, confirm `Scripts/assert-smoke-isolated.sh <smoke>` exits 0.

After any smoke, before anything else:

```sh
.claude/skills/verify-sensorium/scripts/keep-smoke-evidence.sh host-screen <label>
```

## Evidence

Everything goes under `Artifacts/verify/<UTC timestamp>-<label>/` (inside the repo, ignored by Git). Each helper writes `commit.txt` there and prints the directory on its last line. Evidence holds no address or machine name: `keep-smoke-evidence.sh` and `doctor.sh` redact IPv4 addresses, `*.local`/`*.ts.net` names and this machine's own name, and doctor prints only the outcome of the owner's session log; renders use invented machines only.

Proof standards:

- Name the tier. A render proves how a state looks; loopback proves the protocol and controller behavior; only a smoke proves real capture, injection and display handling.
- Show the action and the result: for a flow, the render before and after (for example `viewer-machines-2-list.png` then `viewer-rename-1.png`), or the log lines of the request and its effect.
- Check side effects, not only pictures: smoke logs `host screen started for`, `host-screen capture started`, `host_screen_frames=N`, `pointer_moved=yes`, `text_typed=yes`, `mode_restored=...`, and an unchanged display inventory.
- Look at every PNG you cite. `non-bg > 0` only proves it is not blank.
- Report every tier you skipped and why (for example, smoke blocked: screen locked).

## Cleanup

- Renders and loopback leave no process. Nothing to stop.
- Smokes stop their own host through an exit trap. Afterwards `keep-smoke-evidence.sh` must report `no repo-built Sensorium process running`. If it lists a pid this run started, first check its log: the last `connected` line must be followed by `disconnected` (stopping a host mid-session can strand a virtual display until logout). Then `kill -TERM <that pid>` and rerun the helper. Never kill by name, never use SIGKILL, never touch an `/Applications/...` process or a pid you did not start.
- Smoke state under `.build/real-local-*-smoke` may stay; the next run of that smoke wipes it. Never delete `Artifacts/verify/`.
- If a display mode or display count changed and was not put back, stop and report it. Do not try to repair a display.

## Linux viewer (secondary)

The viewer also runs on Fedora 44 Wayland. Compile and unit-test in a `fedora:44` container (see `.github/workflows/ci.yml`). Visual checks run inside a nested virtual KWin with `Scripts/linux-headless-session.sh -- <command>`, and session chrome renders without a compositor with `SensoriumViewerProbe render-chrome <dir>`; both need a Linux machine and are out of this skill's macOS recipes.

## Feature map

`features/README.md` indexes one recipe per user-facing feature. A proof that drives one convenient entry point is incomplete when the map lists others.

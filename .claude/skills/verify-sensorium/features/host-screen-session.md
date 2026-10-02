# Host screen session

A paired, armed viewer sees and controls one of the host's own displays. While it is live the host shows an unmissable indicator naming the viewer, with a Stop control, and keeps a record of the session. With ask-first on, someone who used the host recently is asked and must agree. The viewer may change the display's resolution among the modes macOS offers; the original mode is restored when the session ends.

## Sub-features

- `hs-start` the session starts on the host screen and frames reach the viewer.
- `hs-input` the viewer's pointer and keys reach the host display.
- `hs-indicator` the on-host badge: expanded at start, shrunk, collapsed to a pill.
- `hs-ask-first` the presence prompt: Allow / Don't Allow, thirty-second timeout.
- `hs-refusals` the viewer's sentence when a host-screen connect never becomes a session.
- `hs-mode` a requested display mode is applied and the previous one restored.
- `hs-record` the host's last-session record, clean or reconciled after a crash.

## How to get to it (user POV)

- Viewer: Your Machines, pick a paired machine. It starts on the host screen when one is offered.
- Viewer, live session: the Resolution menu to change the display mode; the Screen menu to switch screens.
- Host: the badge appears on its own; Stop is on the badge and in the host window.

## Driving it with verify-sensorium

Preconditions:

- Baseline from `README.md`.
- For `hs-start`, `hs-input`, `hs-mode` live: an approved opt-in integration test, doctor's `preconditions met`, and the packaged host holding Screen Recording and Accessibility.

- **Indicator.** A session starts. Run `.claude/skills/verify-sensorium/scripts/render.sh host-screen host-screen-badge-1-expanded.png host-screen-badge-2-shrunk.png host-screen-badge-3-collapsed.png host-screen-presence-prompt-1-short.png host-screen-presence-prompt-2-long-device-name.png host-screen-presence-prompt-3-long-display-label.png host-window-7-connected-host-screen.png host-window-12-last-session-clean-stop.png host-window-13-last-session-not-clean.png viewer-status-6-ended-not-allowed-natural.png viewer-status-7-ended-presence-check-required-natural.png viewer-status-8-ended-presence-declined-natural.png viewer-status-10-ended-display-unavailable-natural.png viewer-status-13-ended-session-active-natural.png`. All `ok:`. The badge names the viewer and offers Stop in each of its three sizes.
- **Ask first.** Read the three `host-screen-presence-prompt-*` files. Each names the device and display, offers Allow and Don't Allow (the default), and says `Don’t Allow will be chosen automatically in 0:30.`; long names wrap inside the panel.
- **Refusals at viewer.** Read the `viewer-status-*-ended-*` files. Each says in plain words why nothing is shown (not allowed, declined, display unavailable, already in use).
- **Record.** Read `host-window-12-...` and `-13-...`. Device, display and times; the crash case says it has no stop time rather than inventing one.
- **Live stream, input and mode (opt-in).** Run `Scripts/run-real-local-host-screen-smoke.sh` unsandboxed, then `.claude/skills/verify-sensorium/scripts/keep-smoke-evidence.sh host-screen live`. Exit 0 and `PASS: real local host screen smoke`. `host.log` contains `host screen started for` and `host-screen capture started`; the script prints `host_screen_frames=` above 0, `pointer_moved=yes`, `text_typed=yes`, `mode_applied=` not `no`, `mode_restored=` not `no`; `display-inventory-pre.json` and `-post.json` match.
- **Logic.** Run `./Scripts/run-unit-tests.sh` (unsandboxed). No `FAIL`; the `HostScreen*` groups in the Host runner cover arming, ask-first, indicator, mode restore and the session log.

## Gotchas

- A locked screen makes the smoke report `text_typed=no` and stream the lock screen. Doctor catches it; never unlock.
- Exit 3 with `BLOCKED:` means someone used the machine recently, a permission is missing, or the display is asleep. Report it; do not retry in a loop.
- The smoke waits up to 15 minutes for idle input. Run it in the background and do not touch the machine meanwhile.
- The smoke changes the real display's mode and must put it back. If `mode_restored` is missing or the inventories differ, stop and report; do not attempt a repair.
- Arming in the smoke is written straight into the throwaway home by the probe. It does not prove the host window's sharing switch; that is the Host runner's `PairedMachinesSharingToggleTests`.

# Session chrome

Everything the viewer draws on its own screen over a live session: the status overlay while connecting, after a drop, while reconnecting, or when it gives up; the stream HUD with decode path, scale and what limits fidelity; the shortcut strip that sends system shortcuts to the host and confirms disruptive ones; and short banners when a display request is refused.

## Sub-features

- `chrome-status` connecting, connecting after a failure, lost, reconnecting, gave up, unverified host.
- `chrome-hud` healthy, held below the asked scale, old host, stale, software decoder, pointer captured, clamped choice, fidelity limited by link or by encoder.
- `chrome-hud-layering` the HUD over the canvas, and under the status panel when the session is lost.
- `chrome-shortcuts` handle only, opened, pinned, confirming Lock Screen.
- `chrome-notices` refusal banners: host screen active, over the host's limit, creation in progress, change failed, unknown reason.

## How to get to it (user POV)

- Connect to a machine from Your Machines; the status overlay shows until the first frame.
- View menu, Session Diagnostics, for the HUD.
- Hover the handle at the top centre of the session window for the shortcut strip.
- Displays or Resolution menu, a choice the host cannot honour, for a banner.

## Driving it with verify-sensorium

Preconditions:

- Baseline from `README.md`.

- **Connecting.** Pick a machine. Run `.claude/skills/verify-sensorium/scripts/render.sh chrome viewer-status-1-connecting-natural.png viewer-status-1b-connecting-after-failure-natural.png viewer-status-2-lost-natural.png viewer-status-3-reconnecting-natural.png viewer-status-4-gave-up-natural.png viewer-status-15-unverified-host-natural.png viewer-hud-1-healthy.png viewer-hud-5-software-decoder.png viewer-hud-6-over-canvas.png viewer-hud-7-under-session-panel.png viewer-hud-10-fidelity-limited.png viewer-shortcuts-0-handle.png viewer-shortcuts-1-shown.png viewer-shortcuts-1b-pinned.png viewer-shortcuts-2-confirming-lock.png viewer-notice-1-host-screen-active.png viewer-notice-4-change-failed.png`. All `ok:`. `viewer-status-1-...` reads "Connecting to workstation…" (the renderer names its machine "workstation").
- **Drop and recover.** Read `viewer-status-2-lost-...`, `-3-reconnecting-...`, `-4-gave-up-...` in order. The last frame stays underneath; the words move from lost to reconnecting to cannot reach.
- **Unverified host.** Read `viewer-status-15-unverified-host-natural.png`. `Could not connect to workstation.` explains the key did not match the one saved at pairing; the only buttons are Quit Sensorium, Your Machines and Pair Again, with no way to connect anyway.
- **HUD.** Choose View, Session Diagnostics. Read `viewer-hud-1-healthy.png`, `-5-software-decoder.png`, `-10-fidelity-limited.png`. Each names the decode path and what limits the picture.
- **Layering.** Read `viewer-hud-6-over-canvas.png` and `-7-under-session-panel.png`. The status panel and its buttons sit above the HUD.
- **Shortcut strip.** Hover the handle, open, pin, press Lock Screen. Read `viewer-shortcuts-0-...` through `-2-...` in order. The last replaces the row with one confirmation question.
- **Banners.** Read `viewer-notice-1-...` and `-4-...`. One sentence each, sized to fit.
- **Live chrome (opt-in).** No smoke drives the overlays on a window. The HUD, strip and overlay logic is covered by `./Scripts/run-unit-tests.sh` (unsandboxed, no `FAIL`): `SessionHUDRowLayoutTests`, `ShortcutStripTests`, `SessionChromeLayoutTests`.

## Gotchas

- Files with `-natural` sit over a synthetic frame; `-stream1.0x`/`-stream1.5x` versions exist for canvas content only. Viewer-local chrome never crosses the wire, so cite the single-pass file.
- The connecting overlay is opaque, so its stream passes are identical to the natural one by design.
- Menus (View, Resolution, Displays, Screen) have no render. Do not claim one was looked at.
- "private desktop" is the product's only name for a session-owned display; "virtual display" and "canvas" must never appear in a PNG. Seeing either is a defect.

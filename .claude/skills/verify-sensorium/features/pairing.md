# Pairing

The person at the host reveals a six-digit pairing code in Sensorium Host; the person at the viewer adds the machine, picked from their tailnet or typed by address, and types the code. From then on the viewer is trusted and armed for the host's screens without a code. A wrong or expired code is refused in words the person can act on.

## Sub-features

- `pair-reveal-code` the host shows a code with a countdown on request, and hides it again.
- `pair-picker` the viewer's add step lists tailnet devices, online and offline.
- `pair-picker-states` loading, Tailscale unreachable, Tailscale not installed, no other devices.
- `pair-code-entry` code field for a picked machine, with an optional name.
- `pair-manual-address` typing an address by hand adds an address field above the code.
- `pair-refused` the host refuses the code and the viewer says why.
- `pair-live` a real pairing over the network, followed by a session without a code.

## How to get to it (user POV)

- Host: Sensorium Host window, Show pairing code. Also the host's menu-bar panel while a code is live.
- Viewer: Your Machines, Add a Machine, pick a device or type an address, type the code.

## Driving it with verify-sensorium

Preconditions:

- Baseline from `README.md`.
- For `pair-live` only: an approved opt-in integration test and doctor's `preconditions met`.

- **Reveal code at host.** Choose Show pairing code. Run `.claude/skills/verify-sensorium/scripts/render.sh pairing host-window-3-ready-no-machines-paired.png host-window-4-pairing-code-shown.png host-menu-panel-3-pairing.png viewer-add-1-picker.png viewer-add-1b-picker-loading.png viewer-add-1c-picker-tailscaled-unreachable.png viewer-add-1d-picker-tailscaled-unreachable-tailscale-installed.png viewer-add-1e-picker-tailscale-not-installed.png viewer-add-1f-picker-no-other-devices.png viewer-add-2-code.png viewer-add-3-code-manual.png viewer-add-4-pairing-failed.png`. All `ok:`. Compare `host-window-3-...` (button) with `host-window-4-...` (six digits and a countdown in its place).
- **Pick a machine at viewer.** Choose Add a Machine. Read `viewer-add-1b-picker-loading.png` then `viewer-add-1-picker.png`. One online and two offline devices are listed.
- **Picker failures.** Read `viewer-add-1c-...`, `-1d-...`, `-1e-...`, `-1f-...`. Each says what is wrong and offers the one way on (Open Tailscale where it is installed).
- **Type the code.** Read `viewer-add-2-code.png`, and `viewer-add-3-code-manual.png` for the typed-address path. The manual path adds an address field above the code.
- **Wrong code.** Read `viewer-add-4-pairing-failed.png`. `Wrong code.` in red under the code field's hint, then `Check the six digits on <machine> and try again.`; the typed code and the optional name stay filled, with Pair and Back.
- **Protocol.** Run `./Scripts/run-unit-tests.sh` (unsandboxed). No `FAIL`; `PairingProtocolTests`, `HostConnectionAndPairingTests` and `PairingSignatureRequirementTests` cover code expiry, signed requests and refusal reasons.
- **Live pairing (opt-in).** Run `Scripts/run-real-local-host-screen-smoke.sh`, then `.claude/skills/verify-sensorium/scripts/keep-smoke-evidence.sh host-screen pairing`. `host.log` contains `Pairing code:` and `probe.log` contains `host_screen_probe_paired=yes`; the later `enter` step connects with no code.

## Gotchas

- The live smoke pairs a probe, not the Sensorium.app window, through the packaged host's `pair` verb. It proves the ceremony and the wire, not the add-machine window.
- No wire message creates or widens arming. The smoke writes the arming record inside its throwaway home through the host's own store; that is a stand-in for the host-side switch, not a pairing feature.
- A pairing code expires. A slow manual step yields `invalid-code`-style refusals that are correct behavior.
- Never pair anything with the installed host on port 7777.

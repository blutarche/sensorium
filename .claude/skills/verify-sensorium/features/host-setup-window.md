# Host setup window

Opening Sensorium Host shows its one window: whether this machine is reachable on the tailnet, what permission is missing and a button that opens it, who is connected with a Stop button, the paired machines with each one's sharing state and a Rename action, and how the last host-screen session ended. A menu-bar panel mirrors the live state.

## Sub-features

- `host-no-address` no tailnet address found; Open Tailscale when it is installed.
- `host-ready` reachable, nobody connected, Show Pairing Code offered, with the four setting checkboxes.
- `host-permission` Screen Recording not granted, with a button that opens the permission.
- `host-connected` a connected viewer, on a private desktop or a host screen, with Stop.
- `host-paired-list` paired machines: empty, one blocked, two, named and unnamed, two displays with the same name, armed with no display list.
- `host-rename` Rename on a paired machine opens a sheet holding its current name.
- `host-last-session` the last host-screen session, clean stop or reconciled after a crash.
- `host-identity` the host cannot read its own key and offers Try Again and Make a New Key.
- `host-menu-panel` the menu-bar panel: hosting, pairing, serving, permission missing.

## How to get to it (user POV)

- Double-click Sensorium Host.app on the host. The window opens itself.
- Click the Sensorium Host menu-bar item for the panel.

## Driving it with verify-sensorium

Preconditions:

- Baseline from `README.md`.

- **Window states.** Open the host. Run `.claude/skills/verify-sensorium/scripts/render.sh host-window host-window-1-no-address-found.png host-window-3-ready-no-machines-paired.png host-window-6-connected.png host-window-7-connected-host-screen.png host-window-8-screen-recording-not-granted.png host-window-9-paired-machines-none.png host-window-10-paired-machines-one-blocked.png host-window-11-paired-machines-two.png host-window-12-last-session-clean-stop.png host-window-13-last-session-not-clean.png host-window-14-no-address-tailscale-installed.png host-window-15-identity-needs-replacing.png host-window-17-paired-machines-named-and-unnamed.png host-window-18-paired-machines-same-name-displays.png host-window-19-paired-machines-armed-without-displays.png host-window-20-connected-with-pairing-code.png host-rename-sheet.png host-menu-panel-2-hosting.png host-menu-panel-3-pairing.png host-menu-panel-4-serving.png host-menu-panel-5-permission-missing.png`. All `ok:`.
- **Missing permission.** Read `host-window-8-screen-recording-not-granted.png`. `Screen Recording is not allowed.` under a `SCREEN RECORDING NEEDED` eyebrow, and an `Open Screen Recording Settings` button above Show Pairing Code.
- **Connected and stop.** Read `host-window-6-connected.png` and `host-window-7-connected-host-screen.png`. Each names the connected machine and shows Stop; the host-screen one is visibly distinct.
- **Paired machines.** Read `host-window-9-...` through `-11-...` and `-17-...` through `-19-...`. A machine with Share host screen off shows its key alone on the bottom line; same-named displays are told apart by position.
- **Rename.** Choose Rename on the first paired machine. Compare `host-window-11-paired-machines-two.png` with `host-rename-sheet.png`. The sheet's field holds that machine's current name.
- **Rename and settings logic.** Run `./Scripts/run-unit-tests.sh` (unsandboxed). No `FAIL`; `PairedMachineRenameTests`, `PairedMachinesSharingToggleTests`, `HostPrivateDesktopSettingTests` and `HostLocalNetworkSettingTests` cover what each control stores.
- **Menu-bar panel.** Read `host-menu-panel-2-...` through `-5-...`. The serving panel names the connected machine; the permission panel names what was revoked.

## Gotchas

- `host-window-2` and `-16` do not exist; numbering has gaps. Use the names in `index.txt`.
- These are renders. The live window on the owner's host is never opened, clicked, or quit for verification.
- The four checkboxes `Open at login`, `Install updates automatically`, `Offer a private desktop` and `Allow connections from this network` render in every state. In the ready states the first two are checked and the last two are not; `Offer a private desktop` is checked in the connected renders. What toggling them stores is proven only by the Host runner.
- The window is 360 pt wide at its content height; a clipped row in the PNG is a real layout defect.

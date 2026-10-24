# Your Machines window

Opening Sensorium on the viewer shows Your Machines: every host this machine has paired with, most recently connected first, each with its name and the address it was paired at. The person picks one to connect, cancels a dial in progress, or renames a machine; an empty list offers Add a Machine.

## Sub-features

- `machines-empty` nothing paired yet: one sentence and the accent Add a Machine button.
- `machines-list` saved machines, most recent first, with address and tailnet status.
- `machines-connecting` the dialling row's status reads connecting… and it offers Cancel; other rows stay usable.
- `machines-failed` a failed attempt says why (for example, no answer) and keeps Cancel while the retry is pending.
- `machines-rename` Rename puts the current name in a field with Rename and Cancel beneath.
- `machines-unnamed` a machine paired without a name shows its address instead.
- `machines-long-name` names and addresses longer than the row truncate inside it.
- `identity-unreadable` an unreadable key file offers Try again, then Make a new key.

## How to get to it (user POV)

- Double-click Sensorium.app on the viewer. The window opens itself.
- Viewer app menu: Your Machines…, from a session window.
- A row's menu: Rename… (next to Pair Again).

## Driving it with verify-sensorium

Preconditions:

- Baseline from `README.md`.
- Nothing else; renders need no paired machine and no host.

- **Empty list.** First launch with nothing paired. Run `.claude/skills/verify-sensorium/scripts/render.sh machines viewer-machines-1-empty.png viewer-machines-2-list.png viewer-machines-3-connecting.png viewer-machines-4-failed.png viewer-rename-1.png viewer-machines-5-one-unnamed.png viewer-machines-6-several-selected.png viewer-machines-7-long-name.png viewer-identity-1-key-unreadable.png`. Every line of `expected.txt` reads `ok:`. `viewer-machines-1-empty.png` shows one sentence and Add a Machine.
- **List.** Two saved machines. Read `viewer-machines-2-list.png`. Two rows, each with a name, an invented `*.tail1234.ts.net` address and online/offline status, newest first, each with a `…` menu button; Add a Machine below.
- **Connect, then cancel.** Choose a row. Read `viewer-machines-3-connecting.png`. That row's status reads `connecting…` with a yellow dot, and a Cancel button appears beside its `…` button.
- **Failed dial.** Read `viewer-machines-4-failed.png`. The row's status reads `no answer` and Cancel stays until the retry dials.
- **Rename.** From the list, choose Rename… in the first row's menu. Compare `viewer-machines-2-list.png` (before) with `viewer-rename-1.png` (after). Heading `Rename this machine`, the field holding the current name, a line saying only this machine uses the name, Cancel and Rename beneath.
- **Rename persists.** Run `./Scripts/run-unit-tests.sh` (unsandboxed). Its Client runner includes `SavedHostRenameTests` and prints no `FAIL`; it is the only check that the new name is written to the saved-host store, since no live window can be driven here.
- **Key unreadable.** Read `viewer-identity-1-key-unreadable.png`. Try again and Make a new key are offered; no command-line flag is named.

## Gotchas

- A render is constructed state, not a click. Say "render" when citing it.
- The renderer uses invented machines; any real machine name or address appearing in a PNG is a defect to report, not evidence.
- The window's title bar is macOS's and is not in the PNG; the image is the content view at 460 pt wide.
- The Your Machines… menu item and each row's menu are NSMenus and have no render; their plan types are covered by the Client runner.

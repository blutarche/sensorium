# macOS permissions

## Each app's own key

Both apps keep a key that identifies the machine they run on, in `device-identity.json` under `~/Library/Application Support/Sensorium`. The host keeps a second key there, `host-tls-identity.json`, which holds the certificate the viewer pins when the two machines pair. Each file is readable by its owner only. macOS asks for no permission to read them, so a rebuild changes nothing about them.

If a file cannot be read, the app shows its own window with **Try again** and **Make a new key**. Click **Try again** first. Only click **Make a new key** if the key is really lost, since it replaces the key and the two machines must pair again.

## Host

Sensorium Host needs three permissions, and can use a fourth macOS service for one opt-in feature. Grant the permissions in System Settings.

| Permission or service | Used for | Checked by the app |
|---|---|---|
| Screen Recording | Capturing the session canvas it streams | Yes |
| Accessibility | Injecting mouse and keyboard input | Yes |
| Remote Desktop | Apple's gate on unattended remote access | No. macOS has no API for it. |
| Screen Sharing (Remote Management, System Settings) | macOS's own built-in service, spoken over loopback to type the login password during an opt-in lock-screen unlock | No. Not checked or required unless lock-screen unlock is used. |

Without Accessibility the host still streams video. It only refuses input.

Screen Sharing is off by default and is entirely the host operator's own choice to turn on, for [lock-screen unlock](host-screen-design.md). Turning it on makes it listen on every interface, not loopback alone; Sensorium only ever connects out to it, on `127.0.0.1`, and opens no listener of its own for it. See [the threat model](threat-model.md).

### Waking the screen

macOS draws nothing to a sleeping display. A session that started against a host whose screens had idled would stream a picture that never arrives, so the host wakes them when a session starts and keeps them awake while it runs.

This needs no permission. It uses public power management only. The screen that comes on is the one the session streams. Nothing about the display's resolution, arrangement, or mirroring changes, and a machine that is itself asleep stays asleep.

While a session is live, macOS reports Sensorium as the reason the screen stays on, under the name "Sensorium session is live". When the session ends, the host lets the screen idle again exactly as it did before.

If a screen does not come back within five seconds, the host says so and refuses to share it.

### Grants expire

macOS ties a grant to the exact binary. Rebuilding the app drops the grant. Since macOS Sequoia, grants also expire about weekly and after a restart.

The host checks both permissions every 30 seconds while it runs. A lost permission logs which System Settings pane to reopen.

## Viewer

The viewer needs no permission to run. It needs Accessibility only to forward shortcuts macOS reserves for itself.

| Permission | Used for | Checked by the app |
|---|---|---|
| Accessibility | Watching for reserved shortcuts before macOS acts on them, so they reach the host instead | Yes, prompting once |

The viewer asks for this permission once per run, at the first session start, and never prompts again until the app is relaunched. Because macOS's own approval dialog is asynchronous, a decline does not end the ask: the viewer keeps watching for the grant, and forwarding starts as soon as it is given, with no reconnect needed. The viewer shows its shortcut routing mode and Accessibility status before the first keystroke.

If the viewer asks for Accessibility again after the toggle is already on, the row in System Settings belongs to an older build signed differently. Remove that row, or run `tccutil reset Accessibility com.sensorium.viewer`, then relaunch the viewer and grant the one prompt.

### Shortcut routing

| Mode | Reserved shortcuts act on |
|---|---|
| `local` | The viewer machine. Nothing is forwarded. |
| `remote-when-focused` (default) | The host, whenever a viewer window has key focus. |
| `remote-in-fullscreen` | The host, only while a viewer window is fullscreen. |

The default forwards these shortcuts to the host as soon as a viewer window has key focus, windowed or fullscreen, the same as ordinary typing already does. Control-Option-Command-Escape is always the way back to the local machine.

Without the grant, these still forward in a remote mode, since they need no permission: Cmd-Q, Cmd-W, Cmd-H, Cmd-M, and ordinary typing.

These reserved shortcuts stay on the viewer machine without the Accessibility grant, or in `local` mode: Cmd-Tab, Cmd-Shift-Tab, Cmd-Space, Cmd-` and Cmd-Shift-`, and Ctrl-Up, Ctrl-Down, Ctrl-Left, Ctrl-Right.

**Control-Option-Command-Escape** returns the person to the machine in front of them. It leaves fullscreen, hides the viewer, and releases anything the session canvas still holds. No mode forwards it.

Cmd-Q forwards under the same condition as the shortcuts above: whenever a viewer window has key focus by default, or only while fullscreen if the mode was changed to `remote-in-fullscreen`. In `local` mode it stays on the viewer machine.

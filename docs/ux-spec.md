# Sensorium user interface specification

This document says what each of the two apps shows and who decides what.

## The one rule

The person is at the viewer. The host is an unattended machine.

The host decides permission only: which machines may connect, whether a connected machine may see one of its host screens, and whether a viewer may open a private desktop.

The viewer decides everything else about a session: how many displays, their resolution, a host screen or a virtual display, and clipboard sharing. These apply while the session runs, not at the next launch.

A setting on the host that shapes a session is a defect. So is a choice the viewer cannot make from its own window, or text that names a command, a flag, a file path, or an internal state.

## Sensorium Host

A menu-bar app with one window. No settings window.

### Window contents

Top to bottom:

1. **Status.** One line, showing one of:
   - *Ready*, shown when nothing is connected.
   - *Waiting for `<machine name>` to finish pairing*.
   - *Connected to `<machine name>`*, with a **Stop** button.
   - An actionable failure: Screen Recording not granted, with a button opening the permission, or Tailscale not running.
   - *Quit Sensorium Host and open it again*. This outranks every other line once this machine stops handing the host any picture.
2. **Pairing code.** Six digits in two groups of three, large, with **Hide Code** beneath them. Shown the moment a new machine asks to pair. Otherwise a **Show Pairing Code** button shows instead, never replacing the connected machine or its **Stop** button.
3. **Paired machines.** One row per machine, named by the name it gave when it paired or the name chosen for it with **Rename**, never a key fingerprint. A machine with neither is titled **Unnamed machine**. Each row has:
   - The name, with **Rename** and **Remove** right-aligned. Removing a machine ends every connection it has at once and refuses it from then on until it pairs again.
   - **Rename** opens a small sheet: a field holding the current name (empty for an **Unnamed machine**), **Cancel** and **Rename**. Return renames and Escape cancels. The name is trimmed, loses any invisible or text-reversing characters, becomes one line, and is kept to 64 characters. An empty name puts back the name the machine reports. The name is kept on this machine only. It is what the host shows everywhere it names that machine: this list, the status line, the menu bar, the ask-first prompt, the badge and the session record. The name a machine reports when it connects or pairs again never replaces it. Renaming changes nothing about what the machine may do.
   - **Share host screen**. It arms the machine, not one screen, and a line beneath it names the screens this machine can share right now.
   - **Ask me first if this machine is in use**, shown while sharing is on, off by default.
   - A line naming its key fingerprint, on every row, and why sharing is or is not available now.
4. **Last screen session.** Machine, display, and when, if there has been one.
5. **Open at login.** A checkbox, on by default, so an unattended host comes back reachable after a restart; turning it off is the person at the host's own choice and stands until they change it again.
6. **Install updates automatically.** A checkbox, on by default. Beneath it, one line says where updates stand:
   - *Sensorium Host `<version>`, up to date*.
   - *Sensorium Host `<new version>` will install when no machine is connected*.
   - *Sensorium Host could not update: `<reason>`. It keeps running `<version>`.* The only line drawn in the warning colour.
   - *Move Sensorium Host to Applications and open it again to receive updates.*
7. **Offer a private desktop.** A checkbox, off by default. While it is off, the host creates no session canvas, and a viewer can only work on a host screen. A host with no monitor still creates its sharp screen for a host-screen session, as [Host screen mode](host-screen-design.md#10-a-host-with-no-monitor) explains. A viewer sees it as a host screen.
8. **Allow connections from this network.** A checkbox, off by default. It lets a viewer on the same Wi-Fi or wired network connect by name, such as `mini.local`, without Tailscale. Anyone on that network can then ask to pair.

### Menu bar

The status item mirrors the status line. It names the connected machine while a session runs, and offers Stop. Its menu also offers **Check for Updates…**.

### While a host screen is being streamed

An unmissable badge sits on the display being streamed, naming the connected machine, with Stop, draggable anywhere on that display. Clicking it anywhere but Stop collapses it to a small pill with the same name and Stop button, tooltipped with the display's name. Position and collapsed state are remembered per display. It floats above every other window.

## Sensorium (viewer)

### Your machines

Launching opens one window, the only one until a picture arrives. It shows the heading *Your machines*, every paired machine, and **Add a Machine**.

Each machine row shows:

| Field | Content |
| --- | --- |
| Name | Given when it paired, or the name chosen with **Rename…** |
| Address | The paired address |
| State | *online* or *offline* |

Rows are ordered most recently connected first. With nothing paired yet, the list is replaced by *No machine is paired with this one yet. Choose Add a Machine to pair with one.*, and **Add a Machine** is the only action.

Nothing is dialled until a row is clicked. One click connects. Return connects the selected row. While an attempt is out, the row appends *connecting…* or *stopping…* with a pulsing dot and offers **Cancel**. Other rows stay clickable, and clicking one stops the attempt already out. A failed attempt keeps a short reason, with the full explanation in the status panel.

Each row also offers **Pair again**, **Rename…** and **Forget**, from a right-click or its **…** button. **Rename…** replaces the window's list with a short step: a field holding the current name, **Rename** and **Cancel**. Return renames and Escape cancels. The name is trimmed, loses any invisible or text-reversing characters, becomes one line, and is kept to 64 characters. An empty name puts back the one pairing gave the machine, which is its address when it was paired by address. The name is kept on this machine only and is never sent to the other one, and it shows everywhere the viewer names the machine. Pairing the machine again keeps it. Forgetting removes the entry and changes nothing on the machine it named. A row whose last host-screen attempt, tried through this machine's own **Start with** preference, failed to connect adds **Connect to a Private Desktop**, the one explicit retry on a private desktop.

There is no Quit button here. Command-Q quits, and closing the window is the same choice. **Your machines…** (Control-Option-Command-1) opens it at any time.

When a newer Sensorium has downloaded, the window shows one line beneath the list: *Sensorium `<version>` is ready.*, with **Restart Now** while no session window is open. Otherwise the update installs the next time Sensorium quits. The Sensorium menu offers **Check for Updates…** and **Check for Updates Automatically**, which is on by default. With it off, Sensorium asks for nothing until **Check for Updates…** is chosen.

**Check for Updates…** brings this window forward. The line reads *Checking for updates…*, then *Sensorium `<version>` is up to date.* until the window is shown again. A check that cannot reach the release page leaves the line empty. An update that fails reads *Sensorium could not update: `<reason>`.* A copy that cannot replace itself, such as one opened from the Downloads folder, reads *Move Sensorium to Applications and open it again to receive updates.*

### Adding a machine

Two steps, in that same window, with a **Back** link returning from each:

1. **Pick a machine.** Every machine on the tailnet, online first, this one excluded. *Enter Address Manually* is one click away, never shown first.
2. **Code.** *Type the code shown on `<name>`*, six digits hinted by where that machine shows them, plus an optional rename field. A failure appears under the field.

Pairing succeeds, the new machine joins the list, and Sensorium connects to it. **Pair again** on a row goes straight to the code step.

### The session window

Created when the session goes live, not before. Until then every attempt is reported on the row in *Your Machines*. A session that drops, ends, or cannot prove the machine it reached is the one paired with says so here, with **Your machines**, closing this window and restoring the list.

Title: `<machine name> @ <tailnet name>`, falling back to the address when the tailnet name is unknown.

Controls, in the menu bar, reachable while connected, applying live:

- **Displays: 1 or 2** session displays the host creates. It applies to a virtual display session only. Changing it mid-session adds or removes a window.
- **Resolution:** per display, each scale listed with its pixel size. Automatic is the default and only fidelity setting. A link that cannot sustain it shows the HUD naming the frame rate and encoder quality in use, as a measured limit, not a pick.
- **Screen: Host screen or Private Desktop**. Each of the host's screens is listed when the host allowed this machine to see it. **Private Desktop** is listed only when the person at the host has turned on "Offer a private desktop", which is off by default. Live, the menu also carries a **Resolution** submenu of that screen's own display modes, and a **Start with** submenu naming the target tried first next time: **Host Screen When Offered**, the default, **Private Desktop**, or a screen. **Host Screen When Offered** starts on the screen last shown, or the first screen the host offers. On a host with no monitor, **Resolution** is disabled: its one screen has a single size. If the host offers no screen, the window says so and streams nothing. Whether of a mode change or an unavailable screen, a refusal must be said in the window in plain words, never left silent. The **Screen** menu's screen rows and **Displays** are disabled while a host screen is live. **Start with** stays available because it only sets the next session.
- **Clipboard: on or off**, on by default. A copy that is not shared says why in the session window.
- **Pointer capture**, its shortcut named next to it. Leaving the window releases it, and outside capture this machine's own pointer draws locally, not waiting on the video.

When the host screen shows the lock screen, the person at the viewer unlocks it the way they would at the machine. Typing, clicking and scrolling in the session window reach the lock screen as ordinary input. There is no panel, no button and no password prompt.

If the host machine was locked during a host-screen session and was later found unlocked, whether from the viewer or by the person at the host, it locks itself again once the session ends -- unless someone is using the machine itself, in which case it is left alone. This happens silently, with no notice in this window.

### Sending system shortcuts

With Accessibility granted and a focused viewer window, shortcuts the machine in front of the person would otherwise take first — Mission Control, Spotlight, Command-Tab, and the rest — reach the host by key, the same as ordinary typing. A slim strip hangs from the top of the session window as the pointer path for them, and remains the only path when Accessibility is not granted. Every overlay names the host: the strip's label and every button's tooltip say which machine a shortcut goes to.

A small rounded tab at top centre is all that shows while a session is live. Hovering opens the strip, clicking toggles it, and Command-Control-Shift-Space does the same without the pointer, sliding away a second after the pointer leaves or on Escape over it.

Open, it reads left to right:

- The host's name, in grey.
- Four icon-only clusters by intent: window management, virtual desktops, search and app switching, lock and quit. Each button is tooltipped with its action and target.
- A pin that turns the strip's hover behaviour off. The strip is pinned by default, and the choice to unpin or pin it again is remembered across launches. Pinning gives the strip its own band across the top; the picture and the diagnostics panel move down below it, so neither is covered.

Lock Screen and Quit App ask once first. Nothing on the strip takes keyboard focus.

### Errors the viewer may show

Every error names the machine, says what happened in one sentence, and offers the fix as a button. No remedy is a command, a file, or another app.


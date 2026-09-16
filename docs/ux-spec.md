# Sensorium user interface specification

This document says what each of the two apps shows and who decides what.

## The one rule

The person is at the viewer. The host is an unattended machine.

The host decides permission only: which machines may connect, and whether a connected machine may see one of its host screens.

The viewer decides everything else about a session: how many displays, their resolution, a virtual display or a host screen, and clipboard sharing. These apply while the session runs, not at the next launch.

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
2. **Pairing code.** Six digits in two groups of three, large, with **Hide code** beneath them. Shown the moment a new machine asks to pair. Otherwise a **Show pairing code** button shows instead, never replacing the connected machine or its **Stop** button.
3. **Paired machines.** One row per machine, named by the name it gave when it paired, never a key fingerprint. Each row has:
   - The name, with **Remove** right-aligned.
   - **Share host screen**, the only session-shaping control on the host. It arms the machine, not one screen, and a line beneath it names the screens this machine can share right now.
   - **Ask me first if this machine is in use**, shown while sharing is on, off by default.
   - A line naming its key fingerprint and why sharing is or is not available now.
4. **Last screen session.** Machine, display, and when, if there has been one.

### Menu bar

The status item mirrors the status line. It names the connected machine while a session runs, and offers Stop.

### While a host screen is being streamed

An unmissable badge sits on the display being streamed, naming the connected machine, with Stop, draggable anywhere on that display. Clicking it anywhere but Stop collapses it to a small pill with the same name and Stop button, tooltipped with the display's name. Position and collapsed state are remembered per display. It floats above every other window.

## Sensorium (viewer)

### Your machines

Launching opens one window, the only one until a picture arrives. It shows the heading *Your Machines*, every paired machine, and **Add a machine…**.

Each machine row shows:

| Field | Content |
| --- | --- |
| Name | Given when it paired |
| Address | The paired address |
| State | *online* or *offline* |

Rows are ordered most recently connected first. With nothing paired yet, the list is replaced by *No machine is paired with this one yet.*, and **Add a machine…** is the only action.

Nothing is dialled until a row is clicked. One click connects. Return connects the selected row. While an attempt is out, the row appends *connecting…* or *stopping…* with a pulsing dot and offers **Cancel**. Other rows stay clickable, and clicking one stops the attempt already out. A failed attempt keeps a short reason, with the full explanation in the status panel.

Each row also offers **Pair again** and **Forget**, from a right-click or its **…** button. Forgetting removes the entry and changes nothing on the machine it named. A row whose last host-screen attempt, tried through this machine's own **Start with** preference, failed to connect adds **Connect with a virtual display**, the one explicit retry on a virtual display.

There is no Quit button here. Command-Q quits, and closing the window is the same choice. **Your machines…** (Command-1) opens it at any time.

### Adding a machine

Two steps, in that same window, with a **Back** link returning from each:

1. **Pick a machine.** Every machine on the tailnet, online first, this one excluded. *Enter address manually* is one click away, never shown first.
2. **Code.** *Type the Code Shown on `<name>`*, six digits hinted by where that machine shows them, plus an optional rename field. A failure appears under the field.

Pairing succeeds, the new machine joins the list, and Sensorium connects to it. **Pair again** on a row goes straight to the code step.

### The session window

Created when the session goes live, not before. Until then every attempt is reported on the row in *Your Machines*. A session that drops, ends, or cannot prove the machine it reached is the one paired with says so here, with **Your machines**, closing this window and restoring the list.

Title: `<machine name> @ <tailnet name>`, falling back to the address when the tailnet name is unknown.

Controls, in the menu bar, reachable while connected, applying live:

- **Displays: 1 or 2** session displays the host creates. Changing it mid-session adds or removes a window.
- **Resolution:** per display, each scale listed with its pixel size. Automatic is the default and only fidelity setting. A link that cannot sustain it shows the HUD naming the frame rate and encoder quality in use, as a measured limit, not a pick.
- **Screen: Virtual display (default) or Host screen**, one of the host's screens, offered only when the host allowed this machine to see one. Choosing one triggers the presence check. A failed check ends the whole session. Live, the menu also carries a **Resolution** submenu of that screen's own display modes, and a **Start with** submenu naming the target tried first next time: *Host screen when offered*, the default, *Virtual display*, or a screen. Whether of a mode change or an unavailable screen, a refusal must be said in the window in plain words, never left silent. **Screen** and **Displays** are both disabled while a host screen is live.
- **Clipboard: on or off.**
- **Pointer capture**, its shortcut named next to it. Leaving the window releases it, and outside capture this machine's own pointer draws locally, not waiting on the video.

While the host reports its screen locked, a panel titled *Unlock the host* appears in the session window: a **Login password** secure field and an **Unlock** button. Submitting confirms presence, then sends the password once, over the same connection. A wrong password keeps the panel up to try again; every other outcome clears the field and shows a brief notice, listed in *Errors the viewer may show* below.

### Sending system shortcuts

Some shortcuts never reach the host, because the machine in front of the person takes them first: Mission Control, Spotlight, Command-Tab, and the rest. A slim strip hangs from the top of the session window and sends them on. Every overlay names the host: the strip's label and every button's tooltip say which machine a shortcut goes to.

A small rounded tab at top centre is all that shows while a session is live. Hovering opens the strip, clicking toggles it, and Command-Control-Shift-Space does the same without the pointer, sliding away a second after the pointer leaves or on Escape over it.

Open, it reads left to right:

- The host's name, in grey.
- Four icon-only clusters by intent: window management, virtual desktops, search and app switching, lock and quit. Each button is tooltipped with its action and target.
- A pin that turns the strip's hover behaviour off, remembered across launches. Pinning gives the strip its own band across the top; the picture and the diagnostics panel move down below it, so neither is covered.

Lock Screen and Quit App ask once first. Nothing on the strip takes keyboard focus.

### Errors the viewer may show

Every error names the machine, says what happened in one sentence, and offers the fix as a button. No remedy is a command, a file, or another app.

The unlock panel's own notices, shown beneath its password field after an attempt:

- "The host is unlocked."
- "That password did not unlock the host. Try again."
- "This machine could not reach its own screen-sharing service to unlock."
- "The host is already unlocked."
- "This session is not allowed to unlock the host."
- "Too many wrong passwords. The host stopped accepting unlock attempts. Someone at the host can re-arm this machine to allow more."
- "That password is too long for this unlock method. Type it at the login window instead."
- "Confirm you are here to unlock the host, then try again."
- "The host could not be unlocked. Try again."
- "The unlock request could not be sent. Try again."
- "Presence confirmation was cancelled or failed. Try unlocking again."
- "The host did not answer the unlock request in time. Try again."

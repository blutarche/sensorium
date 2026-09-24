# Host screen mode

Sensorium streams one of two targets. Session canvas is the default: a virtual display the host creates for the session and removes when the session ends. Host screen is the second target: one display the host already had, captured as it is. Capturing a display is allowed. Configuring one is not. No private display APIs. No resolution, arrangement, or mirroring change. No display created or destroyed. The capability is ScreenCaptureKit capturing an `SCDisplay` under a granted Screen Recording permission.

A session may wake this machine's displays and keep them awake while it runs. macOS draws nothing at all to a sleeping display, virtual displays included, so a session that starts against a sleeping machine captures a picture that never arrives. Section 8 says what that permits and what it still forbids.

---

## 1. Naming

`CaptureIntent` names the two targets a session can stream.

| Term | Meaning |
| --- | --- |
| `CaptureIntent.sessionCanvas` | A virtual display the host created for this session. |
| `CaptureIntent.hostScreen(token:)` | One existing display of this host. |
| `SessionSurfaceGeometry` | A surface's logical size and backing scale, for either target. |

The viewer calls this mode "host screen", not "mirror". A mirror would imply a copy of the display. This streams the display itself.

---

## 2. Choosing the mode

Host screen is armed by pairing. A machine that pairs is armed at once. Arming names the machine, not a set of screens. An armed machine may be offered any display the host has when a session starts. A person at the host, not the viewer, can turn it off for that machine afterward, and can turn it back on.

### 2.1 Arming, at pairing, persistently

Pairing arms a paired machine for screen control at once. A machine that pairs again after the person at the host turned this off for it is not re-armed by pairing again. The person at the host can turn screen control off or back on for one paired machine, through the host app's own interface. The record persists across restarts, so an unattended host stays reachable without anyone standing in front of it.

- **Host-set only.** Only a pairing ceremony the person at the host started, completed with a signed request carrying the code shown there, can create an arming record; nothing else on the wire can create, re-arm, or widen it. A `pairRequest` without a signature over `sensorium-pair-request-v2` is refused as malformed before the code is read, and one whose signature does not verify against the key it names ends the connection. Beyond that ceremony, only the host's own interface writes the arming store, and the session controller and coordinator hold a read-only view.
- **Named machines.** Arming names the machine's public key. Pairing a second machine does not extend screen control to it.
- **Per machine, not per display.** Arming names no display. A display qualifies when the host has it at session time and Sensorium did not create it, so a monitor attached after the host started can be shared, exactly as it can with the screen sharing macOS ships. A session canvas the host created never qualifies.

The record lives at `~/Library/Application Support/Sensorium/host-screen-arming.json`, owner-readable only. It holds armed machine keys and the arming time. A record written by an earlier version that also named displays still loads; the display list is ignored and dropped when the record is written back. This is a separate file from `approved-devices.json`. That file means "this machine may connect." This file means "this machine may drive my screen." It sits beside the identity files in the same directory and is owner-readable in the same way. Its owner can read it with `cat` and revoke it with `rm`. A file that is there but cannot be decoded arms nothing and is named once in the host's log: it is never read as an empty record, which would let the one-time arming below run again and re-arm machines the person at the host had turned off.

### 2.2 Seeing and revoking it later

The menu bar shows the state at all times: "Screen control: ON for `<machine>`", with a one-click "Turn off screen control". The Host Setup window shows the same as a switch, with the date it was armed and the last host-screen session. Removing a paired machine removes its arming with it.

Turning screen control off for a machine ends that machine's live host-screen session at once. It ends the way the host's own Stop control ends it: the viewer is told `stopped-by-host` and does not redial, and the teardown, relock and session record all run. A session canvas of that machine is not ended by turning screen control off.

Removing a paired machine ends every connection it has at once, session canvas and host screen alike, the same way. The running host stops admitting its key immediately, so its next connection is refused as not paired without a restart. Connections that have not yet authenticated, and pairing connections, are not affected.

### 2.3 The viewer side

A real host offers its host-screen list unprompted. It sends this right after a successful authenticated hello, before any other host-initiated message. The list holds every display this host can share right now, or an empty list when it has none to share. The session chooser lists "Private canvas (default)" and each offered display, plus a "Connect to Host Screen" item that reconnects. A connection's target is fixed for its whole life. Choosing host screen opens a fresh connection naming the display's own `displayIdentity`. No message upgrades an open canvas connection into a host-screen one.

A machine that is not armed is refused with the reason `host-screen-not-allowed`, shown as "This machine's owner has not enabled screen control for you." It does not fall back to a canvas silently. A display can be missing from the offer for several reasons: it is offline, asleep, or mirroring another display. Each case is logged with the reason. A canvas the host itself created is never a candidate and is not logged. The Host Setup window's paired-machine row says when nothing can be shared.

### 2.4 What the person at the host sees

A menu-bar icon and title. An always-visible badge names the connected machine and display, with a Stop control. Full detail is in §6.3.

---

## 3. What is shared, and what forks

Transport, framing, pairing, authentication, encoding, packetization, clipboard sync, adaptive fidelity, telemetry, and the viewer's presentation and viewport layers are identical for both targets. They already carry geometry and content without assuming who created the display. Some types assume the canvas is host-created, and each of these forks into a host-screen counterpart: display acquisition and release, the canvas-request message case, key confinement, capture-selection guards, workspace placement, the workspace's own launcher and application catalog, display-readiness waiting, and the operator-status strings that describe what a session can see. Key confinement gets a new case because there is no owned window to confine a key to, covered in §4. No workspace window opens on a host screen, and the launcher and application catalog stay hidden since the host's screen already has a Dock and running applications. Display-readiness waiting is replaced by a check that the display is still present, still online, and has the same bounds.

Host screen uses new message types instead of a mode field on the canvas request. A host that predates the feature then builds an ordinary canvas instead of misreading an unknown field. The message types are `hostScreenList`, `hostScreenRequest`, `hostScreenReady`, and `hostScreenRefused`. Their fields appear where they are used: the offered-display list in §5.4, and the resume ticket in §6.4.

---

## 4. Input injection

`globalPoint` adds the target display's own `CGDisplayBounds` origin. It re-reads those bounds on every event, so rearranging displays does not strand the mapping. Key confinement is gone. There is no owned window to confine a key to. The arming gate is what stands between a posted key and whatever holds the host's focus. Two input streams merge with no arbitration, because macOS does not distinguish injected events from a person's own.

- **Local activity** is read with `CGEventSource.secondsSinceLastEventType` against `.hidSystemState`. An ordinary event posted at `.cgSessionEventTap` never touches this. A system hotkey such as Mission Control, Spaces, or Spotlight posts to `.cghidEventTap` instead, early enough for the window server's own handling to see it, and that does touch it -- the same is true while the screen is locked, below. It carries `CoreGraphicsInputTranslation.nativeAuxiliaryFlags` so navigation-cluster and F-row keys read correctly.
- **While the screen is locked**, a host-screen session posts every event -- key, pointer, and scroll alike -- at `.cghidEventTap` instead of `.cgSessionEventTap`, the same tap a system hotkey posts to. A session canvas posts nothing while the screen is locked.
- **Held input** is released on pause entry and at teardown. A release that throws is still handled, not silently dropped.
- **Pointer capture is refused.** `CGAssociateMouseAndMouseCursorPosition(0)` would disconnect the host's own mouse from its cursor. The viewer sends absolute motion only.
- **Stopping**, from the menu item, badge button, or a global chord, releases held input, ends the surface, and disarms the mode.

---

## 5. Geometry, scale, and choosing a display

### 5.1 Learning geometry

`DisplayInventory.active()` reports bounds, logical mode size, backing pixel size, online and builtin flags, and identity for every display. `hostScreenReady` carries the target's logical size and backing scale. The viewer builds its input mapper and window aspect ratio from that reply, not a fixed preset.

### 5.2 Stream scale

A host-screen session honours the viewer's drawable size, the same as a session canvas does. The viewer reports the pixel size of the window it is drawing into. The host turns that into a stream scale against the host screen's own logical size, never against the canvas size it is not streaming.

Two ceilings bound that scale, and the lower one wins. The first is the display's own backing scale. A display chosen by someone else has no further pixel to encode past it. The second is the largest frame this machine's hardware H.264 encoder accepts. A request past that one does not soften the picture, it fails the rebuild. A person's own fixed choice of scale is held at the same two ceilings, and so is every scale the fidelity controller chooses. Encoder dimensions are geometry times scale. Each clamp is reported to the viewer and written to the host log.

Both targets run the same fidelity control. The host measures what its capture, encoder, link, and viewer actually managed. Resolution is what it spends first, and it names the resolution rather than stepping towards one. Encode cost is per pixel, so the median encode measured at the scale in force predicts what any other scale would cost. The host streams the largest scale that leaves the encoder room for 60 frames a second. Frame rate and quality move only once the scale is at its floor and something is still behind. A still screen gets its quality and its resolution back. The host says what its capture stream delivered on the same cadence, and builds a capture that has delivered nothing at all once more before giving up on it. A host screen whose capture is rebuilt this way stays one session: the indication naming the connected device stays up and the session record stays open across it.

The figures behind those decisions are the same figures per surface for either target: applied stream scale, the highest scale this session has been measured to sustain, applied frame rate, applied encoder quality, and which stage is holding the picture back. A host-screen session sends them on the same cadence a session canvas does, so the viewer's readout reads the same either way. That is a narrower right than writing this machine's pasteboard, which still needs a canvas the session opened.

### 5.3 Reconfiguration during a session

A changed mode, changed bounds, or a display that disappears tears the surface down with the reason `host-screen-changed`. The viewer reconnects. There is no live geometry renegotiation.

### 5.4 Which display, and how it is chosen

The viewer never names a raw display ID. `CGDirectDisplayID` is not stable across sleep or replug. The host offers `hostScreenList`: entries of `opaqueToken`, `label`, `logicalWidth`, `logicalHeight`, `backingScale`, `isBuiltin`, and `displayIdentity`. The viewer picks a token. The host maps it back to the display it minted it for, and revalidates at start time.

`opaqueToken` and `displayIdentity` answer different questions. The token is a one-shot capability, minted fresh per offer, meaningless outside the session that minted it. `displayIdentity` is a stable encoding of the same display across every offer this host makes, including across a restart. It is opaque to the viewer, not secret. It lets a viewer recognize "the same display as last time" once a token is gone.

A display is admitted only when every one of these holds: this machine's key is armed, the token was minted in this session, the display is still present, online, awake, and unmirrored, and it does not carry this host's own canvas identity. One display streams per session. Serving two at once is architecturally possible but not built.

### 5.5 Remembering a chosen mode

The viewer keeps one remembered display mode per machine and host-screen pair, keyed by the machine's pinned public key and the display's own `displayIdentity`. At the start of a session, if a remembered mode is still offered and differs from the current one, the viewer sends a single `hostScreenModeRequest` for it. Otherwise it sends nothing. Only a mode the host confirms applying is ever remembered.

### 5.6 Putting the mode back

The host owes a changed display its earlier mode until a restore succeeds, and keeps the record until it does. A refused restore is retried a few times, about a second apart, outliving the session that owed it. The quit-time sweep retries every display still owed a mode the same way. Capture does not start for a session that ended mid mode-change.

### 5.7 Starting on the same screen next time

The viewer keeps one more per-machine setting, **Start with**. Its options are a private canvas, a host screen named by its own `displayIdentity`, or host screen when offered, the default. A machine that has ever been offered a screen starts on the screen it last reached, or the first one offered. A machine never offered one starts on a private canvas, updated from the host's own most recent offer so it tracks whichever target a session actually reached.

A canvas connection made only for lack of anything remembered still carries the unprompted offer from §2.3. The moment it arrives, before the viewer has shown a picture, the default setting switches that same attempt to the first screen offered. An empty offer leaves it on the canvas and says nothing. A person's own pick from the Screen menu is not second-guessed this way again. If the default setting's own choice is refused and nothing has been shown yet, the viewer falls back to a private canvas on its own, after saying once why. Once a picture has shown, the ordinary ending applies, and trying again is a person's own decision.

---

## 6. Safety and consent

### 6.1 Before a frame leaves the host

1. The machine is paired and authenticated.
2. The source address is on the tailnet.
3. Screen Recording is granted. `CGPreflightScreenCaptureAccess()` is read when the host starts, and again every thirty seconds while it runs (`HostPermissionMonitor`), which is what reports a grant revoked mid-run. It is not re-read at arming time or per session.
4. The machine's key is armed, per §2.1.
5. The host-presence rule from §6.2 is satisfied, or a valid resume ticket is presented for a session already granted, per §6.4.

A failure of any of these refuses the whole session, video included.

### 6.2 The host-presence rule

Arming a machine is itself the consent this control exists to obtain. A session starts immediately with no prompt by default. A person arming a machine may switch on **Ask me first** for that machine alone. With no local activity at the host for several minutes, the session still starts without a prompt. With recent local activity, the person at the host is asked. No answer within thirty seconds denies, and the viewer is told the machine is in use and did not respond.

### 6.3 What the person at the host sees

- **A badge.** An always-on-top panel above the Dock and menu bar, on every Space and over full-screen apps, naming the connected machine and display with a Stop button. It can be dragged anywhere on the display and stays fully inside it, and appears in the captured stream itself. A session that starts without a prompt opens the badge expanded for a few seconds before it shrinks.
- **The menu bar** shows a distinct icon and title text while a host-screen session is live.
- **Stop**, in three places: badge button, menu item, global chord. Always releases held input, ends the surface, and disarms the mode.
- **A local record** at `~/Library/Application Support/Sensorium/host-screen-sessions.log`: machine name, display, and start and stop times, never input content. Shown in Host Setup as "Last screen session: `<machine>`, `<date>` `<start>`–`<end>`."

This applies everywhere else privacy is claimed in the product: the operator status line, the operator log, the setup window, the README, and the threat-model documents. Each states which mode it describes, instead of promising privacy unconditionally.

### 6.4 Resume tickets

A grant belongs to a host-screen session, not to a transport connection, and the host decides what counts as the same session. At session start the host mints a short-lived opaque resume ticket with `hostScreenReady`. The viewer presents it on reconnect.

- **Transport interruption.** The ticket is presented, the host still holds the surface, and the session resumes with no prompt.
- **A new session prompts.** The ticket is expired or unknown, the surface was torn down, the host restarted, a different display was requested, or the arming record changed. The host refuses the resume attempt with `host-screen-resume-refused`, and the viewer falls back to its ordinary connect flow.
- **Grace window and ceiling.** The grace window is five minutes, refreshed on each successful resume. A grant never survives more than twelve hours of resumes. The next reconnect after that prompts, and a live session is never interrupted mid-way.
- **Never in a retry loop.** The check runs only on a user-initiated connect, at most once per action. Automatic reconnection either presents a valid ticket or stops and waits for the person.

### 6.5 Threat model

Stated in `docs/threat-model.md`. A stolen viewer key from a machine that has never been armed for host screen buys an attacker a private, empty canvas. A stolen key from any armed machine buys control of a logged-in machine, with nobody necessarily present to refuse, unless the person at the host has turned screen control off for that machine. The compensating controls, in order: arming is per-machine, arming is host-local and nothing on the wire can create, re-arm, or widen it, the tailnet requirement stands, the badge and Stop make a live session obvious to anyone in the room, and the session log makes a past session provable afterward.

---

## 7. Core invariant

The rule governing both targets is stated once, under "v1 core invariant" in `CLAUDE.md`.

---

## 8. Display power

A sleeping display is drawn to by nothing. Capture of it, or of a virtual display on the same machine, starts without error and delivers no frames. Waking the display first is what makes a session possible at all.

`DisplayWakeController` is the only thing in this codebase that touches power state, through public IOKit power management and nothing else.

| Step | Call |
| --- | --- |
| Wake the displays | `IOPMAssertionDeclareUserActivity` with `kIOPMUserActiveLocal` |
| Keep them awake | `IOPMAssertionCreateWithName` with `kIOPMAssertPreventUserIdleDisplaySleep` |
| Let them idle again | `IOPMAssertionRelease` |

The assertion is named "Sensorium session is live", which is what macOS shows anyone at the host asking what is keeping the screen on.

- **At session start.** If sleep is the only thing keeping a display out of the offer, the host declares user activity and waits for the display it is about to stream, up to five seconds. A display held back for any other reason, a mirror of another display among them, is left alone: waking it would not make it offerable. A display that comes back is offered and captured. A display that stays asleep is refused as `asleep`.
- **While a session is live.** One prevent-sleep assertion, taken once however many surfaces the session has.
- **At session end.** The assertion is released on every path that ends a session, the ones that end it on an error and the one that ends it because the host is quitting included.
- **Nothing on the wire.** Only a display an armed machine could already be offered is woken before an offer, and only the display a token this host itself minted names is woken before a request. A message naming anything else reaches no power call.
- **Still forbidden.** No display is created, destroyed, resized, re-arranged, mirrored, or blanked. The machine itself is never woken from sleep. An activity declaration wakes a display, not a sleeping machine.

A capture that delivers nothing while the display it captures is asleep is answered by waking that display and building the stream once more, rather than by giving up on this process's ability to capture. A host-screen session reads only the display it is streaming. A session canvas reads the machine, since display sleep is machine-wide.

If the session still ends, it ends with `host-displays-asleep`, and the viewer is told the host's screens were asleep. The viewer does not redial into that ending: a person waking the screen is what changes the answer. `capture-unavailable` names the different case where the host can no longer get a picture out of that machine at all, and tells a person to quit and reopen the host.

---

## 9. Lock-screen unlock

A locked host is unlocked the way it would be at the machine. While a live host-screen session shows the host's lock screen, the viewer's keystrokes, clicks and scrolls reach it as ordinary forwarded input. The host posts them through the locked-screen routing in §4, at `.cghidEventTap`. The viewer draws no password prompt. A password typed there is ordinary key input: Sensorium never recognises, extracts, stores or logs it as a password.

### 9.1 Gating

Unlocking needs nothing beyond the live host-screen session itself. It opens no separate connection and asks for no separate arming record. A session canvas cannot reach the lock screen: its input is dropped while the machine is locked. Out of scope entirely: FileVault's pre-boot, cold-boot unlock screen, which no session reaches.

### 9.2 Lock state

The host rereads its own lock state every two seconds for as long as the host-screen session lasts. It sends `hostScreenLockState(locked)` whenever that reading changes. The same readings feed the relock rule in §9.5 and the input routing in §4.

### 9.3 Unused unlock request

The wire format still defines `hostScreenUnlockRequest` and `hostScreenUnlockResult`. The host still answers them through an RFB client for the built-in screen-sharing service on loopback (`RFBLockScreenUnlocker`). No shipping viewer sends that request, so unlocking never depends on Screen Sharing being on. See `docs/protocol.md` for the messages.

### 9.4 Unused wrong-guess budget

Answers to that unused request are limited to 5 wrong guesses per machine per host uptime, held in memory only (`HostScreenUnlockThrottle`). Forwarded key input at the lock screen is not counted by it.

### 9.5 Relocking on session end

A host-screen session that found the machine locked, and was later found unlocked, relocks the machine when that session ends -- unless someone is using the machine itself. The unlock may have come through this session or from the person at the host. Ending also covers the host app quitting with such a session still live. A session that never saw the screen locked leaves it unlocked. A session that ends with the screen locked never relocks it: there is nothing to redo.

Relock never locks a machine someone is using at the keyboard. Hardware input at the moment the screen went from locked to unlocked means a person unlocked it themselves, and that veto sticks for the rest of the session. Hardware input found at session end, whoever unlocked the screen, means someone is using it right now. Both checks read hardware input only, through the same idle-time signal and five-minute window `HostScreenPresenceRule` uses elsewhere, discounted against this host's own most recent forwarded keystroke -- sampled immediately before that keystroke is posted, so a real person's input right before it is never masked by the post that follows -- so that a viewer typing into the lock screen is never mistaken for a person at the machine (`SelfPostDiscountingLocalActivitySignal`).

`HostScreenRelockTracker` holds this rule. Every raw lock-state reading a session takes feeds it, alongside that hardware-activity check: at bring-up, from an unlock attempt's own announcement, and from the two-second lock-state poll. A last, fresh reading of both is taken at session end too, so an unlock or a person sitting down that the poll had not yet caught is still seen. The tracker is asked once, when the session's surfaces are torn down.

The relock itself posts macOS's own Lock Screen shortcut, Control-Command-Q, at the same `.cghidEventTap` tap a system hotkey needs.

### 9.6 Locking at launch

Because the host can open itself at login, it locks the screen shortly after launch too, through the same relock, whenever it finds the screen unlocked with no local input since before the process started -- this closes the unlocked window a fresh boot would otherwise leave open, but does not by itself make an unattended reboot fully safe.

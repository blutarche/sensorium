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

Host screen is armed by pairing. A machine that pairs and registers a presence credential is armed at once, for the displays the host has at that moment. A person at the host, not the viewer, can turn it off for that machine afterward, and can turn it back on.

### 2.1 Arming, at pairing, persistently

Pairing arms a paired machine for screen control at once, when the machine registers a presence credential. A machine that pairs again after the person at the host turned this off for it is not re-armed by pairing again. A machine that never registers a presence credential is not armed. The person at the host can turn screen control off or back on for one paired machine, through the host app's own interface. The record persists across restarts, so an unattended host stays reachable without anyone standing in front of it.

- **Host-set only.** No wire message reaches the arming store. Only the host's own interface writes it. The session controller and coordinator hold a read-only view.
- **Named machines.** Arming names the machine's public key. Pairing a second machine does not extend screen control to it.
- **Named displays.** Arming names which display may be captured. Attaching a display later does not arm it.

The record lives at `~/Library/Application Support/Sensorium/host-screen-arming.json`, owner-readable only. It holds armed machine keys, armed display identities, the minimum credential strength registered for each machine at the moment it was armed (see §6.3), and the arming time. This is a separate file from `approved-devices.json`. That file means "this machine may connect." This file means "this machine may drive my screen." It sits beside the identity files in the same directory and is owner-readable in the same way. Its owner can read it with `cat` and revoke it with `rm`.

### 2.2 Seeing and revoking it later

The menu bar shows the state at all times: "Screen control: ON for `<machine>`", with a one-click "Turn off screen control". The Host Setup window shows the same as a switch, with the date it was armed, the registered credential strength, and the last host-screen session. Removing a paired machine removes its arming with it.

### 2.3 The viewer side

A real host offers its host-screen list unprompted. It sends this right after a successful authenticated hello, before any other host-initiated message. The list holds every display the connecting machine is armed for, or an empty list if it is armed for none. The session chooser lists "Private canvas (default)" and each offered display, plus a "Connect to Host Screen" item that reconnects. A connection's target is fixed for its whole life. Choosing host screen opens a fresh connection naming the display's own `displayIdentity`. No message upgrades an open canvas connection into a host-screen one.

A machine that asks for host screen while armed for none is refused with the reason `host-screen-not-allowed`, shown as "This Mac's owner has not enabled screen control for you." It does not fall back to a canvas silently. A display can be missing from the offer for several reasons: it is offline, inactive, a canvas the host itself created, or absent from the pre-session snapshot. Each case is logged with the reason. The Host Setup window's paired-machine row shows the same reason.

### 2.4 What the person at the host sees

A menu-bar icon and title. An always-visible badge names the connected machine and display, with a Stop control. Full detail is in §6.4.

---

## 3. What is shared, and what forks

Transport, framing, pairing, authentication, encoding, packetization, clipboard sync, adaptive fidelity, telemetry, and the viewer's presentation and viewport layers are identical for both targets. They already carry geometry and content without assuming who created the display. Some types assume the canvas is host-created, and each of these forks into a host-screen counterpart: display acquisition and release, the canvas-request message case, key confinement, capture-selection guards, workspace placement, the workspace's own launcher and application catalog, display-readiness waiting, and the operator-status strings that describe what a session can see. Key confinement gets a new case because there is no owned window to confine a key to, covered in §4. No workspace window opens on a host screen, and the launcher and application catalog stay hidden since the host's screen already has a Dock and running applications. Display-readiness waiting is replaced by a check that the display is still present, still online, and has the same bounds.

Host screen uses new message types instead of a mode field on the canvas request. A host that predates the feature then builds an ordinary canvas instead of misreading an unknown field. The message types are `hostScreenList`, `hostScreenRequest`, `hostScreenReady`, and `hostScreenRefused`. Their fields appear where they are used: the offered-display list in §5.4, the presence credential in §6.3, and the resume ticket in §6.5.

---

## 4. Input injection

`globalPoint` adds the target display's own `CGDisplayBounds` origin. It re-reads those bounds on every event, so rearranging displays does not strand the mapping. Key confinement is gone. There is no owned window to confine a key to. The arming gate is what stands between a posted key and whatever holds the host's focus. Two input streams merge with no arbitration, because macOS does not distinguish injected events from a person's own.

- **Local activity** is read with `CGEventSource.secondsSinceLastEventType` against `.hidSystemState`. Injected input never touches this, because injected input posts to `.cgSessionEventTap`. A system hotkey such as Mission Control, Spaces, or Spotlight posts to `.cghidEventTap` instead, early enough for the window server's own handling to see it. It carries `CoreGraphicsInputTranslation.nativeAuxiliaryFlags` so navigation-cluster and F-row keys read correctly.
- **Local input wins.** Local activity pauses remote injection for two seconds, extended by further local activity. Capture keeps streaming. The viewer's HUD shows `"LOCAL USER ACTIVE — your input is paused."`
- **Held input** is released on pause entry and at teardown. A release that throws is still handled, not silently dropped.
- **Pointer capture is refused.** `CGAssociateMouseAndMouseCursorPosition(0)` would disconnect the host's own mouse from its cursor. The viewer sends absolute motion only.
- **Secure input** is surfaced to the viewer as a reason, not silently swallowed keystrokes. The host checks `IsSecureEventInputEnabled()`, true while a password field holds focus.
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

A display is admitted only when every one of these holds: the mode is armed for this machine's key, the display is armed, the token was minted in this session, the display is still present and online, it does not carry this host's own canvas identity, and it appears in the pre-session display snapshot. One display streams per session. Serving two at once is architecturally possible but not built.

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
3. Screen Recording is granted, checked with `CGPreflightScreenCaptureAccess()` at arming time.
4. The mode is armed for this machine's key and this display, per §2.1.
5. The request carries a verified presence-credential signature over the host's challenge, or a valid resume ticket, per §6.3 and §6.5.
6. The host-presence rule from §6.2 is satisfied.

A failure of any of these refuses the whole session, video included.

### 6.2 The host-presence rule

Arming a machine is itself the consent this control exists to obtain. A session starts immediately with no prompt by default. A person arming a machine may switch on **Ask me first** for that machine alone. With no local activity at the host for several minutes, the session still starts without a prompt. With recent local activity, the person at the host is asked. No answer within thirty seconds denies, and the viewer is told the machine is in use and did not respond.

### 6.3 Proof that a person is at the viewer

A presence-bound credential is a keypair the viewer's operating system or authenticator will not use without a live human confirming at that moment. It is registered with the host when the machines pair, and signed over a challenge the host issues for the session. The wire carries the public key, an opaque `credentialID`, a signature algorithm, a `credentialFormat` naming the verification routine, and a strength. It carries no mechanism of consent.

Two strengths register:

- **`hardwareBound`.** The private key lives in dedicated hardware, cannot be extracted, and every use requires a fresh confirmation. A Secure Enclave key with a user-presence access control, a FIDO2/CTAP2 authenticator with user verification, or a TPM 2.0 key under a PIN policy all qualify.
- **`softwarePresence`.** The key lives in the operating system's keystore, gated by a presence check, but reaches process memory once that check passes. It defeats an attacker holding a borrowed, unlocked machine. It does not defeat one already running code on that machine.

A machine that can register neither may pair and use a session canvas, but may not register for host screen. Registration tries each strength in descending order and keeps the first that succeeds. The sensor type behind a check words the prompt only, and never gates anything.

The strength a machine registered is a report, not a proof. No third-party attestation distinguishes a hardware signature from a software one. So the arming record snapshots the strength registered at the moment of arming, `minimumCredentialStrength`, and refuses anything weaker than that snapshot from then on. A record armed before this snapshot existed carries no minimum, and is refused outright with `host-screen-needs-rearming`. Raising the minimum again means re-arming. A weaker credential is a different key, and registering a different key always goes through the pairing ceremony at the host with a fresh one-time code. It is never authorized by the credential it replaces, and never by an already-armed machine's own existing key. A one-time code alone never authorizes writing a credential, or a machine's recorded name, for a key the host already approved. Doing so also requires proof, on the same connection, that it holds that key's private half, from either an `authenticatedHello` verified earlier on the connection or a signed `pairRequest` transcript. A key the host has never approved is exempt, since there is nothing registered yet to overwrite.

A non-Apple viewer satisfies the same obligation with an external FIDO2/CTAP2 authenticator or a TPM 2.0 key under a PIN policy. The host verifies a platform envelope containing its challenge, selected by `credentialFormat`, instead of a raw signature over the challenge bytes. The credential identifier is an opaque blob instead of a raw public key.

### 6.4 What the person at the host sees

- **A badge.** An always-on-top panel above the Dock and menu bar, on every Space and over full-screen apps, naming the connected machine and display with a Stop button. It can be dragged anywhere on the display and stays fully inside it, and appears in the captured stream itself. A session that starts without a prompt opens the badge expanded for a few seconds before it shrinks.
- **The menu bar** shows a distinct icon and title text while a host-screen session is live.
- **Stop**, in three places: badge button, menu item, global chord. Always releases held input, ends the surface, and disarms the mode.
- **A local record** at `~/Library/Application Support/Sensorium/host-screen-sessions.log`: machine name, display, start and stop times, and the registered credential strength, never input content. Shown in Host Setup as "Last screen session: `<machine>`, `<date>` `<start>`–`<end>`."

This applies everywhere else privacy is claimed in the product: the operator status line, the operator log, the setup window, the README, and the threat-model documents. Each states which mode it describes, instead of promising privacy unconditionally.

### 6.5 Resume tickets

A grant belongs to a host-screen session, not to a transport connection, and the host decides what counts as the same session. At session start the host mints a short-lived opaque resume ticket with `hostScreenReady`. The viewer presents it on reconnect.

- **Transport interruption.** The ticket is presented, the host still holds the surface, and the session resumes with no prompt.
- **A new session prompts.** The ticket is expired or unknown, the surface was torn down, the host restarted, a different display was requested, or the arming record changed. The host refuses the resume attempt with `host-screen-resume-refused`, and the viewer falls back to its ordinary connect flow.
- **Grace window and ceiling.** The grace window is five minutes, refreshed on each successful resume. A grant never survives more than twelve hours of resumes. The next reconnect after that prompts, and a live session is never interrupted mid-way.
- **Never in a retry loop.** The check runs only on a user-initiated connect, at most once per action. Automatic reconnection either presents a valid ticket or stops and waits for the person.

### 6.6 Threat model

Stated in `docs/threat-model.md`. A stolen viewer key from a machine with no registered presence credential buys an attacker a private, empty canvas. A stolen key from any other paired machine buys control of a logged-in Mac, with nobody necessarily present to refuse, unless the person at the host has turned screen control off for that machine. The compensating controls, in order: arming is per-machine and per-display, arming is host-local and nothing on the wire can create, re-arm, or widen it, the tailnet requirement stands, a presence-bound credential must sign each session's challenge, the badge and Stop make a live session obvious to anyone in the room, and the session log makes a past session provable afterward.

The presence credential proves a person was present. It does not prove they understood what they approved. On a machine without hardware key storage, it does not defend against an attacker already running code there.

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

- **At session start.** If any online display is asleep, the host declares user activity and waits for the display it is about to stream, up to five seconds. A display that comes back is offered and captured. A display that stays asleep is refused as `asleep`.
- **While a session is live.** One prevent-sleep assertion, taken once however many surfaces the session has.
- **At session end.** The assertion is released on every path that ends a session, the ones that end it on an error and the one that ends it because the host is quitting included.
- **Nothing on the wire.** Only a display the connecting machine is already armed for is woken before an offer, and only the display a token this host itself minted names is woken before a request. A message naming anything else reaches no power call.
- **Still forbidden.** No display is created, destroyed, resized, re-arranged, mirrored, or blanked. The machine itself is never woken from sleep. An activity declaration wakes a display, not a sleeping Mac.

A capture that delivers nothing while the display it captures is asleep is answered by waking that display and building the stream once more, rather than by giving up on this process's ability to capture. A host-screen session reads only the display it is streaming. A session canvas reads the machine, since display sleep is machine-wide.

If the session still ends, it ends with `host-displays-asleep`, and the viewer is told the host's screens were asleep. The viewer does not redial into that ending: a person waking the screen is what changes the answer. `capture-unavailable` names the different case where the host can no longer get a picture out of that machine at all, and tells a person to quit and reopen the host.

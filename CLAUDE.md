# Sensorium — Non-Negotiable Engineering Rules

## Product
Sensorium is a clean-room, private, native remote workstation system for one viewer machine and one host machine. macOS is the first platform; Linux is next.

Sensorium ships as two double-clickable macOS apps and nothing else. No user ever runs a command, opens Terminal, or types an address. The CLI verbs and the `.command` launchers are test scaffolding — not an alpha surface — and every capability must be reachable from the GUI before it counts as delivered.

This repository will be published as open source. Write every comment, document and identifier for a stranger reading it cold: no scratchpad notes, no conversation or grill-history references, no "dev-only" asides, no narration of how the code used to be. Anything that would embarrass the project in public does not go in.

## Clean-room boundary
- Do NOT copy, import, vendor, fork, invoke, or inspect source from any other remote desktop or display configuration implementation.
- The platform vendor's public framework documentation and independently written, small compatibility experiments are allowed.
- Do not add telemetry, analytics, crash reporting SDKs, webviews, accounts, cloud APIs, TURN/STUN, or a backend.

## Safety boundary — strict
- Do NOT call private display APIs, third-party display tools, `displayplacer`, `screencapture`, `system_profiler`, System Settings, `launchctl`, `defaults`, PF, `sudo`, network/firewall commands, or write outside this repository unless the task explicitly says it is an approved opt-in macOS integration test.
- Do NOT install packages, Xcode, Homebrew formulae, applications, services, agents, launch daemons, login items, or permissions on a development machine. Shipping code may register the host app as its own login item (Open at login) through `SMAppService`; installing a build on the owner's machines happens only when the owner asks.
- Do NOT read keychains, credentials, shell histories, or files outside the repository.
- Do NOT open network listeners, perform network calls, or access external websites.
- Do NOT commit, push, create branches/worktrees, or change Git configuration unless explicitly assigned.

## Development discipline
- Strict TDD: write one failing test, run it and observe the intended failure, implement the minimum code, rerun the specific test, then run the full suite.
- Prefer Swift 6 and XCTest. Keep code native and dependency-free.
- Write only source, tests, and documentation inside this repository.

## v1 core invariant

A session streams exactly one of two targets, and the target is named
explicitly when the session is set up:

- **Session canvas**: a session-owned virtual display this host
  created. It is removed at disconnect. The session starts here when the
  host does not offer a host screen.
- **Host screen**: one existing display of this machine, captured as it
  is. It is never created and never removed. Pairing arms it. The person
  at the host can turn it off afterward. The session starts here when the
  host offers one. Its display mode (resolution and scaling) may be
  changed only on the viewer's explicit request during a live host-screen
  session, choosing among the modes macOS already offers for that display
  through public CoreGraphics display-mode APIs, and the mode it had
  before is restored when the session ends or the host quits.

Beyond that one mode change, reconfiguration is forbidden in both modes.
Sensorium must never create, destroy, resize, re-arrange, mirror, or blank
a physical display, and must never call a private display API,
`displayplacer`, or any other display configuration tool. A session may wake
a display and keep it awake while it is live, through public IOKit power
management only.
Capturing a display with ScreenCaptureKit under a granted Screen Recording
permission is allowed; a mode change through `CGDisplaySetDisplayMode` or
`CGBeginDisplayConfiguration` is allowed only for the host screen a session
is streaming, on the viewer's request, and is always undone.

Host screen is gated, and no frame of it may leave the host until all of
these hold. Screen Recording is granted. The connecting device is paired
with this host and armed. Pairing arms a device: the person at the host
shows the pairing code, and the device that enters it with a signed
request is trusted from then on for any display this machine has. The
person at the host can turn off arming for one device, and can turn it
back on. The record persists across restarts, so an unattended host stays
reachable. It is stored on this machine alone. No message on the wire can
create, re-arm, or widen it. The target display is one Sensorium did not
create. The person at the host can also turn on asking first. Someone who
used this machine in the last few minutes is then asked, and must agree
first. Asking first is off by default.

What pairing proves is that whoever held the device at that moment could
read the code shown at the host. It does not prove who holds the device
later. A stolen or compromised paired device has the same reach as its
owner, as with a saved password in any other remote desktop, and nothing in
the codebase or its documentation may describe pairing as more than that.
Sensorium asks for no further proof of a person at the viewer.

A locked host is unlocked the way it would be at the machine. While a live
host-screen session shows the host's lock screen, the viewer's keystrokes,
clicks and scrolls reach it as ordinary forwarded input, posted through
public CoreGraphics event APIs at the HID event tap while the screen is
locked. The viewer draws no password prompt. Sensorium never recognises,
extracts, stores or logs a password as such: it is ordinary input like any
other typing. Screen Sharing is not needed. FileVault's pre-boot unlock is
out of scope.

While a host-screen session is live, the person at the host must see a
continuous, unmissable indication naming the connected device, with a
control that stops it immediately; and every such session must leave a
local record naming the device, the display, and when it ran. Sensorium
places no window on a physical display except that indicator.

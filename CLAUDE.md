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
- Do NOT install packages, Xcode, Homebrew formulae, applications, services, agents, launch daemons, login items, or permissions.
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
  is. It is never created and never removed. Pairing arms it when the
  pairing device registers a presence credential. The person at the host
  can turn it off afterward. The session starts here when the host offers
  one. Its display mode (resolution
  and scaling) may be changed only on the viewer's explicit request during a
  live host-screen session, choosing among the modes macOS already offers
  for that display through public CoreGraphics display-mode APIs, and the
  mode it had before is restored when the session ends or the host quits.

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

Host screen is additionally gated, and no frame of it may leave the host
until all of these hold. Screen Recording is granted. Host screen is armed
by pairing. The person at the host shows the pairing code. The machine that
pairs is armed for this machine itself, not for a fixed set of screens: it may
be offered any display this machine has when a session starts. Arming needs a
registered presence credential. The person at the host can turn off
arming for one machine. The person can turn it back on. The record
persists across restarts, so an unattended host stays reachable. It is
stored on this machine alone. No message on the wire can create, re-arm, or
widen it. The target display is one Sensorium did not create.
The person at the host can also turn on
asking first. Someone who used this machine in the last few minutes is then
asked. That person must agree first. Asking first is off by default. An
armed device is otherwise not asked.

Host screen also requires proof that a person is at the viewer. The viewer
holds a presence-bound credential — a keypair its operating system or
authenticator will not use without a live human confirming at that moment —
whose public half is registered with this host when the devices pair, and
which signs a challenge this host issues for the session. The host verifies
that signature against the registered public key. This presence credential,
and any biometric or password its authenticator checks, is never transmitted,
stored, or seen by this code, and this rule names no specific platform
mechanism: any operating system that can hold such a credential can satisfy
it. The one exception is the opt-in lock-screen unlock described below, which
is the only place a password crosses the wire.

Credentials register at one of two acceptable strengths, and which one a
device registered is recorded and shown to the person arming it: a key held
in hardware that cannot be extracted and requires confirmation for every
use, or a key held by the operating system whose use is gated by a presence
check but which an attacker who has already compromised that machine can
extract after one such check. A device that can offer neither may pair and
use a session canvas, but may not register for host screen. The host stores
a minimum acceptable strength per armed device and refuses anything weaker;
that rule is enforced by requiring the pairing ceremony to change the
registered key, never by trusting the strength a device reports.

A failed, cancelled, or unavailable check refuses the whole session, video
included; it never degrades to a view-only session, because a failed check
is exactly when it is least clear who is at the viewer. What this proves is
that a person was present and approved; it does not prove they understood
what they were approving, and nothing in the codebase or its documentation
may describe it as more than that.

Lock-screen unlock is an opt-in action inside a live, authenticated,
presence-verified host-screen session. When the person at the viewer chooses
to unlock a locked host, and only then, the host's login password travels once
over the same encrypted, authenticated, presence-gated channel, is held in
memory only long enough to enter it, and is never written to disk, never
logged, and never stored. The host types it into its own login window through
the operating system's built-in screen-sharing service over the loopback
interface only; Sensorium opens no network listener of its own to do this, and
speaks that service's protocol from the public specification without copying
any other implementation. Enabling that built-in service is the operator's
own choice on the host.

While a host-screen session is live, the person at the host must see a
continuous, unmissable indication naming the connected device, with a
control that stops it immediately; and every such session must leave a
local record naming the device, the display, and when it ran. Sensorium
places no window on a physical display except that indicator.

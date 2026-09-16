# Sensorium

A private remote workstation for two machines: a person at the viewer works on
a session canvas the host creates for them, or, with permission granted at the
host, on one of the host's own screens.

## Language

### The two sides

**Host**:
The Sensorium Host app, and the unattended machine it runs on, that creates
canvases and streams them.
_Avoid_: server, mini, daemon

**Viewer**:
The Sensorium app, and the machine it runs on, where the person is.
_Avoid_: client, Mac, remote

**Machine**:
Either computer, named in every window by the name it gave when it paired.
The category word is always "machine"; macOS is named only when a fact is
specific to that operating system.
_Avoid_: Mac (as a category), device, peer, computer

**Paired machine**:
A machine the host has accepted through a pairing code and lists in its window.
_Avoid_: trusted device, known peer

**Pairing code**:
Six digits the host shows and a person types at the viewer to pair the two.
_Avoid_: PIN, passcode, token

**Start with**:
A per-machine viewer setting naming which target a fresh connection to that
machine opens on: a virtual display, one of its host screens, or
*host screen when offered* (the default), which starts directly on
whichever screen that machine's host most recently offered, falling back to
a virtual display for a machine never offered one -- and, for a connection
that starts there only for lack of anything remembered, switching itself to
the first screen offered the moment that offer arrives.
_Avoid_: start target, default target, launch preference, last used

### What is streamed

**Session**:
One connection during which the host streams exactly one target to one viewer.
_Avoid_: stream, link, call

**Session canvas**:
A virtual display the host creates for a session and removes at its end. On
screen it is called a "virtual display"; "canvas" never appears in a window.
_Avoid_: virtual screen, canvas display, workspace display

**Host screen**:
One display the host already had, streamed as it is under a permission a person
granted at the host. Never created or removed by Sensorium, and altered in two
respects only: its host screen mode, and whether it is awake. Both are below.
The permission is "Share host screen"; what the viewer does with it is "see and
control".
_Avoid_: physical display, mirror, real screen

**Host screen mode**:
The resolution and scaling the host screen runs at. Only the viewer changes it,
only during a live host-screen session, and it is restored at that session's
end. On screen it is called "resolution".
_Avoid_: display mode, screen resolution change, scaling profile

**Lock-screen unlock**:
An opt-in action inside a live, authenticated, presence-verified host-screen
session: the person at the viewer types the host machine's login password, and
the host types it into its own locked login window. What locks is the
machine's login session, not any one display, so this has nothing to do with
which screen is being streamed. On screen it is offered as "Unlock the host
screen".
_Avoid_: remote unlock, screen unlock, password injection

**Login password**:
The password that unlocks the host machine's own login window, typed once at
the viewer's request during lock-screen unlock and never stored, logged, or
written to disk.
_Avoid_: passcode, PIN

**Waking the screen**:
What the host does to a sleeping display when a session starts, and keeps doing
for as long as that session runs. macOS draws nothing to a sleeping display, so
a session that did not do this would stream nothing at all. On screen it is
called "waking the screen".
_Avoid_: power assertion, caffeinate, keep-awake, idle inhibit

**Ask me first**:
A per-machine host-screen setting, off by default, that asks the person at
the host to approve a session before it starts if someone has used that
machine in the last few minutes. Arming a machine for host screen is already
the consent the feature needs; this is an extra a person may switch on for
one machine alone. With it off, the badge and Stop are what protect a person
working at the host.
_Avoid_: presence prompt, consent prompt

**Presence-bound credential**:
A keypair a viewer's operating system or authenticator will not use without a
live human confirming at that moment, registered with the host when the two
machines pair, and signed over a challenge the host issues for each
host-screen session. Proves a person was present; names no specific
platform mechanism.
_Avoid_: biometric, passkey, security key

**Surface**:
One of the at most two slots a session streams, each owning its own canvas,
capture, and input; surface 0 is the primary. Never named on screen, where the
person sees "displays".
_Avoid_: display index, slot, monitor

**Workspace**:
The window the host places on a session canvas for the person to work in.
_Avoid_: desktop, launcher

**Shortcut strip**:
The pinnable strip at the top of the viewer's session window that sends
system shortcuts a viewer machine would otherwise keep for itself — Mission
Control, Spotlight, Command-Tab, and the rest — on to the host instead.
_Avoid_: hotkey bar, toolbar, macro bar

**Canvas identity**:
The vendor, product, and serial a session canvas presents to macOS; identity is
what macOS refuses when a canvas from an earlier host was left behind.
_Avoid_: display serial, EDID

**Capability probe**:
The canvas the host creates and releases at startup to prove this machine can
create one at all.
_Avoid_: preflight, startup check

### Picture quality

**Stream scale**:
The resolution the host encodes a surface at, relative to the viewer's
drawable size.
_Avoid_: zoom, resolution factor

**Fidelity ladder**:
The trade-offs the host makes when the encoder, link, or viewer cannot keep
up. Stream scale goes first and is chosen from the encoder's measured cost
per pixel, so a moving picture keeps its frame rate. Frame rate and quality
move only once the scale is at its floor.
_Avoid_: adaptive bitrate, quality controller

**Lever**:
One of the three things the ladder can spend: stream scale, frame rate,
encoder quality.
_Avoid_: rung, level, tier

**Still-screen refresh**:
A single high-quality key frame the host sends when the picture has stopped
changing, so a still screen is sharp.
_Avoid_: sharpening, high-res snapshot

### Endings

**Stop**:
The host's control, in its window and menu bar, that ends the live session at
once.
_Avoid_: disconnect, kill, end session

**Released canvas**:
A session canvas the host has removed and whose identity is free again.
_Avoid_: destroyed, torn down

**Capture unavailable**:
The host state in which this process can no longer stream any picture; only
quitting and reopening the host clears it, and the host refuses every canvas
while it lasts.
_Avoid_: wedged, broken host, degraded

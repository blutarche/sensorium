# Linux host design

The Fedora 44 host has been built and package-tested for x86-64. A logged-in
Plasma desktop streamed to the macOS viewer over Tailscale, and restarting
the host in the same graphical login restored the sharing grant. The checks
below cover additional desktop behavior before claiming support for
unattended use across locks and fresh logins.

## Scope

The Linux host streams the **host screen** only. It offers no session
canvas, no sharp screen and no display mode changes. A viewer already
handles a host that offers none of these: `hostScreenModeList` is never
sent, and a `canvasRequest` is refused with `canvas-unavailable`.

It targets Wayland on KDE Plasma 6. Fedora KDE 44 is the reference
machine. GNOME is not supported: Mutter offers neither layer shell nor a
way to read idle time, so the indicator and ask-first rules below cannot
hold there. A host on GNOME says so and offers no host screen. X11 is
out of scope.

The host needs a graphical login. Before anyone has logged in there is
no Wayland session, no portal and nothing to capture, so the host is not
running.

## One host, two platforms

The session logic stays in one place. `SensoriumHost` talks to its
platform through a few seams:

| Seam | macOS today | Linux |
|---|---|---|
| `HostByteChannel` | `NWByteChannel` over a Network.framework QUIC stream | one stream of an OpenSSL 3.5 QUIC server connection |
| host TLS identity | Security framework | OpenSSL, same certificate shape and pin |
| `HostFrameSource` | ScreenCaptureKit | PipeWire stream from the ScreenCast portal |
| encoder | VideoToolbox | libavcodec `h264_vaapi`, `libopenh264` as the software fallback |
| `InputInjecting` | CoreGraphics events | RemoteDesktop portal `Notify*` methods |
| display inventory | CoreGraphics display list | the granted portal stream |
| lock state | `CGSessionScreenLockState` | `org.freedesktop.ScreenSaver.GetActive` |
| lock | CoreGraphics lock request | `org.freedesktop.ScreenSaver.Lock` |
| local activity | HID idle seconds | `org.freedesktop.ScreenSaver.GetSessionIdleTime` |
| indicator | menu bar badge, corner pill | layer-shell corner pill, tray item |
| login item | `SMAppService` | XDG autostart entry |

`SensoriumHost` is made to compile on Linux. Files that are macOS only
are wrapped in `#if os(macOS)`. The Linux implementations live in a new
target, `SensoriumLinuxHost`, so `SensoriumHost` never links a Linux C
library. Pairing, arming, the authenticated hello, resume tickets and
the session record are the same code on both platforms.

**Gates live in shared code.** Today the macOS app's own wiring puts the
badge and session record around host-screen media and reads the Screen
Recording grant. The port moves that requirement into `SensoriumHost`:
host-screen media cannot be built without an accountable wrapper and a
capture grant gate, and showing the badge can fail. A badge that cannot
be shown refuses the session before any frame leaves. Each host-screen
gate in `CLAUDE.md` is enforced in shared code on both platforms:
capture grant, paired and armed device, ask-first, indicator and session
record.

## Transport

The Linux host listens with OpenSSL 3.5's QUIC server API
(`SSL_new_listener`, `SSL_accept_connection`, `SSL_accept_stream`). It
selects only the Sensorium ALPN, keeps OpenSSL's default 30 second idle
timeout, which matches the macOS host's (OpenSSL cannot set it on an
accepted connection), and presents a self-signed certificate of the same shape as the macOS
host's, minted with OpenSSL. Both viewers connect unchanged: the macOS
viewer through Network.framework, the Linux viewer through
`OpenSSLQUICConnection`. The viewer opens one bidirectional stream and
writes `hello` first, so the host accepts that stream and every packet
travels on it, as today.

OpenSSL 3.5's server sends a Retry before the handshake, which costs one
round trip and which Network.framework handles. It does not support
connection migration, and it does not report an accepted connection's
peer address, which the source address rule needs. A viewer
whose address changes reconnects, and the resume ticket brings the
session back the way it does after any other drop.

The listener binds the tailnet address only. The Linux host offers no
local network switch because it cannot check the source address of a
connection. Interop with both viewers is a hard gate.

## Capture and input: one portal session

The host opens one `org.freedesktop.portal.RemoteDesktop` session. It
calls `SelectDevices` with keyboard and pointer and `persist_mode` 2,
which needs RemoteDesktop interface version 2 or later. It then calls
`ScreenCast.SelectSources` on the same session to request physical monitor
streams. KDE 6.7 supplies one stream for each physical monitor when
multiple sources are requested.

**Granting.** The person at the host approves access in KDE's remote control
dialog. **Update Screen Sharing…** opens that dialog again for an existing
grant. The viewer's **Screen** menu offers the monitors covered by the
grant, and switching connects to the chosen monitor as a fresh session.

**Restore tokens.** The portal may hand back a new token on every
successful `Start`, and then the old one stops working. KDE 6.7 hands back
the same token again. The host writes whatever token it gets atomically
before it does anything else with the session, owner only, in its own
data folder.

A token the portal cannot use is not refused. The portal ignores it and
shows the dialog on the host's screen. A host that nobody is sitting at
would then wait forever. So the host restores the session once, at
launch, and keeps it open for its whole life. Every viewer session
reuses that one portal session. If the launch-time `Start` does not
return within 15 seconds, the host closes the portal session, which
takes the dialog down, and shows "Screen sharing needs to be allowed
again" in its window. Until someone grants it again, the host offers no
host screen and a viewer is told the host screen is unavailable.

**What the token is.** The token is a bearer grant. Any program running
as the same user can read it and restore capture and input without a
dialog. On macOS the grant is tied to the app's signature; here it is
not. `docs/threat-model.md` must say so in those words. A program running
as the owner's user can already read the screen and type through other
means on most desktops, so this widens nothing that matters, but it is
stated rather than hidden.

**Encoder.** Stock Fedora's VA-API driver has no H.264 profiles. A host
with the RPM Fusion `mesa-va-drivers-freeworld` driver encodes on the GPU
(about 9 ms a frame at 2560x1440 on the reference machine); every other
host falls back to OpenH264 on the CPU. The host never installs a driver.

**Frames.** The portal hands back a PipeWire node for each granted monitor.
The host reads the nodes with libpipewire and encodes the selected monitor
from shared-memory frames. DMA-BUF import into VA-API is not implemented.
A node is read only while a session watches its monitor, because a
running screencast has the compositor render and copy out a picture on
every change. At the grant the host reads each node just long enough
for one frame, which gives the monitor's size, and stops. A session that
starts reading gets the picture on screen as the stream's first frame.
The cursor arrives as metadata and is left out of the frame, as on the
macOS host, because the viewer draws its own.

**Geometry.** The advertised logical size is the stream's `size`
property. The backing scale is the PipeWire buffer width divided by it.
Pointer positions go to `NotifyPointerMotionAbsolute` in those logical
coordinates, so fractional scaling maps exactly. The display identity in
`hostScreenList` is the stream's `id` property when the portal gives
one, and otherwise a hash of the monitor's position and size. Only granted
monitors with a known frame size are offered.

**Input.** Buttons go through `NotifyPointerButton` with evdev codes,
scrolls through `NotifyPointerAxis` and `NotifyPointerAxisDiscrete`, and
keys through `NotifyKeyboardKeycode`. The viewer sends macOS virtual
keycodes on the wire, so the host maps them to evdev with the inverse of
the Linux viewer's table. Where that table sends two Linux keys to one
macOS key, the host picks the PC key: virtual keys 105, 107 and 113 post
Print Screen, Scroll Lock and Pause. A key the viewer sends with modifier
flags but no modifier keys down gets those modifiers pressed around it.
Stop, disconnect and `releaseAllInput` release every key and button the
host still holds.

**Caps Lock differs.** `docs/protocol.md` has the macOS host post letters
with the Alpha Shift flag so the host's own Caps Lock never changes. The
portal has no such flag. The Linux host instead holds Shift around a
letter key while the viewer's Caps Lock is on, and never touches the
host's Caps Lock. Letters come out right. If the host's own Caps Lock is
also on, letters come out lower case; the host cannot read that state
through the portal. `docs/protocol.md` gets a paragraph for this.

libei is not used unless `Notify*` proves too slow or too limited.

## Lock state, relock and lock at launch

The host reads the lock state every two seconds from
`org.freedesktop.ScreenSaver.GetActive` and sends `hostScreenLockState`
on each change, as macOS does.

**Relock on session end.** The macOS rule (`host-screen-design.md` §9.5)
is ported unchanged. When a session that found the host locked, or that
saw it unlocked during the session, ends with no local activity since,
the host locks the screen with `org.freedesktop.ScreenSaver.Lock`. Local
activity comes from `GetSessionIdleTime`, with the host's own posted
input discounted exactly as on macOS.

**Lock at launch.** An unattended Linux host after a reboot needs
automatic login, which leaves it unlocked. The macOS rule (§9.6) is
ported: when the host starts in a session nobody has touched since login,
it locks the screen first. Without this, "reachable after a reboot"
would mean "sitting unlocked after a reboot".

Both only help if a viewer can unlock the lock screen. That is open
question 3. If it fails, the Linux host is not unattended: after a lock,
someone has to unlock it at the machine.

## Host app

`sensorium-host` is a GTK4 app, installed by its own RPM next to the
viewer's. The host window shows the pairing code, paired machines with
per-device arming and Ask first, the screen sharing grant, and Open at
login. It uses the system font and the shared design tokens.

**Indicator.** While a host-screen session is live, the host shows a
corner pill on every output through `zwlr_layer_shell_v1`, naming the
device, with a Stop control that ends the session at once. A tray item
(StatusNotifierItem) and the host window also carry Stop, matching the
macOS host's three places. Layer shell is a requirement, not a nicety:
without it the host offers no host screen.

**Ask first.** When Ask first is on and someone used the machine in the
last few minutes, the host shows a GTK prompt naming the device, with
Allow and Deny. It times out to Deny.

**Records.** The session record and arming record are the same JSON files
the macOS host writes, under `$XDG_DATA_HOME/sensorium-host`.

**Updates.** The host updates itself from a signed release, as section 12
of `docs/self-update-design.md` describes. It installs once no machine is
connected and no pairing is in progress. It hands over to the new version
only once the new one serves with the same identities, paired machines and
address, and keeps serving if it does not. The new version runs as the old
one's child, so the desktop sees the same app and the saved portal grant
restores without a dialog.

## What is not ported

Session canvas, sharp screen, display mode changes and display wake have
no Linux counterpart in this first version. The host never advertises
them, and every message about them is refused the way a macOS host with
the feature off refuses it.

## Rules

`CLAUDE.md` lets the Linux host write its own XDG autostart entry for
Open at login, and words the invariant for PipeWire capture and portal
input.

## Open questions

These checks exercise the real Plasma session. The automated host and viewer
smoke covers frame rendering, input delivery, and Stop with a synthetic
monitor and no desktop login.

1. **Silent restore.** A stored token restores sharing after a host restart
   in the same graphical login. A reboot and fresh login still need checking.
2. **Lock screen frames.** While the session is locked, does the portal
   stream show the lock screen, a frozen frame, or nothing?
3. **Lock screen input.** Does portal input reach the lock screen, so a
   viewer can type the password?
4. **Indicator.** Does the layer-shell pill stay above full-screen windows
   and the lock screen?
5. **Idle time.** Does portal input reset `GetSessionIdleTime`? The
   discount rule depends on the answer.
6. **Display off.** Does the stream keep delivering frames while the
   monitor is powered down?
7. **Latency.** Is `Notify*` over D-Bus fast enough for pointer motion?

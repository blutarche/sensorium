# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches 1.0.

## [Unreleased]

## [0.5.8] - 2026-10-24

### Changed

- A large picture is sent smaller while you scroll or drag, and sharp again
  half a second after it stops moving, so scrolling keeps up. The host
  judges motion from the pixels that changed, so a blinking caret, the
  pointer or a small animation leaves the picture sharp.
- The host now captures the screen in the colour format its video
  encoder takes directly. The encoder no longer converts every frame
  itself, which saves about 2 ms per frame on a full-size display. The
  picture's colours are unchanged.
- The host window has clearer status text, spacing and contrast.
- Linux session menus have more space between their titles.

### Fixed

- Stream diagnostics scroll within the viewer window on macOS and Linux,
  keeping every row and control reachable.
- Host-screen recovery controls offer actions the connected host supports
  and retry the same screen.
- About Sensorium shows the packaged version on Linux.
- The macOS viewer fills the available screen when maximized.

## [0.5.6] - 2026-10-23

### Removed

- The host no longer asks you to turn on Screen Sharing. Typing reaches the
  lock screen without it.

## [0.5.5] - 2026-10-23

### Added

- The host asks you to turn on Screen Sharing when it is off, so your other
  machine can type at this machine's lock screen.
- The host now writes its session log to the system log, so it is kept when
  the host is opened from Finder. It notes whether the screen was locked when
  input arrived, never what was typed.

### Fixed

- Typing no longer stops while the host sets up its video encoder.
- A quality change made while a stream is starting is no longer lost.
- A screen capture that fails to start is stopped before the host tries again,
  so two captures never run at once.

## [0.5.4] - 2026-10-22

### Fixed

- Typing at a locked host no longer stops when the host's video encoder
  stalls. The host now waits for the encoder away from the part that types,
  so keys reach the lock screen and the host can still quit.
- The host now types and clicks as soon as Accessibility is turned on. It no
  longer has to be quit and opened again first.
- Quit and Try Again work again after the person at the host presses Stop.

## [0.5.3] - 2026-10-21

### Fixed

- The host now closes a connection whose request for a screen it refused.
- The host now cleans the name a connecting machine reports before it shows
  it in the menu bar and the host log.

## [0.5.2] - 2026-10-21

### Added

- The back and forward buttons of a mouse now work on the host. The
  viewer sends them only to a host that accepts them.
- Caps Lock at the viewer now types capitals on the host.
- A mouse wheel that turns in steps now scrolls the host by lines, as a
  wheel plugged into the host would. A trackpad still scrolls smoothly.

### Changed

- The viewer's own shortcuts now use Control-Option-Command. Command,
  Command-Shift and Command-Control shortcuts now reach the host.
  Command-Q, Command-H and the Edit menu stay with the viewer.
- The host now sends the picture at exactly the size the viewer's window
  draws it, and the viewer draws it pixel for pixel. Before, the host
  picked the nearest of a few fixed sizes and the viewer stretched the
  picture to fit, which blurred text.
- The host now closes a connection that does not start pairing or a
  session within 15 seconds of connecting. It also closes one that has
  not paired or signed in after 330 seconds, and one that signed in but
  asked for no screen within 60 seconds.

### Fixed

- The host's screen no longer goes to sleep and locks about 10 seconds
  after a viewer connects to a host that has been idle.
- A pairing code typed more than 30 seconds after it was shown now
  pairs. Before, the viewer said it could not reach the host.
- Double-click works on the host.
- Input reaches the host as a physical keyboard and mouse would send it.
  A held key repeats like a real one. A drag survives another button's
  release. Keypad keys and Command-Shift-Tab work.
- The click that brings the viewer's window to the front now reaches the
  host. So do drags with the middle button.
- A key pressed with Command held is now released on the host.
- Clicks and keys now reach the host in the order you made them.
- A mouse wheel on the macOS viewer scrolled the host by a few pixels
  per step. It now scrolls a normal distance.
- The Linux viewer:
  - treats Right Alt as Option on layouts that use it for special
    characters
  - forwards the Japanese input keys and sends Insert as Help
  - keeps the desktop's shortcuts away in every session window, not only
    the first
  - no longer sends a scroll made over its own controls
  - always tells the host when a key is released
- The Resolution menu names the sizes the host actually offers.
- Making the window larger now makes the picture sharper at once.
- A resolution chosen before the picture started is now used as soon as
  it starts.
- A session no longer ends when one side sends a message the other does
  not know. Newer and older versions can now add features without
  breaking each other.

## [0.5.1] - 2026-10-15

### Added

- The disk images open to a designed window: drag the app onto
  Applications.

### Changed

- The host now sends a full picture every 10 seconds instead of every
  second, when the viewer can ask for one. A full picture is many times
  the size of a normal frame and holds up the frames behind it, so this
  removes most of the regular delay spikes. When the viewer misses
  frames, it asks, and the host still sends a full picture at once.
- A viewer that was asleep for longer than the host keeps a session open
  now starts a new session by itself when the host reports the old one
  expired, instead of stopping with "could not resume". It asks once for
  the same screen, and the host's usual checks apply. A session the person
  at the host stopped, or one lost to a host restart or a change to what the
  machine is armed for, is never restarted this way.
- The viewer no longer holds frames back while you are using the host.
  Within half a second of any click, key press, scroll or pointer move,
  each frame is shown as soon as it arrives, which takes about 30
  milliseconds off the wait for what you just did. Video and animation
  you only watch are still paced evenly.
- A host with no monitor now streams a sharp picture. macOS gives such a
  host a placeholder screen of 1920x1080 pixels at 1x, which looks soft on
  a high-density viewer. A session on it now streams a screen of 1920x1080
  points at 2x, which the host creates in its place. The viewer still sees
  "External Display", with no resolution choices. Connecting a monitor
  ends the session, and macOS brings the placeholder back once the host
  lets that screen go.
- The host now encodes large pictures faster while the screen moves. It
  uses the H.264 Constrained Baseline profile for every stream instead of
  Main. In a test with fast-scrolling text at 3584x2016 pixels, the
  slowest frames took 50 milliseconds instead of 84, and the key frame
  sent once a second during motion took under half as long. Detail at the
  same bit rate is very slightly lower.
- When the host cannot keep up with the full picture, it now keeps the
  picture sharp and lowers the frame rate first, from 60 to 45 to 30
  frames a second, so text stays easy to read. The picture gets smaller
  only if 30 frames a second is still too much, and softer only after
  that. As things improve, the full size comes back before the frame
  rate climbs above 30.
- Text stays crisper when the viewer's window is larger than the picture
  the host sends. The viewer now enlarges the picture with a sharper
  filter. A picture drawn at its own size or smaller looks as before.

### Fixed

- Release builds no longer contain the build machine's folder paths.
- Copied text could bounce between the two machines for minutes. When
  something else on a machine wrote the same text back to its clipboard,
  such as the system's own clipboard syncing, Sensorium sent it across
  again. The same text is no longer sent back within 30 seconds, so a new
  copy is not overwritten by an old one coming back.
- The delay the viewer shows grew over a long session even when nothing
  changed. The two machines' clocks drift apart slowly, and the viewer kept
  using its best measurement of the difference from early in the session.
  It now uses only the last five minutes of measurements, so the figure
  stays true after hours.
- The viewer's picture could freeze for a minute or more after its window
  had been in the background. While hidden, the viewer took in each frame
  late, and then mistook that delay for the network's. Every later frame
  was held for that long, and a newer one replaced it before its turn
  came. Only while you clicked or typed did the picture move. A frame now
  waits at most 50 milliseconds after it arrives.
- Asking for a screen the host had just lost, such as a monitor that went
  to sleep, said that host screen was turned off for this machine. The
  viewer now says the screen you chose is no longer available there.
- A host screen session could end by itself a couple of minutes after
  the screen went still. The sharp picture the host sends of a still
  screen could freeze the host. A frozen host read nothing from the
  viewer, so after 20 seconds it ended the session. Sending that picture
  no longer freezes the host.
- On a slow link, a mostly still host screen could stall for about half a
  second every few seconds. Each time the screen settled, the host sent a
  large sharp picture of it, and the next change waited behind it. The
  host now times each of these pictures. After one that took more than a
  tenth of a second to send, the next waits at least 30 seconds, twice as
  long after each slow one in a row, up to four minutes. The host log
  shows how long each one took to send.
- The host could lower the picture for a viewer that was keeping up.
  Time a frame spent waiting before the viewer began to decode it counted
  as slow decoding. On a quiet screen, the viewer takes a little longer
  over each of its few frames, and that counted as the viewer falling
  behind. The host now tells both apart from a viewer that is really
  behind.
- The viewer could show broken blocks for up to a second while the
  picture was changing. When the link fell behind, the host threw away
  frames it had already encoded. The frames after them could not be
  drawn correctly until the next full frame. The host now waits to
  encode while the link is busy, so it rarely has to throw an encoded
  frame away. If one is still lost, the host sends nothing more for
  that screen until a full frame, and asks for one at once. The host
  log notes each time it asks.
- The stream no longer drops its frame rate while you drag a window or
  move the pointer. Frames that arrive together can only show the newest,
  and the host used to read that as a viewer falling behind and cut the
  rate from 60 to 45. It now counts them as kept up with and lowers the
  rate only for a viewer that really is behind.

## [0.5.0] - 2026-10-11

### Added

- Each release carries a disk image for each macOS app,
  `Sensorium-<version>.dmg` and `Sensorium-Host-<version>.dmg`. Open it
  and drag the app onto the Applications shortcut. The zips stay on the
  release for self-update.

### Changed

- When the host offers no screen, the viewer now says "The host has no
  screen available to share right now."
- Windows and messages in both apps say "machine" or "the host" where
  they said "Mac".

## [0.4.3] - 2026-10-10

### Fixed

- A host update that was waiting on a pairing code now installs once the
  code expires, not at the next check up to six hours later.

## [0.4.2] - 2026-10-10

### Fixed

- After an update, the old host could stay open without serving, and the
  new one would not update again until it was gone. The old host now
  quits. A host updating from 0.4.0 or 0.4.1 has its stuck old copy ended
  after 30 seconds.

## [0.4.1] - 2026-10-10

### Fixed

- When an update fails in a way that could pass on another try, and the
  app puts the old version back, the app now waits for its next scheduled
  check before trying that release again. It had tried again as soon as
  the old version opened, so a host could go offline up to three times in
  a row within minutes. **Check for Updates…** still tries at once.

## [0.4.0] - 2026-10-10

### Added

- Both macOS apps now update themselves. Download them once from the
  release page and later versions arrive on their own. Each app checks
  this project's GitHub releases when it opens and every six hours. It
  installs a release only if it is signed with the project's update key
  and the same certificate as the running app.
- Sensorium Host installs an update only while no machine is connected
  and no pairing is under way. It keeps its paired machines, its
  identity, its address, **Open at login**, and its Screen Recording and
  Accessibility permissions. If the new version does not start and serve
  the same way, the host puts the old version back.
- The viewer installs a downloaded update the next time it quits, or at
  once with **Restart Now** in Your Machines while no session is open.
- **Install updates automatically** in the host window and **Check for
  Updates Automatically** in the viewer's Sensorium menu, both on by
  default. **Check for Updates…** sits in the host's menu bar item and the
  viewer's Sensorium menu.
- Releases carry `Sensorium-<version>.zip` and
  `Sensorium-Host-<version>.zip`, ready to unzip into Applications.

## [0.3.0] - 2026-10-06

### Added

- The host window has a new setting, **Allow connections from this
  network**. It is off by default. When it is on, a viewer on the same
  Wi-Fi or wired network can connect by a name such as `mini.local`,
  without Tailscale. Pairing works the same way as before. Turning it off
  ends every session that did not come over Tailscale. The host still
  needs Tailscale to start.
- A paired machine can be renamed from the **…** menu on its row in Your
  Machines, on both viewers. The name is kept on the viewer only,
  survives pairing again, and an empty name puts the original back.
- The person at the host can rename a paired machine with **Rename** on
  its row in the host window. The host shows that name everywhere it names
  the machine, including the badge and the session record. The name is kept
  on the host only, the name the machine reports never replaces it, and an
  empty name puts the reported one back. On both sides, a machine's name
  is shown without invisible or text-reversing characters, on one line,
  and cut to 64 characters.
- When the Linux viewer decodes video on the CPU, its diagnostics panel
  says so and links to the install guide's steps for faster video on
  Fedora.

### Changed

- The shortcut strip is now pinned by default on both viewers. A viewer
  that has never had the pin changed, or whose pin file cannot be read,
  starts with the strip pinned.

### Fixed

- The Linux viewer now remembers whether the shortcut strip is pinned,
  so a pin set once stays set for the next session.
- The first change after the host screen was still appears at once,
  without the short hold the viewer adds to keep motion smooth.
- The Linux viewer sends keys, clicks and pointer moves to the host in
  the order they happened.
- On a Linux viewer whose video decoder is OpenH264, as on a stock
  Fedora install, the last change on a still host screen no longer
  waits up to a second to appear. That viewer now asks the host for a
  simpler kind of video its decoder shows at once. Other viewers are
  unchanged.
- The Linux viewer no longer says it decodes in hardware when its
  video decoder is one that only decodes in software.
- Clicking a machine whose host is briefly unreachable keeps trying until
  the host answers, instead of stopping after one failed try with a line
  saying the connection dropped.
- That line now reads "The connection dropped before the screen came up.
  Connect again to ask for it."
- The host keeps accepting connections after Tailscale restarts on its
  machine. It had stopped answering until it was quit and opened
  again.

## [0.2.0] - 2026-09-29

### Added

- A Linux viewer for Fedora 44 with Wayland, delivered as an RPM. It
  pairs, lists the machines it is paired with, and runs a session on a
  virtual display. There is no Linux host.
- Host screen for every paired device, once armed, with no security key
  or Touch ID needed at session start.
- A notice at first launch on a machine with no hardware video decoder
  Sensorium can use, saying it will decode in software and use more
  power.
- Open at login, on by default, so an unattended host comes back
  reachable after a restart. A switch in the host window turns it off.
- Lock at start: if the host launches with its screen unlocked and no
  one has touched this machine since before the process started, it
  locks the screen again before doing anything else.
- Offer a private desktop, a switch in the host window, off by default.
  It lets a viewer open a separate desktop that isn't shown on this
  machine's screens. While it is off, the host creates no virtual display at
  all, refuses a viewer that asks for one, and tells the viewer none is
  available so its menus do not offer one.
- The menus a Mac app is expected to have. The viewer gets a standard
  Edit menu (Undo, Redo, Cut, Copy, Paste, Select All) for its pairing
  fields, a Window menu (Minimize, Zoom, Bring All to Front), Show All in
  the app menu, a full screen item that reads Enter or Exit Full Screen,
  and reopens the Your Machines list from the Dock icon when no window
  is open. Every one of these keys still reaches the host while a
  session window is key, exactly as before. Sensorium Host gets the same
  standard menus for its own Host Setup window, with Quit going through
  its usual clean shutdown, and its About panel now comes to the front
  when opened from the menu bar.
- The host's menu bar shows the live round trip to the connected viewer,
  such as `8ms`, in place of the device's name while a session is
  streaming. It updates about once a second, smooths out jitter, and
  goes quiet again if no fresh reading arrives for a few seconds.

### Removed

- The presence-bound credential a device registered at pairing and the
  per-session proof it signed before host screen or lock-screen unlock.
  Pairing itself now arms a device for host screen; the host can disarm
  and re-arm any paired device at any time.

### Changed

- The Linux viewer has the Mac's menu bar, with the same menus, across
  Your Machines and the session window. Every session choice lives in
  its menus, so the Session Settings window and its Ctrl-Shift-Super-K
  chord are gone.
- The Linux viewer now looks like the Mac viewer. Its status panels,
  shortcut strip, notices, diagnostics panel and windows use the same
  sizes, colours and spacing, and the strip draws its own icons, shaped
  like the Mac's.
- The Linux viewer's windows (Your Machines, pairing and messages) are
  drawn like the Mac's, with the same surfaces, sizes and labels,
  instead of the desktop theme's buttons and fields.
  They draw no focus ring or hover look the Mac does not, Tab moves
  between fields as on the Mac, and the Look Again, Enter Address
  Manually and Back links carry the same icons on every desktop theme.
- Selected text and the text cursor in the viewer's fields use
  Sensorium's own colours on both platforms, not the system highlight.
- A long machine name ends in "…" on the Mac as it does on Linux.
- The pairing code placeholder stays centred in its field while the
  field is being typed into on the Mac.
- Scale choices on Linux read "1.00x (1920 × 1200)".
- The reason a viewer cannot start begins with a capital letter.
- A machine paired without a name shows its address once, with only its
  status on the line below.
- The Linux viewer shows the Sensorium icon in the taskbar and the
  window switcher.
- The shortcut strip is 40 points high on the Mac, and every button
  label is 13 points.
- Viewer messages and buttons use Title Case, and a refused host screen
  says how to try again. After a host screen session ends, Return picks
  Your Machines, never the private desktop.
- Clipboard sharing is on by default. The viewer can still turn it off
  from the View menu, and the host follows the viewer's choice.
- Clipboards up to about 4 MB are shared, up from 1 MB. A copied TIFF
  image is sent as PNG.
- A copy that offers both text and an image is sent as whichever the
  copying app listed first. If that one is too large, the other is sent.
- The wire messages for registering and proving a host-screen credential
  are gone. An app built before this change that still sends one of them
  is not disconnected for it; the other side now treats that message as
  unrecognized, the same tolerance any future message gets.
- On first launch after this update, every machine paired with a host is
  armed for host screen, including machines the person at the host had
  turned off and machines that were never armed. Turn any of them off
  again in the host window.
- An authenticated hello now names and signs the SHA-256 of the host's
  TLS certificate, the one the viewer pinned when it paired, and a host
  refuses a hello naming any other certificate. This stops a host a
  viewer once paired with from replaying that viewer's hello to another
  host. Its signed transcript is now `sensorium-authenticated-hello-v2`,
  and the pairing request's is `sensorium-pair-request-v2`, so no
  signature made over either earlier version can be read as the newer
  one. The host and the viewer must be updated together.
- A pairing request must carry the signature that proves the machine
  sending it holds the key it names. A request without one is refused as
  malformed, and one whose signature does not verify ends the
  connection. Every viewer this project has shipped already signs.
- A host-screen request that the person at the host declined, or left
  unanswered, is now refused for the rest of that connection with the
  same reason, and asks nobody again. Reconnecting still asks, as it
  always did.
- An arming record that exists but cannot be read is now treated as
  arming nothing at all, and is named once in the host's log. Before,
  such a file read as an empty record, and the next launch re-armed
  every paired machine, undoing every machine the person at the host had
  turned off.
- Lock-screen unlock has no panel, button or password prompt: typing,
  clicking and scrolling in the session window reach the host's lock
  screen as ordinary forwarded input. Screen Sharing is not needed. The host also
  reports its lock state whenever it changes during a host-screen
  session, not only right after an unlock attempt.
- Turning screen control off for a machine ends that machine's live
  host-screen session at once, the same way the host's Stop control does.
  Before, a live session carried on until it ended by itself.
- Removing a paired machine ends every connection it has at once, session
  canvas included, and the running host refuses it from then on. Before,
  a removed machine could reconnect until the host restarted.
- A session canvas no longer sends any input to this machine while it is
  locked. Only a host-screen session reaches the lock screen.
- A machine turned off or removed while the ask-first prompt is showing
  is refused, even if the person then allows it.
- The viewer always starts on one of the host's screens: the one it
  last used if the host still offers it, otherwise the first one. It
  never switches to a virtual display on its own. A virtual display
  opens only when you choose it from the Screen menu, and only when the
  host offers one. When the host offers no screen, the viewer says
  "This Mac has no screen available to share right now."

### Fixed

- Text in the Linux viewer's machine list and pairing windows stays on
  the same lines across desktop fonts, including Nimbus Sans and FreeSans.
- The live host-screen badge opens and stays on the display being shared,
  including after a drag or display mode change. A remembered badge position
  is read and saved for that display.
- A host unlocked from the viewer locks again when the session ends,
  even after the viewer typed or clicked while it was unlocked. That
  input no longer counts as a person at the host.
- The host no longer keeps the machine marked as in use once a connection
  or session is over, so it can sleep and lock on its own again.
- A host-screen session no longer loses its picture right after it
  starts on a machine whose monitors had already idle-timed-out. The
  host now keeps the machine marked as in use from the moment it wakes a
  display for a request through to the end of the session that
  request starts, instead of letting go the instant the wake itself
  returns -- the gap that let the monitors go back to sleep with the
  session already live.
- Clipboard sharing works during host-screen sessions.
- A clipboard that is not shared now says why in the session window.
- A copy made in another app just before switching back to the viewer
  is sent before the first keystroke, so pasting right away pastes it.
- Typing reaches a locked host's lock screen again.
- A host-screen session that unlocked the machine, or found it unlocked
  by the person at the host, now locks it again when the session ends or
  the host quits, unless someone is using the machine itself. A session
  that never saw the screen locked, or that leaves it locked, never does.
- A viewer's forwarded keystrokes no longer read as a person at the host
  machine: the local-activity check the presence prompt and relock both
  rely on now discounts idle time this host's own forwarded input could
  explain, sampled immediately before each forwarded post so a real
  person's input right before it is never masked by the post that
  follows.
- A host whose monitors had been turned off by display sleep no longer
  streams a black screen. The host now wakes its displays every time it
  offers its screens and every time a host-screen session starts. It
  waits up to 3 seconds for the monitors to come back before it lists
  them. The stand-in display macOS keeps online while the monitors are
  off is offered only when it is the only display.
- The Screen menu now lists every screen the host offered, with the one
  it is streaming checked, even when a session starts directly on host
  screen instead of a virtual display first.
- A paired device can no longer wake the host's displays without
  starting a session.
- A session that keeps resuming after network drops no longer skips
  asking first for more than twelve hours after it was first allowed.
- A host screen whose monitor went to sleep or briefly disappeared
  mid-session now comes back instead of freezing.
- A virtual display whose picture stops on its own is restarted once.
  If that fails, the session ends instead of leaving the viewer on a
  frozen picture.
- A connection attempt that fails for any reason now closes its
  connection, not only one that timed out.
- The host log says nothing on this machine is being shared any more
  only once the last connected viewer has left.
- A host screen refused before it ever named its own screens no longer
  offers "Connect with a virtual display" on a host that has none.

## [0.1.3] - 2026-09-19

### Changed

- Default shortcut routing is remote-when-focused: a system-reserved
  shortcut such as Cmd-Tab now reaches the host as soon as a viewer
  window has key focus, windowed or fullscreen, instead of only in
  fullscreen.

### Added

- The viewer asks for Accessibility once per run, at the first session
  start, so reserved shortcuts can actually be forwarded instead of
  requiring the grant to already exist. Forwarding starts as soon as the
  grant is given, with no reconnect needed.

## [0.1.2] - 2026-09-17

### Fixed

- A host now notices a viewer that went silent -- lost link, quit app --
  after twenty seconds without a message, drops that connection, and frees
  its host-screen slot, instead of leaving the device marked busy until
  the process restarts. The `host-screen-already-live` refusal shown to a
  reconnecting viewer no longer states a second open window as fact; it
  now also names the wait-and-retry path.
- A viewer now notices a host that went silent for thirty seconds and ends
  the session and reconnects, instead of freezing on the last picture with
  no way back.

## [0.1.1] - 2026-09-16

### Changed

- Product wording no longer names specific computer models. Windows,
  notices, permission prompts, and documentation say viewer machine, host
  machine, and this machine. macOS is named only where a fact belongs to
  that operating system. Linux support is planned, not present.

## [0.1.0] - 2026-09-16

First public release.

### Added

- Pairing between one viewer app (Sensorium) and one host app (Sensorium
  Host), by way of a temporary, single-use six-digit code shown on the
  host.
- Session canvas mode: a session-owned virtual display the host creates
  for the session and removes at disconnect.
- Host screen mode: streaming one existing display of the host as is,
  never created or resized by Sensorium, gated behind arming with a
  registered presence credential and a live presence check at session
  start.
- Display-mode change on the viewer's request during a live host-screen
  session, restored when the session ends.
- Lock-screen unlock as an opt-in action inside a live, presence-verified
  host-screen session, typed into the host's own login window over the
  loopback interface and never stored.
- Pinned-identity QUIC transport between viewer and host.
- H.264 video streaming of the session canvas or host screen.
- Keyboard and pointer input delivery, and clipboard sharing, between the
  two apps.
- Reconnect after a dropped connection.
- Two double-clickable apps (macOS), `Sensorium.app` and
  `Sensorium Host.app`, built with `Scripts/package-apps.sh`. No
  command-line interface for end users.

[0.5.8]: https://github.com/blutarche/sensorium/releases/tag/v0.5.8
[0.5.6]: https://github.com/blutarche/sensorium/releases/tag/v0.5.6
[0.5.5]: https://github.com/blutarche/sensorium/releases/tag/v0.5.5
[0.5.4]: https://github.com/blutarche/sensorium/releases/tag/v0.5.4
[0.5.3]: https://github.com/blutarche/sensorium/releases/tag/v0.5.3
[0.5.2]: https://github.com/blutarche/sensorium/releases/tag/v0.5.2
[0.5.1]: https://github.com/blutarche/sensorium/releases/tag/v0.5.1
[0.5.0]: https://github.com/blutarche/sensorium/releases/tag/v0.5.0
[0.4.3]: https://github.com/blutarche/sensorium/releases/tag/v0.4.3
[0.4.2]: https://github.com/blutarche/sensorium/releases/tag/v0.4.2
[0.4.1]: https://github.com/blutarche/sensorium/releases/tag/v0.4.1
[0.4.0]: https://github.com/blutarche/sensorium/releases/tag/v0.4.0
[0.3.0]: https://github.com/blutarche/sensorium/releases/tag/v0.3.0
[0.2.0]: https://github.com/blutarche/sensorium/releases/tag/v0.2.0
[0.1.3]: https://github.com/blutarche/sensorium/releases/tag/v0.1.3
[0.1.2]: https://github.com/blutarche/sensorium/releases/tag/v0.1.2
[0.1.1]: https://github.com/blutarche/sensorium/releases/tag/v0.1.1
[0.1.0]: https://github.com/blutarche/sensorium/releases/tag/v0.1.0

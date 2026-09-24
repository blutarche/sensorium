# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches 1.0.

## [Unreleased]

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

### Removed

- The presence-bound credential a device registered at pairing and the
  per-session proof it signed before host screen or lock-screen unlock.
  Pairing itself now arms a device for host screen; the host can disarm
  and re-arm any paired device at any time.

### Changed

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

### Fixed

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

[0.1.3]: https://github.com/blutarche/sensorium/releases/tag/v0.1.3
[0.1.2]: https://github.com/blutarche/sensorium/releases/tag/v0.1.2
[0.1.1]: https://github.com/blutarche/sensorium/releases/tag/v0.1.1
[0.1.0]: https://github.com/blutarche/sensorium/releases/tag/v0.1.0

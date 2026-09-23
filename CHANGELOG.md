# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches 1.0.

## [Unreleased]

### Changed

- Clipboard sharing is on by default. The viewer can still turn it off
  from the View menu, and the host follows the viewer's choice.
- Clipboards up to about 4 MB are shared, up from 1 MB. A copied TIFF
  image is sent as PNG.
- A copy that offers both text and an image is sent as whichever the
  copying app listed first. If that one is too large, the other is sent.

### Fixed

- Clipboard sharing works during host-screen sessions.
- A clipboard that is not shared now says why in the session window.
- A copy made in another app just before switching back to the viewer
  is sent before the first keystroke, so pasting right away pastes it.

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

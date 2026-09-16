# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
once it reaches 1.0.

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

[0.1.1]: https://github.com/blutarche/sensorium/releases/tag/v0.1.1
[0.1.0]: https://github.com/blutarche/sensorium/releases/tag/v0.1.0

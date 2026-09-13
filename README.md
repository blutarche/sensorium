# Sensorium

A private remote workstation for two Macs. You sit at one Mac and work on a
virtual display the other Mac creates for you. With permission granted at
the host, you can also see and control one of its real screens.

Two apps, nothing else:

- **Sensorium** runs on the Mac you sit at.
- **Sensorium Host** runs on the Mac you work on.

No account, no relay, no telemetry, no command line.

![Sensorium architecture](docs/architecture.svg)

## Requirements

- An Intel MacBook to view from and an Apple-silicon Mac mini to host.
- macOS 14 or later on both.
- Both on the same Tailscale tailnet. Nothing else can reach the host.

## Getting started

1. Build both apps with `SENSORIUM_ALLOW_ADHOC=1 ./Scripts/package-apps.sh`. See [Install](docs/install.md) to keep permissions across rebuilds.
2. Open Sensorium Host on the Mac mini. Grant what its window asks for.
3. Open Sensorium on the MacBook. Pick the host. Type the six-digit code.

Docs:

- [Install](docs/install.md)
- [Permissions](docs/macos-permissions.md)
- [Privacy](docs/privacy.md)
- [Threat model](docs/threat-model.md)
- [Wire protocol](docs/protocol.md)
- [Host screen mode](docs/host-screen-design.md)

## Status

Works between the two machines it was built for. Pairing, virtual display,
pinned-identity QUIC transport, H.264 video, input, clipboard and reconnect
all run. Not signed, not notarized, not yet tested on other hardware.

## Development

Swift 6. No dependencies. No Xcode needed. Run the tests with
`./Scripts/run-unit-tests.sh`. See [testing](docs/testing.md) and
[CONTEXT.md](CONTEXT.md) for the words the code uses.

## Not in v1

- Changing physical displays. One exception: a host screen's resolution,
  on request, restored afterwards.
- Backend, accounts, browser viewer, relay, telemetry.
- Audio, file transfer, multiple users, access before login.

## License

GPL-3.0. Copyright (c) 2026 blutarche.

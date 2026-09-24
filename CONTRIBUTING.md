# Contributing

Sensorium is a two-app system: a host for macOS, and a viewer for macOS
and for Linux. No CLI surface for end users, no Xcode requirement, no
dependencies.

## Build

Swift from Command Line Tools, no Xcode needed.

```sh
swift build
```

To produce the two double-clickable apps:

```sh
SENSORIUM_ALLOW_ADHOC=1 ./Scripts/package-apps.sh
```

See [docs/install.md](docs/install.md) for what that produces and how to
keep permissions across rebuilds.

On Fedora 44, install what the viewer's Linux targets link against, then
build the viewer alone:

```sh
sudo dnf install swift-lang cairo-devel ffmpeg-free-devel glib2-devel \
  gtk4-devel libglvnd-devel libva-devel libxkbcommon-devel \
  openssl-devel pango-devel pkgconf-pkg-config wayland-devel
swift build -c release --product Sensorium
```

There is no Linux host. See [docs/install.md](docs/install.md) for the
Fedora package and what it installs.

## Test

```sh
./Scripts/run-unit-tests.sh
```

This builds and runs every verification runner in both `debug` and
`release`, plus the Python checks, including the
public-repository audit. See [docs/testing.md](docs/testing.md) for what
each runner and script covers.

## Development discipline

This project follows strict TDD: write one failing test, run it and
confirm it fails for the intended reason, write the minimum code to pass
it, rerun that test, then run the full suite before moving on. A change
without a failing-then-passing test behind it will not be accepted.

Keep code native to the platform it runs on, and dependency-free: the
system's own libraries, nothing vendored. Do not add a package
dependency, telemetry, analytics, crash reporting, a webview, an account
system, or a cloud API.

## Clean-room boundary

Do not copy, import, vendor, fork, invoke, or inspect source from any
other remote desktop or display configuration implementation, open source
or not. Apple's public framework documentation, and small compatibility
experiments you write yourself, are fine. If you looked at another
project's source to write a change, say so in the pull request instead of
submitting it.

## Commits and pull requests

- Keep commits focused; one logical change per commit, with a message
  that explains why, not just what.
- Every pull request must state that `./Scripts/run-unit-tests.sh` passes
  and that no other project's source was copied or inspected.
- Changes touching the host/viewer safety boundary (display handling,
  pairing, arming) need extra care: read
  [docs/threat-model.md](docs/threat-model.md) and
  [docs/host-screen-design.md](docs/host-screen-design.md) first.

## Reporting a vulnerability

Do not open a public issue. See [SECURITY.md](SECURITY.md).

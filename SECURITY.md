# Security policy

## Reporting a vulnerability

Report security issues privately, not in a public issue. Use GitHub's
private vulnerability reporting: go to the
[Security tab](https://github.com/blutarche/sensorium/security) of this
repository and choose **Report a vulnerability**.

Do not open a public issue or pull request for a vulnerability, even a
proof of concept. A public report gives an attacker a head start before
a fix ships.

## What to include

- What you found and why it is a security issue, not just a bug.
- Steps to reproduce it, or a minimal proof of concept.
- The affected version (see `VERSION`) and macOS version.
- What you think the impact is: what an attacker gains, and who is
  exposed.

See [docs/threat-model.md](docs/threat-model.md) for what this project
already defends against and what it explicitly does not, so a report can
focus on what is actually in scope.

## Supported versions

Only the latest 0.1.x release is supported. This project is pre-1.0 and
moves fast; older tags do not receive fixes.

## What happens next

Expect an acknowledgment, then either a fix or an explanation of why the
report is out of scope. Credit is given in the fix's release notes unless
you ask not to be named.

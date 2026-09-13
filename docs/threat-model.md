# Threat model

Who can attack Sensorium, and what stops them.

The host is a workstation with someone logged in. Remote control of it is full control. What is at stake is the host's input authority and screen contents, not any data this project stores.

## Who the adversary is

1. **Another machine on the tailnet.** The realistic adversary. It can reach the host's port and speak the protocol.
2. **A machine on the same LAN or the public internet.** Should not reach the port at all.
3. **A process on the viewer machine.** Out of scope. A compromised viewer machine means a compromised session.

There is no cloud account, backend, relay, or vendor control plane to attack, because none exists.

## Controls, and what each buys

| Control | Enforced in | Stops |
|---|---|---|
| Optional PF anchor on the UDP port, added by hand, not installed by Sensorium | `Scripts/install-pf-rule.sh`, run by hand | LAN and public sources reaching the port |
| Tailnet source check | `SourceAddressPolicy`, applied in `HostNetworkListener` before any session state exists | The same, without depending on the optional PF anchor |
| Signed device hello | `HostSessionController`, verified against the paired key set | A machine that has not completed pairing |
| One-time pairing code | `HostPairingService`, single-use and time-limited | Silent enrollment of a new machine |
| Per-code failure budget | `PairingAuthority`, 10 wrong guesses retire the issued code | Guessing the six digits across repeated connections |
| Per-connection failure cap | `HostSessionController`, 5 wrong guesses end the connection | A single connection working through the code space |
| Host-signed canvas readiness | `SensoriumFrameCodec.canvasReadyTranscript`, verified by the viewer against its pinned key | A machine impersonating the host |
| Canvas-bounded input validation | `HostSessionController` and `ClientSessionController` | Input aimed outside the session canvas |
| Held-input release | `HostSessionController.releaseHeldInput`, plus an explicit viewer release at disconnect | A modifier or button stuck down after a lost session |
| Presence-bound credential | `HostSessionController`, verified against the registered public key over a per-session challenge | Host screen granted to anyone but a live human at the registered viewer |

The source check stands on its own. The PF anchor is one more layer for anyone who adds it. Both viewer and host check input bounds independently.

### Why the pairing code cannot be guessed

The code is six digits, so a machine that reaches the port has a 1-in-10^6 shot per guess. Two caps bound it. A per-code budget allows 10 wrong guesses against the issued code itself, capping total exposure at 10-in-10^6 per ceremony no matter how many connections an attacker opens, and an eleventh attempt is refused even when correct. A per-connection cap allows 5 wrong guesses, so an attacker pays for a fresh handshake every five guesses instead of working through the per-code budget on one connection.

The comparison is constant-time, so a guess cannot be refined digit by digit from how long the rejection took. The code, and any prefix of it, is never logged. The only place it appears is the host's own pairing screen.

### Where the keys are kept

Each app keeps its key in a file under `~/Library/Application Support/Sensorium`, readable by its owner only. Any process running as that user can read it. The macOS keychain would instead show that process a dialog, which people are used to approving. This is the same posture as an ssh or gpg key on disk.

## What is not defended

- **A compromised viewer machine.** It holds the paired key.
- **Physical access to the host.** Out of scope.
- **Traffic analysis inside the tailnet.** WireGuard encrypts payloads. Volume and timing are visible to the tailnet coordination path.
- **Pre-boot and login-window access.** Not supported at all.

## Privacy

No telemetry, analytics, crash reporting, or third-party SDK exists in this repository. Latency traces are local, opt-in, timing numbers only, no addresses, no screen contents.

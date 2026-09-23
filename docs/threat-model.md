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
| Host-screen arming | `HostScreenArming`, `ApprovedDeviceStore`, host-local and host-set only | Host screen granted to a machine the person at the host has not armed |
| Per-machine unlock failure budget | `HostScreenUnlockThrottle`, 5 wrong guesses per machine per host uptime | Brute-forcing the host's login password through lock-screen unlock |

The source check stands on its own. The PF anchor is one more layer for anyone who adds it. Both viewer and host check input bounds independently.

Canvas-bounded input validation does not cover a system hotkey (Mission Control, Spotlight, the Lock Screen shortcut, and the rest `SystemHotkeyChord` recognizes): those post at the same HID tap real hardware uses and reach the whole login session, not only the streaming canvas, even from a canvas-mode session. This is not a gap the canvas bound failed to close -- a paired, armed device is already trusted with the owner's whole session, the same trust a saved password gives any other remote desktop, and a system hotkey reaches nothing a real keyboard at that session could not already reach.

### Why the pairing code cannot be guessed

The code is six digits, so a machine that reaches the port has a 1-in-10^6 shot per guess. Two caps bound it. A per-code budget allows 10 wrong guesses against the issued code itself, capping total exposure at 10-in-10^6 per ceremony no matter how many connections an attacker opens, and an eleventh attempt is refused even when correct. A per-connection cap allows 5 wrong guesses, so an attacker pays for a fresh handshake every five guesses instead of working through the per-code budget on one connection.

The comparison is constant-time, so a guess cannot be refined digit by digit from how long the rejection took. The code, and any prefix of it, is never logged. The only place it appears is the host's own pairing screen.

### What pairing proves

What pairing proves is that whoever held the device at that moment could read the code shown at the host. It does not prove who holds the device later. A stolen or compromised paired device therefore has the same reach as its owner, exactly as with a saved password in any other remote desktop, and nothing in this document describes pairing as more than that. Sensorium asks for no further proof of a person at the viewer: no per-session challenge, no per-action confirmation, no PIN, no biometric.

### Why the login password cannot be brute-forced

Lock-screen unlock (see [Host screen mode](host-screen-design.md)) types the host's own login password into its login window on the viewer's request. A machine's wrong guesses are counted against a shared budget of 5 per host uptime, spent across every connection that machine opens. The budget is cleared by a correct password, by a host restart, or by the person at the host re-arming that machine in the host window, and by nothing else. An outcome that never reflects a real guess -- the screen-sharing service unreachable, the screen already unlocked, a password too long for the credential field, or a connection that died mid-attempt -- does not spend one.

### Where the keys are kept

Each app keeps its key in a file under `~/Library/Application Support/Sensorium`, readable by its owner only. Any process running as that user can read it. The macOS keychain would instead show that process a dialog, which people are used to approving. This is the same posture as an ssh or gpg key on disk.

On Linux the viewer keeps the same files under `~/.local/share/sensorium`, or under `$XDG_DATA_HOME/sensorium` where that variable is set. Each file is owner-read-and-write only, inside a directory only its owner may enter. There is no keyring involved.

## What is not defended

- **A compromised viewer machine.** It holds the paired key.
- **Physical access to the host.** Out of scope.
- **Traffic analysis inside the tailnet.** WireGuard encrypts payloads. Volume and timing are visible to the tailnet coordination path.
- **Pre-boot (FileVault) access.** Not supported at all. FileVault's own unlock screen runs before the host's login window, and before the built-in screen-sharing service lock-screen unlock relies on is running.
- **The Linux package's authenticity.** The Fedora RPM is unsigned. Only a SHA-256 checksum is published beside it, which detects a damaged download, not a substituted one. Anyone who can replace the file on the release page can replace the checksum with it.
- **The loopback unlock connection's peer.** Lock-screen unlock connects to `127.0.0.1:5900`, the built-in screen-sharing service's own port, and does not authenticate that peer beyond the RFB handshake itself. Any local process that binds port 5900 first could receive the login password instead of the real service. Reads and writes on that socket time out after 10 seconds (`RFBLoopbackSocketChannel`, `SO_RCVTIMEO`/`SO_SNDTIMEO`), so a peer that accepts the connection and then stalls cannot hold it open indefinitely. Enabling the built-in service is the host operator's own choice; Sensorium does not turn it on and does not change its behavior. Turning it on makes port 5900 listen on every interface, not loopback alone -- that is the operating system's own service, not a Sensorium listener, and it is exposed there whether or not lock-screen unlock is ever used.

## Privacy

No telemetry, analytics, crash reporting, or third-party SDK exists in this repository. Latency traces are local, opt-in, timing numbers only, no addresses, no screen contents.

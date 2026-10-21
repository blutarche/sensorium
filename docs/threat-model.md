# Threat model

Who can attack Sensorium, and what stops them.

The host is a workstation with someone logged in. Remote control of it is full control. What is at stake is the host's input authority and screen contents, not any data this project stores.

## Who the adversary is

1. **Another machine on the tailnet.** The realistic adversary. It can reach the host's port and speak the protocol.
2. **A machine on the same LAN or the public internet.** A public source should not reach the port at all. A LAN machine reaches it only while the person at the host has turned on **Allow connections from this network**, which is off by default, and only from the same subnet as the host. It then has to pair and sign exactly as a tailnet machine does.
3. **A process on the viewer machine.** Out of scope. A compromised viewer machine means a compromised session.
4. **Someone who can change this project's release page.** Both macOS apps install their updates from it. Replacing a file there is not enough to ship an update, as the controls below show.

There is no cloud account, backend, relay, or vendor control plane to attack, because none exists.

## Controls, and what each buys

| Control | Enforced in | Stops |
|---|---|---|
| Optional PF anchor on the UDP port, added by hand, not installed by Sensorium | `Scripts/install-pf-rule.sh`, run by hand | LAN and public sources reaching the port. It also blocks the LAN viewers **Allow connections from this network** would admit |
| Tailnet source check, widened to the host's own subnets only while **Allow connections from this network** is on | `SourceAddressPolicy`, applied in `HostNetworkListener` before any session state exists | Public and off-subnet sources, without depending on the optional PF anchor. LAN sources too while the setting is off |
| Signed device hello | `HostSessionController`, verified against the paired key set | A machine that has not completed pairing |
| One-time pairing code | `HostPairingService`, single-use and time-limited | Silent enrollment of a new machine |
| Per-code failure budget | `PairingAuthority`, 10 wrong guesses retire the issued code | Guessing the six digits across repeated connections |
| Per-connection failure cap | `HostSessionController`, 5 wrong guesses end the connection | A single connection working through the code space |
| Connection deadlines, measured from accept | `HostNetworkSession` | A connection held open without ever pairing or starting a session |
| Host-signed canvas readiness | `SensoriumFrameCodec.canvasReadyTranscript`, verified by the viewer against its pinned key | A machine impersonating the host |
| Canvas-bounded input validation | `HostSessionController` and `ClientSessionController` | Input aimed outside the session canvas |
| Held-input release | `HostSessionController.releaseHeldInput`, plus an explicit viewer release at disconnect | A modifier or button stuck down after a lost session |
| Host-screen arming | `HostScreenArming`, `ApprovedDeviceStore`, host-local and host-set only | Host screen granted to a machine the person at the host has not armed |
| Signed update manifest, then the zip's SHA-256 | `UpdateSignature` against the Ed25519 key in `UpdatePublicKey`, then `UpdateStager` | An update the maintainer did not publish |
| Same signing certificate as the running app | `CodeRequirementCheck`, the running app's designated requirement | An update signed by anyone else, even with a valid manifest |

The source check stands on its own. The PF anchor is one more layer for anyone who adds it. While the setting is off, the listener is also bound to the tailnet interface alone. While it is on, the listener is on every interface, and the source check is what keeps public and off-subnet sources out. Both viewer and host check input bounds independently.

Canvas-bounded input validation does not cover a system hotkey (Mission Control, Spotlight, the Lock Screen shortcut, and the rest `SystemHotkeyChord` recognizes): those post at the same HID tap real hardware uses and reach the whole login session, not only the streaming canvas, even from a canvas-mode session. While this machine is locked, a canvas-mode session posts nothing at all, system hotkeys included. This is not a gap the canvas bound failed to close -- a paired, armed device is already trusted with the owner's whole session, the same trust a saved password gives any other remote desktop, and a system hotkey reaches nothing a real keyboard at that session could not already reach.

### Why the pairing code cannot be guessed

The code is six digits, so a machine that reaches the port has a 1-in-10^6 shot per guess. Two caps bound it. A per-code budget allows 10 wrong guesses against the issued code itself, capping total exposure at 10-in-10^6 per ceremony no matter how many connections an attacker opens, and an eleventh attempt is refused even when correct. A per-connection cap allows 5 wrong guesses, so an attacker pays for a fresh handshake every five guesses instead of working through the per-code budget on one connection.

The comparison is constant-time, so a guess cannot be refined digit by digit from how long the rejection took. The code, and any prefix of it, is never logged. The only place it appears is the host's own pairing screen.

### How long a connection may stay open

The host closes a connection that has not become a session in time. Each deadline is measured from the moment the host accepted the connection. Nothing the other machine sends moves it.

- 15 seconds to send the first message of pairing or of a session.
- 60 seconds, for a machine that has identified itself, to ask for a host screen or a private desktop.
- 330 seconds to finish pairing or identify itself as a paired machine. That is a pairing code's 300-second life plus 30 seconds.

QUIC's own 30-second idle timeout bounds none of this, because any packet at all resets it. Without these deadlines a tailnet machine could hold connections open indefinitely by sending frames the host skips. A connection that has asked for a screen is past every deadline, including one still waiting for the person at the host to answer. If the host refuses that request and the connection has no session, the host closes it right after writing the refusal, so the viewer still receives it. A refusal on a connection that already has a session leaves it open. A connection that finished pairing is left for the viewer to close, which it does at once.

The host logs one line for each connection it closes this way. A machine that never identified itself is named by its address. One that did is named as it is everywhere else in the log.

### What pairing proves

What pairing proves is that whoever held the device at that moment could read the code shown at the host. It does not prove who holds the device later. A stolen or compromised paired device therefore has the same reach as its owner, exactly as with a saved password in any other remote desktop, and nothing in this document describes pairing as more than that. Sensorium asks for no further proof of a person at the viewer: no per-session challenge, no per-action confirmation, no PIN, no biometric.

### Typing at a locked host

A locked host screen unlocks through ordinary forwarded input, typed at the viewer (see [Host screen mode](host-screen-design.md)). Sensorium adds no guess budget of its own to that input. Anyone who can type at the viewer during a live host-screen session can type at the host's lock screen.

### Where the keys are kept

Each app keeps its key in a file under `~/Library/Application Support/Sensorium`, readable by its owner only. Any process running as that user can read it. The macOS keychain would instead show that process a dialog, which people are used to approving. This is the same posture as an ssh or gpg key on disk.

On Linux the viewer keeps the same files under `~/.local/share/sensorium`, or under `$XDG_DATA_HOME/sensorium` where that variable is set. Each file is owner-read-and-write only, inside a directory only its owner may enter. There is no keyring involved.

## What is not defended

- **A compromised viewer machine.** It holds the paired key.
- **Physical access to the host.** Out of scope.
- **Pairing attempts from the local network.** While **Allow connections from this network** is on, any machine on the host's subnet can connect and try a pairing code, as any tailnet machine already can. It still needs the code shown at the host. This is accepted.
- **Spending a shown pairing code from the local network.** The same machine can use up a shown code's 10-guess budget, which retires it before the intended viewer enters it. The person at the host then shows a new code. This denial of service is accepted. Leaving the setting off on shared networks avoids both.
- **Traffic analysis inside the tailnet.** WireGuard encrypts payloads. Volume and timing are visible to the tailnet coordination path.
- **Pre-boot (FileVault) access.** Not supported at all. FileVault's own unlock screen runs before the host's login window, and before any session can start.
- **The maintainer's own machine.** It holds the update key, the release certificate, and access to the release page. Whoever controls it can ship an update. [Self-update](self-update-design.md#4-trust) explains how each is kept.
- **The first download of each macOS app.** The app inside the disk image is signed with a self-signed certificate and not notarized. The disk image itself is not signed. `SHA256SUMS` beside it detects a damaged download, not a substituted one. Every later update is checked as above. The first install is not.
- **The Linux package's authenticity.** The Fedora RPM is unsigned. Only a SHA-256 checksum is published beside it, which detects a damaged download, not a substituted one. Anyone who can replace the file on the release page can replace the checksum with it.

## Privacy

No telemetry, analytics, crash reporting, or third-party SDK exists in this repository. Latency traces are local, opt-in, timing numbers only, no addresses, no screen contents.

# Privacy

What Sensorium sends over the wire, and what it stores.

## What leaves the host

Video of the session canvas. If clipboard sharing is on, the host's pasteboard contents too. The host never captures a physical display outside host screen mode. A request for any display but the one the session owns is refused.

After the host applies an event the viewer sent, it echoes back the tag the viewer put on it. Nothing else rides along.

Once a second, the host sends one reading per open canvas. It covers capture, encode, and send timing, plus frame rate and drop count.

## What leaves the viewer

Pointer, button, scroll, and key events, in canvas coordinates. If clipboard sharing is on, the viewer's pasteboard contents too. Each event can carry a counter the viewer uses to time its own round trip. The counter is local, not a timestamp or an identifier, and carries nothing typed or clicked.

Once a second, the viewer sends one reading per open display. It covers how long each stage of the picture took, how many frames decoded and reached the screen, and how much video arrived. Stage timings and rates only, no addresses, no screen contents.

If the person at the viewer chooses to unlock a locked host screen, the host's login password too, once, over the same authenticated, presence-verified connection. The host copies the buffers it derives from the password and zeroes each one once it has served its purpose. The one copy it does not control the lifetime of is the wire-decoded message itself, held until that message is released, since `Data`'s copy-on-write storage cannot be wiped any earlier. It is never written to disk and never logged.

## Where it goes

Straight to the paired host over the existing tailnet. There is no cloud service, account, relay, or analytics endpoint in this repository.

## Stored on disk

| Machine | Stored | Where |
|---|---|---|
| Both | One device key pair | `~/Library/Application Support/Sensorium/device-identity.json`, owner-only |
| Host | One TLS certificate and key | `~/Library/Application Support/Sensorium/host-tls-identity.json`, owner-only |
| Host | Paired machine public keys | Host process |
| Host | Which machines may reach the host screen | `~/Library/Application Support/Sensorium/host-screen-arming.json`, owner-only |
| Host | One line per host-screen session: the device, the display, and when it ran | `~/Library/Application Support/Sensorium/host-screen-sessions.log` |
| Host | One outcome token per lock-screen unlock attempt (never the password or its length) | The host's own stdout operator log only. Nothing about an unlock attempt is written to `host-screen-sessions.log` |
| Viewer | Saved host name, port, and pinned public key | `~/Library/Application Support/Sensorium/saved-host.json` |
| Viewer | Which presence credential this machine registered, and at what strength | `~/Library/Application Support/Sensorium/presence-credential.json`, owner-only |

No screen contents, keystrokes, or input history reach disk. Opt-in local latency traces hold stage timings only, no addresses, no screen contents, no input.

## Clipboard sharing

On by default. The viewer decides: turn it off from the viewer's View menu, live during a session. The host shares nothing on a new connection until the viewer has said it wants sharing on.

A pasteboard often holds a credential a password manager put there. Honoring the markers that flag one is best effort, not a guarantee. Turn sharing off before copying anything that must stay on one machine.

With it on, sharing carries text and images only, up to about 4 MiB. Anything larger is refused, not cut down. A refusal is shown in the session window, naming the reason and sizes only. Content is never logged or written to disk. Log lines carry only the kind, the byte count, and the outcome.

Content marked concealed, transient, auto-generated, or as a file reference is never sent. A pasteboard that cannot be read is refused, not sent. Only copies made after clipboard sharing turns on are sent, nothing already on the pasteboard.

It travels over the same authenticated, encrypted connection as everything else, only while a session is active.

No audio driver is installed and no audio is captured. There is no file transfer, shared folder, or printer redirection. Clipboard sharing itself carries text and images only, never files.

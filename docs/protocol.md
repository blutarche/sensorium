# Control protocol

This is the wire reference for Sensorium's control protocol, version 1. It is transport-independent. The same messages travel over the in-memory loopback the tests use and over the Network.framework connection.

## Framing

A control frame is a 4-byte big-endian payload length, followed by JSON.

```text
+--------+-----------------+
| len:4  | JSON payload    |
+--------+-----------------+
```

Frames larger than 64 KiB are rejected before decoding. The transport layer adds a one-byte tag so control and video share one connection (`SensoriumTransportPacketCodec`). Video payloads are capped separately. JSON carries the control channel only.

## Transport tags

Every wire frame is `[tag:1][length:4 big-endian][payload]`.

| Tag | Payload | Meaning |
|---|---|---|
| 0 | `SensoriumFrameCodec` JSON | Control message |
| 1 | `EncodedVideoFrameCodec` bytes | Video for surface 0. Implicit, no surfaceID on the wire |
| 2 | `[surfaceID:4 big-endian][EncodedVideoFrameCodec bytes]` | Video for an explicit surface |
| 3 | `ClipboardPacketCodec` bytes | One machine's pasteboard, offered to the other |
| other | opaque | `.unrecognized(tag:payload:)`, see Version policy below |

Tag 2's `surfaceID` must be `0` or `1`, matching the `{0, 1}` cap on the control messages below. Anything else fails decode with `malformedMessage`. A tag-2 payload too short to hold the 4-byte surfaceID prefix fails with `frameTooShort`. What follows that prefix is what tag 1 carries for the same frame.

The host only sends tag 2 to a client that has proven it understands surfaces, through the `canvasRequest`/`canvasReady` echo (see `surfaceID` below). A client that omits it keeps receiving tag 1. An unknown tag ends an older client's session.

## Clipboard

Tag 3 carries text or an image between the two machines' pasteboards, in both directions. Text and images only. Files and rich-content flavours are out of scope. `public.file-url` on the pasteboard is a reason to skip the copy.

```text
+---------+--------+-------------+--------------+--------+---------+
| magic:4 | kind:1 | formatLen:1 | payloadLen:4 | format | payload |
+---------+--------+-------------+--------------+--------+---------+
```

`magic` is `"CLIP"`. `kind` is 0 for UTF-8 text (`formatLen` 0) or 1 for an image, whose `format` is `png` or `tiff`. This is binary, not a JSON control frame, because an image is megabytes and the control frame is capped at 64 KiB.

**Size.** 1 MiB, enforced at encode, at decode, and again in `ClipboardSyncEngine`. Over the limit, the clipboard is refused with a reason and the session continues.

**No loop.** Both machines poll their own pasteboard, since macOS has no pasteboard-change notification: `changeCount` is polled every 200 ms. `ClipboardSyncEngine` tracks every `changeCount` it has dealt with and acts only on one that differs. `apply()` records the change count its own write produced in the same call, so that write is never read back as a new local copy.

**Gating.** The host applies a peer's clipboard only for a connection that is both authenticated and holds an active canvas (`HostSessionController.isSessionAuthenticatedAndActive`): not during pairing, not mid-handshake, not after `goodbye`. On the client, the clipboard session is built after `connect()` returns a signed canvas.

**Scope.** One pasteboard per machine, however many canvases a session opened, so tag 3 carries no `surfaceID`. Off by default on both ends. A peer with it off neither polls nor applies, and skips any tag-3 frame that reaches it. See `docs/privacy.md`.

## Messages

| Message | Direction | Purpose |
|---|---|---|
| `pairIntent(deviceName)` | client → host | Sent the moment the pairing screen appears, before a code exists. Unauthenticated, no reply |
| `pairRequest(deviceName, publicKey, code, signature)` | client → host | One-time ceremony. `signature` proves possession of `publicKey` and is required: a request without one is refused as malformed by the decoder |
| `pairApproved(hostPublicKey, tlsCertificateHash, signature)` | host → client | Key to pin, plus the TLS certificate hash for pinned reconnects |
| `pairRejected(reason)` | host → client | `invalid-code`, `code-expired`, `code-already-consumed`, `code-attempts-exhausted`, `no-active-code`, `invalid-request` |
| `hello(protocolVersion, deviceName)` | client → host | Unauthenticated. Refused when authentication is required |
| `authenticatedHello(protocolVersion, deviceName, publicKey, hostCertificateHash, signature)` | client → host | Proves the client device key, bound to the host it is sent to. `hostCertificateHash` is the SHA-256 of that host's TLS certificate, the one the viewer pinned; the host refuses a hello naming any other, so a host cannot replay a hello it received to another host |
| `canvasRequest(logicalWidth, logicalHeight, scale, surfaceID)` | client → host | Only the 1920×1200 scale-2 preset is accepted |
| `canvasReady(displayID, logicalWidth, logicalHeight, hostSignature, surfaceID, hostName)` | host → client | Canvas exists. Signature proves the host. `hostName` is the host's own machine name, or absent when unconfigured |
| `canvasRefused(reason, surfaceID)` | host → client | The other answer to a `canvasRequest`: `canvas-creation-in-progress`, `canvas-unavailable` |
| `input(event, surfaceID, sequence)` | client → host | Pointer, button, scroll, key, release-all, or capture-mode change. `sequence` is the client's own monotonic tag for round-trip measurement. Absent means untagged |
| `inputApplied(sequence)` | host → client | Echoes `sequence` once the named event was actually injected. Never sent for a refused or suppressed event |
| `viewerDrawableSize(pixelWidth, pixelHeight, surfaceID, maximumScale)` | client → host | The viewer's real backing-pixel size. Sets the streamed resolution, optionally capped by the user |
| `viewerFocus(surfaceID, hasViewerFocus)` | client → host | Which canvas the user is looking at, or that no canvas is. Sets scheduling preference |
| `streamScalePreference(preference, surfaceID)` | client → host | A person's explicit stream-scale choice, or a return to automatic |
| `displayCount(count)` | client → host | The viewer's live choice of `1` or `2` session displays |
| `clipboardSharing(enabled)` | client → host | Live per-session on/off from the viewer's View menu. No reply |
| `timeSyncRequest(clientTimeNanoseconds)` | client → host | Relates the two monotonic clocks. Requires authentication |
| `timeSyncReply(clientTimeNanoseconds, hostTimeNanoseconds)` | host → client | Echoes the request timestamp and stamps the host clock |
| `telemetry(surfaces)` | host → client | Per-surface capture/encode/send latency, fps, and drop counts |
| `viewerTelemetry(surfaceID, ...)` | client → host | Per-surface receive/decode/present latency, fps, and bitrate |
| `goodbye(reason)` | client → host | Releases the canvas and any held input. `stopped-by-host` marks an ending the host's own Stop control chose. The viewer never redials it |

`code-attempts-exhausted` means the issued code spent its ten-failure budget and is retired: further requests with it are refused even when correct, and pairing has to start again. The budget is counted against the code, not the connection, so reconnecting does not reset it. See `docs/threat-model.md`. The host-screen messages are their own family, see Host screen below.

## surfaceID

`surfaceID: UInt32?` routes a canvas-scoped message to one of a hard cap of **two** session-owned virtual canvases, keyed `0` and `1`. It appears on `canvasRequest`, `canvasReady`, `input`, `viewerDrawableSize`, and `viewerFocus`. `nil` means canvas 0, so a peer that never sends or reads it keeps single-canvas behaviour, without bumping `protocolVersion`.

A `surfaceID` outside `{0, 1}` is rejected the same way bad canvas geometry is: `invalidCanvasRequest`, `invalidInput`, `invalidViewerDrawableSize`, `invalidViewerFocus` on the respective message. An in-range `surfaceID` whose canvas this connection never created is refused with `inputSessionUnavailable` for `input`, `viewerDrawableSize`, and `viewerFocus`, not redirected to the other canvas.

A host-screen session streams one display and owns no canvas. It reports and is steered under surface 0. A `viewerDrawableSize` or `viewerFocus` naming surface 1 on such a session is refused with `inputSessionUnavailable`.

The two canvases are created strictly one after the other on a single-flight gate. `canvasReady`'s `surfaceID` sits inside the signed transcript (see below), not appended after it. The client always requests `surfaceID: 0` on `canvasRequest` and checks the echo on `canvasReady` only as a capability flag: `0` means the host understands the field, an absent echo means an older host, anything else fails `connect()`.

## Refused canvases

A `canvasRequest` has two answers, never a third and never silence. `canvasReady` is the canvas. `canvasRefused` is an explicit refusal carrying a reason: `canvas-creation-in-progress` (another creation still in flight, the client does not retry) or `canvas-unavailable` (the host was refused under every identity it has, so the connection ends instead of redialling). A request producing no reply leaves the client waiting out `SessionTimeouts.remoteDefault.canvasCreation` (15 s) before dropping the whole session.

| Refused surface | Client behaviour |
|---|---|
| 1 (the second canvas) | Drops to single-window. The primary canvas, transport, and session are untouched. |
| 0 (the primary canvas) | Fails `connect()` with the host's own reason. There is no session without surface 0. |

A refusal naming a surface the client did not just ask about is a protocol violation and fails `connect()`. `canvasRefused` is its own message type, not a flag on `canvasReady`, so an old peer decodes it as `.unrecognized`. `protocolVersion` is not bumped for it, and it is **unsigned**, unlike `canvasReady`.

## Clock synchronisation

Host and client monotonic clocks are since-boot counters with no shared origin. The client sends `timeSyncRequest` carrying its own clock, the host replies with that value echoed plus its own clock, and the client computes:

```text
roundTrip = clientReceived - clientSent
offset    = hostReplied - (clientSent + roundTrip / 2)
```

Only the sample with the **lowest** round trip is retained. A reply is accepted only if its echoed timestamp matches an outstanding request, and each request answers once. `timeSyncRequest` also requires authentication, like `input`. Until an offset exists, the client reports **no** latency.

## Signed transcripts

Both directions sign a byte string with explicit separators, never a concatenation that could be shifted between fields.

```text
sensorium-authenticated-hello-v2|<version>\0<deviceName>\0<publicKey base64>\0<hostCertificateHash base64|"none">
sensorium-canvas-ready-v1|<displayID>\0<width>\0<height>\0<clientPublicKey base64>\0<surfaceID|"none">
sensorium-pair-approved-v1|<deviceName>\0<clientPublicKey base64>\0<tlsCertificateHash base64|"none">
sensorium-pair-request-v2|<deviceName>\0<clientPublicKey base64>\0<code>
```

Both the hello and the pairing-request transcripts are at `v2`: their field lists changed after `v1` shipped, and moving the prefix with them means a signature made over either version can never be read as the other. The canvas transcript names the client key, so a signature captured for one client cannot be replayed to another. The hello transcript names the host's own certificate, so a hello signed for one host is refused by every other. An absent surfaceID, an absent certificate hash, and present ones can never collide on the same transcript bytes.

## Input events

`pointerMoved`, `pointerMovedRelative` (raw unaccelerated deltas, sent only while the client has captured the pointer), `pointerButton`, `scrolled`, `key`, `releaseAllInput`, `pointerCaptureChanged(isCaptured)`. Coordinates are canvas logical points with the origin at the **top left**. AppKit's opposite convention is flipped once, on the client. `key.keyCode` is the macOS virtual keycode of the physical key, and a viewer on another platform translates its own scancodes into that space before sending. Validated on both sides: coordinates must be finite and inside 1920×1200, scroll deltas finite and within ±10000, and modifier bits outside the four forwarded modifiers are rejected.

## Streamed resolution

The session canvas is 1920×1200 logical HiDPI, 3840×2400 real pixels. What is streamed is a fraction of that, the **stream scale**, derived by the client from its own drawable:

```text
scale = min(drawablePixelWidth / 1920, drawablePixelHeight / 1200)
        clamped to 1.0...2.0, rounded to the nearest 0.25
```

Both axes take the same factor, so the aspect ratio survives any window shape and the viewer letterboxes the remainder. Encoded dimensions are the canvas logical size multiplied by the scale.

`viewerDrawableSize` is sent only when the derived scale changes from what the host is believed to be streaming, starting from `1.0`. Gated like `input`: authentication plus a live surface, dimensions finite, positive, and at most 16384. A refused value never drops the session. `maximumScale` is the user's own optional cap, folded into the same clamp as the ceiling the host learns by measurement (`EncodeSustainabilityPolicy`, whichever is lower), validated the same way, finite and inside `1.0...2.0`.

A host-screen session honours it too. The live surface is then the host screen, not a canvas, and the scale is a fraction of that display's own logical size. Two further ceilings bound it. The first is the display's backing scale, because there is no further pixel to encode past it. The second is the largest frame the host's hardware H.264 encoder accepts. The lower of the two wins, and a person's own fixed choice of scale is held at the same two.

The host debounces: only a settled scale rebuilds the capture and encode path, replacing the `VTCompressionSession` and its H.264 SPS/PPS. The client learns new parameter sets from the `codecConfiguration` a keyframe carries. The host refuses any delta of a new generation before its keyframe.

## Viewer focus

`viewerFocus(surfaceID, hasViewerFocus)` tells the host which canvas the user is looking at, so it can prefer that canvas when both contend for the one hardware encoder and the one byte channel.

| `hasViewerFocus` | `surfaceID` | Meaning |
|---|---|---|
| `true` | `0` or `nil` | The user is working in canvas 0's window |
| `true` | `1` | The user is working in canvas 1's window |
| `false` | `nil` | The user is in a local app. No canvas is focused |

"No focus at all" is a separate boolean, not an absent `surfaceID`, since an absent `surfaceID` already means canvas 0 everywhere else on this wire. The host treats "never reported" and "no focus" alike, as fair share. The client sends it only on genuine focus transitions, and a reconnect resets that memory. Gated like `input`: authentication plus a live surface, which is a canvas this connection created or the host screen it is streaming. A refused report never drops the session, and `protocolVersion` is not bumped for it.

The focused canvas is preferred at both scheduling points (`SharedEncodeAdmissionGate`, `SurfaceVideoSendQueues`), bounded, not strict: the preferred surface takes at most three turns in a row, so the unfocused canvas is guaranteed one in every four. Keyframes are not reordered by focus.

## Telemetry

`telemetry(surfaces)` is a JSON control message, host → client, carrying one `SurfaceTelemetrySample` per surface that has captured or encoded at least one frame this session.

```text
surfaceID: UInt32
capture / encode / send: { p50Nanoseconds, p95Nanoseconds }?
framesPerSecond: Double?
encoderInputDropped / globalAdmissionDropped / sendQueueDropped: Int
appliedStreamScale: Double?
sustainableScaleCeiling: Double?
clampedFromUserChoice: Double?
hostRequestedStreamScale: Double?
appliedFramesPerSecond: Int?
qualityScale: Double?
fidelityLimitReason: String?
```

A stage with no samples yet is absent, never a fabricated zero. `framesPerSecond` is absent on a session's first tick, and a surface with nothing to report is omitted from the array entirely.

| Field | Meaning |
|---|---|
| `appliedStreamScale` | What the surface is actually encoded at |
| `sustainableScaleCeiling` | The highest scale this session has found it can sustain |
| `clampedFromUserChoice` | The scale a person explicitly chose (`streamScalePreference`), when the learned ceiling held `appliedStreamScale` below it |
| `hostRequestedStreamScale` | The scale the host itself derived from the client's last reported drawable size, before any measured ceiling |
| `appliedFramesPerSecond` | The frame rate the host is aiming at |
| `qualityScale` | The multiplier on the encoder's bitrate. `1.0` when nothing has been given up |
| `fidelityLimitReason` | One of `encoder`, `link`, `viewer` |

All of these are absent from a host that predates them, read by a client as "unknown" instead of full fidelity or `1.0`.

This is a JSON control message, not a new transport tag, on the same forward-compatibility path as `viewerFocus`. Sent once per `TelemetryPolicy.sendIntervalSeconds` (1 second) while the session is authenticated and streaming, which is either a live session canvas or a live host screen. The same tick is what moves the fidelity controller, so the numbers a viewer is shown are the ones that second's decision was made from. This is a narrower right than writing the host pasteboard, which still needs a canvas this session opened. No separate opt-in flag.

**How the host picks those numbers.** Resolution is the first thing it spends and the only one it names directly. Encode cost is per pixel. The median encode measured at the scale in force predicts the cost of every other scale by the square of the ratio between them. That prediction times the rate frames actually arrive at is the share of a second the encoder would spend. The host streams the largest scale whose share stays at or under 0.8 at 60 frames a second. A pressured tick moves it there at once rather than a step at a time. Two unpressured ticks move it back the same way.

The link is measured the same way. Bits per second go with pixels and with the quality multiplier, so what the encoder produced this tick predicts what every other scale would cost the link. When the viewer reports it is receiving well under what was sent, the host takes 0.8 of what did arrive as the budget, and streams the largest scale whose predicted bits fit it. The budget rises by a tenth on every tick with nothing wrong in it, so a link that has recovered is offered the resolution back a step at a time. A surface back at the scale the viewer asked for has no budget at all until the link is short again.

The point is motion. A screen with moving parts is unwatchable below 30 frames a second, so the host gives up size to keep the rate. A screen nobody is changing costs the encoder nothing and asks almost nothing of the link, so it returns to the scale the viewer asked for.

Frame rate and quality only move once the scale is already at its floor and a stage is still behind, which is also what happens when no scale at all fits the budget. The encoder and the viewer get fewer frames. The link gets smaller ones, which costs no motion at all. The frame rate stops at 30 until quality has been spent. Nothing visible changes more than once every two seconds.

**Client display.** `SessionTelemetryTracker` answers `unavailable` before a surface's first sample, `fresh` within `TelemetryPolicy.staleAfterSeconds` (three send intervals) of the last one, and `stale` once that window passes. A reading is flagged worth attention on any drop since the last tick, a stale reading, or an end-to-end p50 past `endToEndP50NanosecondsThreshold` (33 ms). Display only.

## Viewer telemetry

Client to host: `viewerTelemetry` carries one `ViewerTelemetrySample` for one surface.

```text
surfaceID: UInt32
endToEnd / receive / decode: { p50Nanoseconds, p95Nanoseconds }?
presentedFramesPerSecond: Double?
decodedFramesPerSecond: Double?
receivedBitsPerSecond: Double?
```

This exists because the host measures only its own stages: everything after a frame leaves the host is otherwise invisible to it. `receivedBitsPerSecond` is counted on the viewer, since what left the host is not what arrived.

A stage with no samples yet is absent, never a zero. Sent once per `TelemetryPolicy.sendIntervalSeconds`, from the viewer's own display refresh, for each canvas that exists. A send that fails is not reported as session loss. Same forward-compatibility path as `telemetry`, and the same authentication gate as `viewerFocus`. `ViewerTelemetryStore` keeps the latest reading per surface and returns nothing once older than `TelemetryPolicy.staleAfterSeconds`.

A reading naming a surface the session cannot have is dropped. A rate that is not finite, or a rate or duration below zero, drops the whole sample instead of clamping it to zero. Zero itself is kept.

Nothing in this message names an address, a window, a file, or anything the person at the viewer did: stage timings and rates only, the same rule `docs/privacy.md` states for traces.

## Host screen

The host-screen path offers one of the host's own displays instead of a session canvas, and uses its own message family.

| Message | Direction | Purpose |
|---|---|---|
| `hostScreenList(displays)` | host → client | Sent instead of `canvasReady` on this path. Each entry is an opaque per-connection token, a label, logical size, backing scale, and a stable `displayIdentity` |
| `hostScreenRequest(token, resumeTicket)` | client → host | Names one offered display by its token. `resumeTicket`, when present, asks the host to resume a session already granted without a fresh host-presence check (see `docs/host-screen-design.md` §6.4) |
| `hostScreenReady(geometry, resumeTicket)` | host → client | The display's logical size and backing scale. `resumeTicket` is minted fresh for this session and presented back on a silent reconnect |
| `hostScreenRefused(reason)` | host → client | `host-screen-not-allowed`, `canvas-session-active`, `host-screen-session-active`, `host-screen-presence-declined`, `host-screen-presence-unanswered`, `host-screen-presence-check-required`, `host-screen-resume-refused` |
| `hostScreenModeList(modes, currentModeID)` | host → client | Every mode macOS already offers for this display, and which one it is on now. Sent right after `hostScreenReady` and again after every applied change |
| `hostScreenModeRequest(modeID)` | client → host | One `modeID` from that list. Never a width, height, or scale of the viewer's own composing |
| `hostScreenModeApplied(geometry, currentModeID)` | host → client | The mode changed. `geometry` is the new logical size and backing scale |
| `hostScreenModeRefused(reason)` | host → client | `host-screen-mode-not-live`, `host-screen-mode-unknown`, `host-screen-mode-failed`. The session and display are untouched |
| `hostScreenUnlockRequest(password)` | client → host | The host's own login password, as raw UTF-8 bytes, to type into its locked login window |
| `hostScreenUnlockResult(outcome)` | host → client | What the attempt did, one of `HostScreenUnlockOutcome`'s stable tokens, below |
| `hostScreenLockState(locked)` | host → client | Whether the host's screen is locked. Sent unprompted right after `hostScreenReady` and again after every unlock attempt |

A `hostScreenRequest` is admitted once the requesting machine's key is armed for host screen and the token names a display this session's `hostScreenList` actually offered. See `docs/host-screen-design.md` §6.1 for the full admission sequence.

### Lock-screen unlock outcomes

`hostScreenUnlockResult` carries one of these stable tokens, the same discipline `hostScreenRefused`'s reason list follows:

| Token | Meaning |
|---|---|
| `unlocked` | The password was accepted. The screen is no longer locked |
| `wrong-password` | The login window refused the password. Still locked, and the viewer may try again |
| `screen-sharing-unavailable` | The host could not reach its own built-in screen-sharing service on loopback, or that service does not offer the security type this unlock needs. Nothing was typed |
| `not-locked` | The screen was already unlocked when the request arrived |
| `not-authorized` | The connection is not an authenticated, active host-screen session |
| `too-many-attempts` | This machine is at its wrong-guess cap. Retrying on this connection or a fresh one cannot help; only a correct password, a host restart, or the person at the host re-arming this machine clears it |
| `password-too-long` | The password is longer than the unlock method's credential field can hold. Type it at the login window instead |
| `failed` | The password was accepted but the screen is still locked, or some other step failed. Carries a `reason` string for the operator log only, never shown as more than "try again" |

## Ordering rules

- Control messages travel on a reliable ordered stream.
- A surface's `canvasReady` is written before that surface's capture starts, and its workspace window is placed before the reply: a refused placement is answered as a failed canvas request, not as a canvas the client has already been promised. The client still has to tolerate video arriving mid-handshake, held by `DeferredPacketQueue`.
- Pointer motion is latest-wins, collapsing to the newest point queued behind an in-flight send. Buttons, scrolls, and keys are never coalesced.
- Video frames are decoded in the order they arrived. A viewer that fell behind catches up rather than skipping ahead, because each frame is a difference from the one before it. Only a decode queue that reaches its bound gives a group up, and the next key frame recovers from that.
- The viewer draws on its screen's own refresh. Each decoded frame is held a short time past the capture time the host stamped it with, so frames that arrive together are drawn one refresh apart instead of one of them being thrown away. The hold is measured from how unevenly frames arrive and never exceeds 50 milliseconds. A frame that arrives later than that is drawn at once.
- `hostScreenUnlockRequest` is answered only for an already-authenticated, already-streaming host-screen session; see `docs/host-screen-design.md` §9.

## Version policy

`protocolVersion` is checked for an exact match, never bumped for a compatible addition. Once a session's control loop is running, an unrecognized `type` string is tolerated, not fatal: `SensoriumFrameCodec.decode` returns `.unrecognized(type:)` instead of throwing, and both host (`HostSessionController.handle`) and client (`ClientSessionRunner.receiveLoop`) skip it and keep going. A new message type never ends an older peer's session. The same tolerance exists at the transport tag, `.unrecognized(tag:payload:)`. `.unrecognized` is decode-only: `SensoriumFrameCodec.encode` throws if asked to encode one.

**Pairing stays strict.** `ClientSessionController.pair`'s response switch rejects anything but `pairApproved`/`pairRejected`, including `.unrecognized`, with `ClientSessionError.unexpectedMessage`.

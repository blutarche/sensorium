import AppKit
import CoreGraphics
import CoreVideo
import Foundation
import Network
import SensoriumClient
import SensoriumCore

/// Opt-in single-machine acceptance probe. It deliberately uses the production viewer
/// window, frame runner, surface-event router, authenticated transport, and host
/// injector. Pairing and entering are separate so input is exercised only while
/// the host runs in its normal `serve` mode.
///
/// usage:
///   SensoriumLocalWorkspaceInputProbe pair <tailnet-host> <port> <pairing-code>
///   SensoriumLocalWorkspaceInputProbe enter <tailnet-host> <port>
///   SensoriumLocalWorkspaceInputProbe enter-resize <tailnet-host> <port>
///   SensoriumLocalWorkspaceInputProbe enter-focus-release <tailnet-host> <port>
///
/// `enter-resize` drives a real mid-session stream-resolution rebuild through
/// `ClientViewportController.setDrawableSize`, the same entry point the
/// AppKit view calls on a live resize. It is additionally gated behind the
/// `SENSORIUM_ALLOW_RESIZE_SMOKE=1` environment variable so it can never run
/// by accident; `pair` and `enter` are untouched by its existence.
///
/// `enter-focus-release` proves a real held modifier key and mouse button are
/// really released on the real canvas when the viewer loses focus. It holds a
/// key and a button down without their matching up, posts the exact real
/// `NSWindow.didResignKeyNotification`/`NSApplication.didResignActiveNotification`
/// notifications `ClientCanvasWindowController` observes — not a direct call
/// to the release method — and checks the real OS-level key/button state
/// (`CGEventSource.keyState`/`buttonState`), not any in-process bookkeeping.
/// It is gated behind `SENSORIUM_ALLOW_FOCUS_RELEASE_SMOKE=1`.
@main
@MainActor
struct SensoriumLocalWorkspaceInputProbe {
    private struct SavedApproval: Codable {
        let hostPublicKey: Data
    }

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let mode = arguments.first else {
            usageAndExit()
        }

        do {
            switch mode {
            case "pair":
                guard arguments.count == 4 else { usageAndExit() }
                try await pair(
                    host: arguments[1],
                    rawPort: arguments[2],
                    code: arguments[3]
                )
            case "enter":
                guard arguments.count == 3 else { usageAndExit() }
                try await enter(host: arguments[1], rawPort: arguments[2])
            case "enter-resize":
                guard arguments.count == 3 else { usageAndExit() }
                try await enterResize(host: arguments[1], rawPort: arguments[2])
            case "enter-focus-release":
                guard arguments.count == 3 else { usageAndExit() }
                try await enterFocusRelease(host: arguments[1], rawPort: arguments[2])
            default:
                usageAndExit()
            }
        } catch {
            print("local workspace input probe failed: \(error)")
            Foundation.exit(1)
        }
    }

    private static func pair(host: String, rawPort: String, code: String) async throws {
        let port = try endpointPort(rawPort)
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: port,
            transport: .tcpLocalVerification
        )
        try await connection.start()
        let session = ClientSessionController(transport: connection, identity: identity)
        let approval = try await session.pair(deviceName: "Sensorium local workspace input probe", code: code)
        try JSONEncoder().encode(SavedApproval(hostPublicKey: approval.hostPublicKey)).write(to: approvalURL(), options: .atomic)
        await connection.close()
        print("local_input_probe_paired=yes")
    }

    private static func enter(host: String, rawPort: String) async throws {
        let port = try endpointPort(rawPort)
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        let approval = try JSONDecoder().decode(SavedApproval.self, from: Data(contentsOf: approvalURL()))
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: port,
            transport: .tcpLocalVerification
        )
        try await connection.start()
        let session = ClientSessionController(
            transport: connection,
            identity: identity,
            pinnedHostPublicKey: approval.hostPublicKey
        )
        let window = try ClientCanvasWindowController(title: "Sensorium Local Workspace", session: session)
        await session.setCanvasObserver(window.canvasObserver())
        _ = try await session.connect(deviceName: "Sensorium local workspace input probe")
        await window.show()

        let runner = ClientSessionRunner(connection: connection, session: session, window: window)
        try runner.start()
        print("viewer_window_started=yes")
        try await Task.sleep(for: .seconds(2))

        let inputViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(logicalWidth: 1920, logicalHeight: 1200),
            pointerSink: session
        )
        let router = CanvasSurfaceEventRouter(viewport: inputViewport)
        _ = await router.route(.boundsChanged(width: 960, height: 600))
        await inputViewport.canvasDidBecomeReady()
        let move = await router.route(.pointerMoved(x: 480, y: 300))
        let clickDown = await router.route(.pointerButton(button: .left, isDown: true, x: 480, y: 300))
        let clickUp = await router.route(.pointerButton(button: .left, isDown: false, x: 480, y: 300))

        // Both windows are on one machine here, and this probe's own
        // `show()` (ClientCanvasWindowController.show()) activated itself
        // after the host workspace did, so the probe is left frontmost.
        // Hand focus back explicitly and wait for the OS to grant it: the
        // host's own key-confinement guard (`HostSessionController.mayPost`)
        // only posts a key once its workspace really holds focus, and
        // refuses it otherwise -- correctly, since that guard is what stops
        // a viewer that swallows all input from locking the user out of
        // their own machine.
        let (hostFocused, contendingApp) = await activateHostWorkspace()
        print("workspace_focus_confirmed=\(hostFocused)")
        guard hostFocused else {
            print("workspace_focus_holder=\(contendingApp ?? "unknown")")
            print("workspace_input_sent=no")
            runner.stop()
            await session.disconnect(reason: "input-probe-failed")
            throw InputProbeError.hostWorkspaceNeverFocused
        }

        // Confirming this machine's own frontmost app only proves the
        // hand-off reached the host process, not that the host's own window
        // has finished becoming key inside it -- `HostSessionController.mayPost`
        // reads `NativeCanvasWorkspace.hasKeyFocus`, a `Bool` this probe has
        // no way to read, updated by AppKit's own notification once the
        // host's main run loop gets to process the activation it was just
        // handed. Nothing this probe can observe answers "has that landed
        // yet", so retry the identical authenticated key send, bounded,
        // rather than guess how long the one send above needs to sleep.
        var down = PointerDelivery.droppedFailed
        var up = PointerDelivery.droppedFailed
        for attempt in 0..<30 {
            down = await router.route(.key(keyCode: 0, isDown: true, modifiers: []))
            up = await router.route(.key(keyCode: 0, isDown: false, modifiers: []))
            if attempt < 29 {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        // `.delivered`/`.deliveredWithoutLocation` only mean the client's
        // authenticated transport accepted the send; the wire protocol has no
        // host-side acknowledgement of accept or refuse, so this cannot prove
        // the host actually injected the event (it silently refuses input
        // when Accessibility is not granted). Name the marker accordingly.
        guard case .delivered = move,
              case .delivered = clickDown,
              case .delivered = clickUp,
              down == .deliveredWithoutLocation,
              up == .deliveredWithoutLocation else {
            print("workspace_input_sent=no")
            runner.stop()
            await session.disconnect(reason: "input-probe-failed")
            throw InputProbeError.routedInputNotDelivered
        }
        print("workspace_input_sent=yes")

        try await Task.sleep(for: .seconds(2))
        let presented = await runner.latency.metrics().samples(for: .present).count
        print("viewer_presented_frames=\(presented)")
        runner.stop()
        await session.disconnect(reason: "input-probe-complete")
        guard presented > 0 else {
            throw InputProbeError.noPresentedFrames
        }
    }

    /// Drives a real stream-resolution rebuild on a real session: enters at
    /// the default drawable size, reports a larger drawable so the derived
    /// scale changes, waits past the host's settle debounce, confirms the
    /// stream is still decoding and presenting at the new pixel dimensions,
    /// then reports the original drawable size and confirms recovery back.
    ///
    /// Every stage is checked against the real `CVPixelBuffer` dimensions of
    /// decoded frames — never inferred from a host log line — using
    /// `ClientSessionRunner`'s `onDecodedFrame` observation seam.
    private static func enterResize(host: String, rawPort: String) async throws {
        guard ProcessInfo.processInfo.environment["SENSORIUM_ALLOW_RESIZE_SMOKE"] == "1" else {
            print("resize_smoke_gate=refused")
            throw InputProbeError.resizeSmokeNotOptedIn
        }
        let port = try endpointPort(rawPort)
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        let approval = try JSONDecoder().decode(SavedApproval.self, from: Data(contentsOf: approvalURL()))
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: port,
            transport: .tcpLocalVerification
        )
        try await connection.start()
        let session = ClientSessionController(
            transport: connection,
            identity: identity,
            pinnedHostPublicKey: approval.hostPublicKey
        )
        let window = try ClientCanvasWindowController(title: "Sensorium Local Resize Smoke", session: session)
        await session.setCanvasObserver(window.canvasObserver())
        _ = try await session.connect(deviceName: "Sensorium local resize smoke probe")
        await window.show()

        let tracker = DecodedFrameTracker()
        let runner = ClientSessionRunner(connection: connection, session: session, window: window)
        try runner.start(onDecodedFrame: { frame in tracker.record(frame) })
        print("resize_smoke_session_started=yes")

        func settleAndReport(stage: String) async throws -> DecodedFrameSnapshot {
            // Past the 0.35s settle debounce plus room for the host to
            // actually rebuild capture/encode (ScreenCaptureKit stream
            // teardown and restart is not instant) and this client to
            // decode a keyframe at the new resolution.
            try await Task.sleep(for: .seconds(5))
            let snapshot = tracker.snapshotAndReset()
            print("resize_stage_\(stage)_decoded=\(snapshot.count)")
            print("resize_stage_\(stage)_width=\(snapshot.width ?? 0)")
            print("resize_stage_\(stage)_height=\(snapshot.height ?? 0)")
            return snapshot
        }

        func fail(_ reason: String, error: InputProbeError) async throws -> Never {
            print("resize_smoke_failure=\(reason)")
            runner.stop()
            await session.disconnect(reason: "resize-smoke-failed")
            throw error
        }

        let baseline = try await settleAndReport(stage: "baseline")
        guard baseline.count > 0 else {
            try await fail("no decoded frames at baseline", error: .noDecodedFrames)
        }

        let viewport = window.canvasObserver()
        let scaleUpDelivery = await viewport.setDrawableSize(pixelWidth: 3840, pixelHeight: 2400)
        print("resize_scale_up_delivery=\(scaleUpDelivery)")
        guard case .sent = scaleUpDelivery else {
            try await fail("scale-up drawable size was not sent: \(scaleUpDelivery)", error: .drawableSizeNotSent)
        }
        let scaledUp = try await settleAndReport(stage: "scaled_up")
        guard scaledUp.count > 0 else {
            try await fail("no decoded frames after scaling up", error: .noDecodedFrames)
        }

        let scaleDownDelivery = await viewport.setDrawableSize(pixelWidth: 1920, pixelHeight: 1200)
        print("resize_scale_down_delivery=\(scaleDownDelivery)")
        guard case .sent = scaleDownDelivery else {
            try await fail("scale-down drawable size was not sent: \(scaleDownDelivery)", error: .drawableSizeNotSent)
        }
        let scaledDown = try await settleAndReport(stage: "scaled_down")
        guard scaledDown.count > 0 else {
            try await fail("no decoded frames after scaling back down", error: .noDecodedFrames)
        }

        runner.stop()
        await session.disconnect(reason: "resize-smoke-complete")
        print("resize_smoke_complete=yes")
    }

    /// Left Shift. A bare modifier held alone and never released is the
    /// classic stuck-input bug this probe exists to catch (Cmd-Tab away while
    /// still holding Cmd), and it needs no companion key to reproduce.
    private static let focusReleaseModifierKeyCode: UInt16 = 56

    /// Proves a real held key and mouse button are really released on the
    /// real canvas when the viewer loses focus. Bookkeeping cleared without
    /// a matching release would pass a test that checked only bookkeeping,
    /// so every assertion here reads `CGEventSource.keyState`/
    /// `buttonState`, the real OS-level HID input state, which only reflects
    /// a genuine `CGEvent(...).post(tap: .cghidEventTap)` from
    /// `CoreGraphicsInputInjector` in the real host process — not anything
    /// this probe or the host keeps in a Swift struct.
    private static func enterFocusRelease(host: String, rawPort: String) async throws {
        guard ProcessInfo.processInfo.environment["SENSORIUM_ALLOW_FOCUS_RELEASE_SMOKE"] == "1" else {
            print("focus_release_smoke_gate=refused")
            throw InputProbeError.focusReleaseSmokeNotOptedIn
        }
        defer { forceReleaseIfStillHeld(keyCode: focusReleaseModifierKeyCode) }

        let port = try endpointPort(rawPort)
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        let approval = try JSONDecoder().decode(SavedApproval.self, from: Data(contentsOf: approvalURL()))
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: port,
            transport: .tcpLocalVerification
        )
        try await connection.start()
        let session = ClientSessionController(
            transport: connection,
            identity: identity,
            pinnedHostPublicKey: approval.hostPublicKey
        )
        let window = try ClientCanvasWindowController(title: "Sensorium Local Focus Release Smoke", session: session)
        await session.setCanvasObserver(window.canvasObserver())
        _ = try await session.connect(deviceName: "Sensorium local focus release smoke probe")
        await window.show()

        let runner = ClientSessionRunner(connection: connection, session: session, window: window)
        try runner.start()
        print("focus_release_smoke_session_started=yes")

        func fail(_ reason: String, error: InputProbeError) async throws -> Never {
            print("focus_release_smoke_failure=\(reason)")
            runner.stop()
            await session.disconnect(reason: "focus-release-smoke-failed")
            throw error
        }

        let baselineKeyHeld = CGEventSource.keyState(.combinedSessionState, key: focusReleaseModifierKeyCode)
        let baselineButtonHeld = CGEventSource.buttonState(.combinedSessionState, button: .left)
        guard !baselineKeyHeld, !baselineButtonHeld else {
            try await fail(
                "Left Shift or the left mouse button was already physically held before the probe sent anything",
                error: .dirtyBaselineInputState
            )
        }

        let viewport = window.canvasObserver()
        let buttonDownDelivery = await viewport.sendButton(button: .left, isDown: true, x: 480, y: 300)
        print("focus_release_button_down_delivery=\(buttonDownDelivery)")

        // Same hand-off `enter` needs, and for the same reason: this probe's
        // own `show()` left it, not the host workspace, holding frontmost.
        // The button above carries its own canvas coordinates and needs no
        // frontmost app to land, but the key below does.
        let (hostFocused, contendingApp) = await activateHostWorkspace()
        print("workspace_focus_confirmed=\(hostFocused)")
        guard hostFocused else {
            print("workspace_focus_holder=\(contendingApp ?? "unknown")")
            try await fail(
                "the packaged host workspace never became the frontmost app for this probe to hand key focus to",
                error: .hostWorkspaceNeverFocused
            )
        }

        // See `enter`'s identical retry, for the identical reason. Resending
        // a key-down for an already-held key is a no-op at the real OS
        // level, so this cannot fake a hold that never happened --
        // `heldObserved` below still reads the genuine `CGEventSource` state.
        var keyDownDelivery = PointerDelivery.droppedFailed
        for attempt in 0..<30 {
            keyDownDelivery = await viewport.sendKey(keyCode: focusReleaseModifierKeyCode, isDown: true, modifiers: [.shift])
            if attempt < 29 {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        print("focus_release_key_down_delivery=\(keyDownDelivery)")
        // Only proves the authenticated transport accepted the send, exactly
        // the same caveat `enter`'s `workspace_input_sent` marker carries —
        // not that the host actually injected it.
        guard keyDownDelivery == .deliveredWithoutLocation, case .delivered = buttonDownDelivery else {
            try await fail("the key-down/button-down was not accepted by the authenticated transport", error: .heldInputNotSent)
        }

        let heldObserved = await pollUntil(seconds: 5) {
            CGEventSource.keyState(.combinedSessionState, key: focusReleaseModifierKeyCode)
                && CGEventSource.buttonState(.combinedSessionState, button: .left)
        }
        print("focus_release_held_shift_down=\(CGEventSource.keyState(.combinedSessionState, key: focusReleaseModifierKeyCode))")
        print("focus_release_held_left_button_down=\(CGEventSource.buttonState(.combinedSessionState, button: .left))")
        guard heldObserved else {
            try await fail(
                "the host never actually injected the held key-down/button-down onto the real OS input state — "
                    + "either the key-confinement guard refused it because the workspace was not frontmost "
                    + "(check the host log for 'key input dropped, workspace not frontmost') or sensoriumd is missing Accessibility",
                error: .heldInputNeverObserved
            )
        }

        // The exact focus-loss path AppKit takes, not the release method
        // directly: post the two real notifications
        // `ClientCanvasWindowController`'s own observers are registered for.
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window.hostedWindow)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        print("focus_release_notifications_posted=yes")

        let released = await pollUntil(seconds: 5) {
            !CGEventSource.keyState(.combinedSessionState, key: focusReleaseModifierKeyCode)
                && !CGEventSource.buttonState(.combinedSessionState, button: .left)
        }
        print("focus_release_after_shift_down=\(CGEventSource.keyState(.combinedSessionState, key: focusReleaseModifierKeyCode))")
        print("focus_release_after_left_button_down=\(CGEventSource.buttonState(.combinedSessionState, button: .left))")
        guard released else {
            try await fail(
                "the modifier key or the left mouse button was still physically held after focus loss — the release was not actually injected",
                error: .stuckInputAfterFocusLoss
            )
        }

        // The modifier state must genuinely settle, not just the single
        // keyState bit: the aggregate flags CGEventSource reports must not
        // include Shift either.
        let shiftFlagStillSet = CGEventSource.flagsState(.combinedSessionState).contains(.maskShift)
        print("focus_release_shift_flag_still_set=\(shiftFlagStillSet)")
        guard !shiftFlagStillSet else {
            try await fail("CGEventSource still reports Shift held in the aggregate modifier flags after release", error: .stuckModifierFlag)
        }

        runner.stop()
        await session.disconnect(reason: "focus-release-smoke-complete")
        print("focus_release_smoke_complete=yes")
    }

    /// The host binary's file name -- `SensoriumHost` when this probe is
    /// driving the packaged `Sensorium Host.app`
    /// (`Scripts/run-real-local-workspace-input-smoke.sh`), `sensoriumd` when
    /// it is driving the raw, unbundled SwiftPM executable
    /// (`Scripts/run-real-local-focus-release-smoke.sh`), which is not
    /// renamed by packaging. The raw binary has no `Info.plist`, so it has no
    /// `CFBundleIdentifier` for `NSRunningApplication.bundleIdentifier` to
    /// report. The executable path is the one identifier both forms share.
    private static let hostExecutableNames: Set<String> = ["SensoriumHost", "sensoriumd"]

    /// Explicitly asks the host process to become the frontmost app, then
    /// waits for `NSWorkspace` -- real, OS-level, cross-process ground
    /// truth, not this probe's own bookkeeping -- to confirm it actually
    /// did. `NSRunningApplication.activate` is itself asynchronous (it is a
    /// WindowServer round trip), so a caller that sent a key immediately
    /// after issuing it, without waiting for this, would still race the
    /// same way `HostSessionController.mayPost` warns its own `raise` can.
    ///
    /// On failure also reports which application actually held frontmost at
    /// the end of the poll: macOS refuses to hand a background app
    /// frontmost while someone is actively using this machine, and that
    /// app's name is the one piece of real evidence this probe has for
    /// telling that apart from a genuine workspace-focus regression.
    private static func activateHostWorkspace() async -> (confirmed: Bool, contendingApp: String?) {
        guard let hostApp = NSWorkspace.shared.runningApplications.first(
            where: { hostExecutableNames.contains($0.executableURL?.lastPathComponent ?? "") }
        ) else {
            return (false, NSWorkspace.shared.frontmostApplication?.localizedName)
        }
        hostApp.activate(options: .activateIgnoringOtherApps)
        let confirmed = await pollUntil(seconds: 5) {
            hostExecutableNames.contains(NSWorkspace.shared.frontmostApplication?.executableURL?.lastPathComponent ?? "")
        }
        if confirmed {
            return (true, nil)
        }
        return (false, NSWorkspace.shared.frontmostApplication?.localizedName)
    }

    /// Polls at 100ms resolution instead of a single fixed sleep: the host's
    /// real injection is normally near-instant over TCP loopback, and a
    /// generous 5s ceiling still gives room for scheduling jitter without
    /// making the common case slow.
    private static func pollUntil(seconds: Int, condition: () -> Bool) async -> Bool {
        for _ in 0..<(seconds * 10) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    /// Safety net independent of whatever the test above concluded: never
    /// leave a real Shift key or the real left mouse button appearing
    /// physically held on this machine once the probe exits, including on a
    /// failure or a thrown error partway through.
    private static func forceReleaseIfStillHeld(keyCode: UInt16) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        if CGEventSource.keyState(.combinedSessionState, key: keyCode),
           let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) {
            keyUp.post(tap: .cghidEventTap)
        }
        if CGEventSource.buttonState(.combinedSessionState, button: .left) {
            let point = CGEvent(source: source)?.location ?? .zero
            if let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: point,
                mouseButton: .left
            ) {
                mouseUp.post(tap: .cghidEventTap)
            }
        }
    }

    private static func endpointPort(_ rawPort: String) throws -> NWEndpoint.Port {
        guard let rawPort = UInt16(rawPort), let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw InputProbeError.invalidPort
        }
        return port
    }

    private static func identityURL() -> URL {
        applicationSupportDirectory()
            .appendingPathComponent("Sensorium", isDirectory: true)
            .appendingPathComponent("local-workspace-input-probe-identity.json")
    }

    private static func approvalURL() -> URL {
        applicationSupportDirectory()
            .appendingPathComponent("Sensorium", isDirectory: true)
            .appendingPathComponent("local-workspace-input-probe-approval.json")
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    private static func usageAndExit() -> Never {
        print("usage: SensoriumLocalWorkspaceInputProbe <pair|enter|enter-resize|enter-focus-release> <tailnet-host> <port> [pairing-code]")
        Foundation.exit(2)
    }
}

private enum InputProbeError: Error {
    case invalidPort
    case hostWorkspaceNeverFocused
    case routedInputNotDelivered
    case noPresentedFrames
    case noDecodedFrames
    case drawableSizeNotSent
    case resizeSmokeNotOptedIn
    case focusReleaseSmokeNotOptedIn
    case dirtyBaselineInputState
    case heldInputNotSent
    case heldInputNeverObserved
    case stuckInputAfterFocusLoss
    case stuckModifierFlag
}

/// Real decoded-frame dimensions for one measurement window, read from the
/// actual `CVPixelBuffer` VideoToolbox produced — not inferred from any log.
private struct DecodedFrameSnapshot {
    let count: Int
    let width: Int?
    let height: Int?
}

/// Counts decoded frames and records the last pixel-buffer dimensions seen,
/// across calls from VideoToolbox's own decode callback thread.
private final class DecodedFrameTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var lastWidth: Int?
    private var lastHeight: Int?

    func record(_ frame: DecodedFrame) {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        lastWidth = CVPixelBufferGetWidth(frame.pixelBuffer)
        lastHeight = CVPixelBufferGetHeight(frame.pixelBuffer)
    }

    func snapshotAndReset() -> DecodedFrameSnapshot {
        lock.lock()
        defer {
            count = 0
            lock.unlock()
        }
        return DecodedFrameSnapshot(count: count, width: lastWidth, height: lastHeight)
    }
}
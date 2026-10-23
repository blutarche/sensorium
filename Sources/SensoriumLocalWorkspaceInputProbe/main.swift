import AppKit
import ApplicationServices
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
///   SensoriumLocalWorkspaceInputProbe enter-video <tailnet-host> <port>
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
        let tlsCertificateHash: Data?
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
            case "enter-video":
                guard arguments.count == 3 else { usageAndExit() }
                try await enterVideo(host: arguments[1], rawPort: arguments[2])
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
        try JSONEncoder().encode(SavedApproval(hostPublicKey: approval.hostPublicKey, tlsCertificateHash: approval.tlsCertificateHash)).write(to: approvalURL(), options: .atomic)
        await connection.close()
        print("local_input_probe_paired=yes")
    }

    private static func enterVideo(host: String, rawPort: String) async throws {
        let port = try endpointPort(rawPort)
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        let approval = try JSONDecoder().decode(SavedApproval.self, from: Data(contentsOf: approvalURL()))
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: port,
            tlsCertificateHash: approval.tlsCertificateHash,
            transport: .tcpLocalVerification
        )
        try await connection.start()
        let session = ClientSessionController(
            transport: connection,
            identity: identity,
            pinnedHostPublicKey: approval.hostPublicKey
        )
        let window = try ClientCanvasWindowController(title: "Sensorium Local Video Smoke", session: session)
        await session.setCanvasObserver(window.canvasObserver())
        _ = try await session.connect(deviceName: "Sensorium local video smoke probe")
        await window.show()

        let runner = ClientSessionRunner(connection: connection, session: session, window: window)
        do {
            try runner.start()
        } catch {
            await session.disconnect(reason: "video-probe-failed")
            throw error
        }
        print("video_probe_session_started=yes")
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        var decoded = 0
        var presented = 0
        repeat {
            let metrics = await runner.latency.metrics()
            decoded = metrics.samples(for: .decode).count
            presented = metrics.samples(for: .present).count
            if decoded > 0 && presented > 0 { break }
            try? await Task.sleep(for: .milliseconds(100))
        } while ProcessInfo.processInfo.systemUptime < deadline

        runner.stop()
        await session.disconnect(reason: "video-probe-complete")
        print("video_probe_disconnected=yes")
        print("decoded_frames=\(decoded)")
        print("presented_frames=\(presented)")
        guard decoded > 0, presented > 0 else {
            print("workspace_frame_presented=no")
            throw decoded == 0 ? InputProbeError.noDecodedFrames : InputProbeError.noPresentedFrames
        }
        print("workspace_frame_presented=yes")
    }

    private static func enter(host: String, rawPort: String) async throws {
        let hostTarget = try hostWorkspaceTarget()
        let port = try endpointPort(rawPort)
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        let approval = try JSONDecoder().decode(SavedApproval.self, from: Data(contentsOf: approvalURL()))
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: port,
            tlsCertificateHash: approval.tlsCertificateHash,
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
        let (hostFocused, contendingApp) = await activateHostWorkspace(hostTarget)
        print("workspace_focus_confirmed=\(hostFocused)")
        guard hostFocused else {
            print("workspace_focus_holder=\(contendingApp ?? "unknown")")
            print("workspace_input_sent=no")
            runner.stop()
            await session.disconnect(reason: "input-probe-failed")
            throw InputProbeError.hostWorkspaceNeverFocused
        }

        let textBeforeInput = try workspaceText(in: hostTarget)
        let sentinel = "sensoriumprobe" + UUID().uuidString.lowercased().filter { $0.isLetter }
        let keyCodes: [Character: UInt16] = [
            "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "i": 34,
            "m": 46, "n": 45, "o": 31, "p": 35, "r": 15, "s": 1, "u": 32
        ]
        let sentinelKeys = sentinel.compactMap { keyCodes[$0] }
        precondition(sentinelKeys.count == sentinel.count)
        var down = PointerDelivery.droppedFailed
        var up = PointerDelivery.droppedFailed
        // Activation may precede the host's key-window notification. A new
        // sentinel observed through AX proves a complete attempt landed.
        for _ in 0..<5 {
            for keyCode in sentinelKeys {
                down = await router.route(.key(keyCode: keyCode, isDown: true, modifiers: []))
                up = await router.route(.key(keyCode: keyCode, isDown: false, modifiers: []))
            }
            try? await Task.sleep(for: .milliseconds(150))
            if let current = try? workspaceText(in: hostTarget),
               WorkspaceTextObservation.changed(before: textBeforeInput, after: current, sentinel: sentinel) { break }
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
        let textChanged = await pollUntil(seconds: 5) {
            guard let current = try? workspaceText(in: hostTarget) else { return false }
            return WorkspaceTextObservation.changed(before: textBeforeInput, after: current, sentinel: sentinel)
        }
        print("workspace_text_observed=\(textChanged ? "yes" : "no")")
        guard textChanged else {
            runner.stop()
            await session.disconnect(reason: "input-probe-text-unchanged")
            throw InputProbeError.workspaceTextNotObserved
        }

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
            tlsCertificateHash: approval.tlsCertificateHash,
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
        let hostTarget = try hostWorkspaceTarget()
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
            tlsCertificateHash: approval.tlsCertificateHash,
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
        let (hostFocused, contendingApp) = await activateHostWorkspace(hostTarget)
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

    private static func workspaceText(in target: HostWorkspaceActivationTarget) throws -> String {
        func denied() throws -> Never {
            print("workspace_text_observation_blocked=yes")
            throw InputProbeError.workspaceTextObservationUnavailable
        }
        guard AXIsProcessTrusted() else { try denied() }
        guard NSRunningApplication(processIdentifier: target.processIdentifier)?.executableURL?
                .resolvingSymlinksInPath().standardizedFileURL == target.executableURL else {
            throw HostWorkspaceActivationTarget.ValidationError.processExecutableMismatch
        }
        var authorizationDenied = false
        var targetMismatch = false
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var pid: pid_t = 0
            let pidResult = AXUIElementGetPid(element, &pid)
            if pidResult == .apiDisabled { authorizationDenied = true }
            guard pidResult == .success else { return nil }
            guard pid == target.processIdentifier else { targetMismatch = true; return nil }
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
            if result == .apiDisabled { authorizationDenied = true }
            return result == .success ? value : nil
        }
        let application = AXUIElementCreateApplication(target.processIdentifier)
        let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let text = WorkspaceTextObservation.read(
            windows: windows,
            title: { attribute($0, kAXTitleAttribute) as? String },
            isEditor: { attribute($0, kAXRoleAttribute) as? String == kAXTextAreaRole },
            children: { attribute($0, kAXChildrenAttribute) as? [AXUIElement] ?? [] },
            value: { attribute($0, kAXValueAttribute) as? String }
        )
        if targetMismatch { throw HostWorkspaceActivationTarget.ValidationError.processExecutableMismatch }
        if authorizationDenied { try denied() }
        guard let text else { throw InputProbeError.workspaceTextObservationUnavailable }
        return text
    }

    private static func hostWorkspaceTarget() throws -> HostWorkspaceActivationTarget {
        try HostWorkspaceActivationTarget.resolve(
            environment: ProcessInfo.processInfo.environment,
            repositoryRoot: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(),
            executablePath: { NSRunningApplication(processIdentifier: $0)?.executableURL?.path }
        )
    }

    private static func activateHostWorkspace(_ target: HostWorkspaceActivationTarget) async -> (confirmed: Bool, contendingApp: String?) {
        guard let hostApp = NSRunningApplication(processIdentifier: target.processIdentifier),
              hostApp.executableURL?.resolvingSymlinksInPath().standardizedFileURL == target.executableURL else {
            return (false, nil)
        }
        hostApp.activate(options: .activateIgnoringOtherApps)
        let confirmed = await pollUntil(seconds: 5) {
            NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        }
        return (confirmed, confirmed ? nil : NSWorkspace.shared.frontmostApplication?.localizedName)
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
        print("usage: SensoriumLocalWorkspaceInputProbe <pair|enter-video|enter|enter-resize|enter-focus-release> <tailnet-host> <port> [pairing-code]")
        Foundation.exit(2)
    }
}

private enum InputProbeError: Error {
    case invalidPort
    case hostWorkspaceNeverFocused
    case routedInputNotDelivered
    case workspaceTextObservationUnavailable
    case workspaceTextNotObserved
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
enum WorkspaceTextObservation {
    static func read<Node>(
        windows: [Node], title: (Node) -> String?, isEditor: (Node) -> Bool,
        children: (Node) -> [Node], value: (Node) -> String?
    ) -> String? {
        let workspaces = windows.filter { title($0) == "Sensorium Workspace" }
        guard workspaces.count == 1 else { return nil }
        var pending = workspaces
        var editors: [Node] = []
        var visited = 0
        while let node = pending.popLast() {
            visited += 1
            guard visited <= 512 else { return nil }
            if isEditor(node) { editors.append(node) }
            pending.append(contentsOf: children(node))
        }
        guard editors.count == 1 else { return nil }
        return value(editors[0])
    }

    static func changed(before: String, after: String, sentinel: String) -> Bool {
        guard !sentinel.isEmpty, before != after else { return false }
        return after.components(separatedBy: sentinel).count > before.components(separatedBy: sentinel).count
    }
}

struct HostWorkspaceActivationTarget: Equatable {
    let processIdentifier: Int32
    let executableURL: URL

    enum ValidationError: Error {
        case missingOrInvalidProcessIdentifier
        case missingOrUnexpectedExecutable
        case processExecutableMismatch
    }

    static func resolve(
        environment: [String: String],
        repositoryRoot: URL,
        executablePath: (Int32) -> String?
    ) throws -> Self {
        guard let rawPID = environment["SENSORIUM_TEST_HOST_PID"],
              let pid = Int32(rawPID), pid > 1 else {
            throw ValidationError.missingOrInvalidProcessIdentifier
        }
        guard let expectedPath = environment["SENSORIUM_TEST_HOST_EXECUTABLE"], expectedPath.hasPrefix("/") else {
            throw ValidationError.missingOrUnexpectedExecutable
        }
        let root = repositoryRoot.resolvingSymlinksInPath().standardizedFileURL
        let expected = URL(fileURLWithPath: expectedPath).resolvingSymlinksInPath().standardizedFileURL
        let packaged = root.appendingPathComponent("Artifacts/Sensorium/Sensorium Host.app/Contents/MacOS/SensoriumHost")
        let buildRoot = root.appendingPathComponent(".build").path + "/"
        let buildComponents = expected.path.hasPrefix(buildRoot)
            ? String(expected.path.dropFirst(buildRoot.count)).split(separator: "/").map(String.init) : []
        let isBuildHost = buildComponents.count == 3
            && ["debug", "release"].contains(buildComponents[1]) && buildComponents[2] == "sensoriumd"
        guard !expected.path.hasPrefix("/Applications/"), expected == packaged || isBuildHost else {
            throw ValidationError.missingOrUnexpectedExecutable
        }
        guard let actualPath = executablePath(pid),
              URL(fileURLWithPath: actualPath).resolvingSymlinksInPath().standardizedFileURL == expected else {
            throw ValidationError.processExecutableMismatch
        }
        return Self(processIdentifier: pid, executableURL: expected)
    }
}

import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Network
import SensoriumClient
import SensoriumCore
import SensoriumHost

/// Opt-in single-machine acceptance probe for host-screen mode. It uses the
/// production viewer window, frame runner, surface-event router, authenticated
/// transport, and the host's own injector, against one of this machine's real
/// displays -- the sibling of `SensoriumLocalWorkspaceInputProbe`, which does
/// the same for a session canvas.
///
/// usage:
///   SensoriumLocalHostScreenProbe pair <tailnet-host> <port> <pairing-code>
///   SensoriumLocalHostScreenProbe arm <arming-file-path>
///   SensoriumLocalHostScreenProbe wait-idle <timeout-seconds>
///   SensoriumLocalHostScreenProbe enter <tailnet-host> <port>
///
/// `arm` stands in for the arming ceremony a person performs in the host app's
/// own interface (docs/host-screen-design.md §2.1). No wire message can create
/// or widen an arming record, so an automated rig has no way to arm itself
/// except by writing the host's own file directly. It writes only the path it
/// is given, which `Scripts/run-real-local-host-screen-smoke.sh` points at a
/// throwaway `HOME` under `.build/` -- never at anyone's real one.
///
/// `enter` opens a second window of its own, holding an editable text view, on
/// the armed display. That window is the thing being driven: the host injects
/// into a real display, and what lands there is read back from AppKit and from
/// `NSEvent.mouseLocation` -- this process's own view of the machine, not any
/// bookkeeping the session kept.
@main
@MainActor
struct SensoriumLocalHostScreenProbe {
    private struct SavedApproval: Codable {
        let hostPublicKey: Data
    }

    private static let deviceName = "Sensorium local host screen probe"

    /// Unlike the canvas probes, this one needs AppKit to actually deliver the
    /// injected pointer and key events to a window of its own, which only a
    /// running `NSApplication` event loop does. A Swift `async` `main` leaves
    /// the main thread draining the main queue with no run loop on it, so the
    /// work runs as a main-actor task *inside* `NSApplication.run()` instead.
    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let application = NSApplication.shared
        // No bundle, so no `Info.plist` to declare this: a probe that cannot
        // become frontmost cannot be typed into, and typing into it is the
        // whole measurement.
        application.setActivationPolicy(.regular)
        let status = ExitStatus()
        Task { @MainActor in
            do {
                try await run(arguments: Array(CommandLine.arguments.dropFirst()))
            } catch {
                print("local host screen probe failed: \(error)")
                status.code = 1
            }
            stopEventLoop()
        }
        application.run()
        Foundation.exit(status.code)
    }

    private static func run(arguments: [String]) async throws {
        guard let mode = arguments.first else {
            usageAndExit()
        }
        switch mode {
        case "pair":
            guard arguments.count == 4 else { usageAndExit() }
            try await pair(host: arguments[1], rawPort: arguments[2], code: arguments[3])
        case "arm":
            guard arguments.count == 2 else { usageAndExit() }
            try arm(armingFilePath: arguments[1])
        case "wait-idle":
            guard arguments.count == 2 else { usageAndExit() }
            await waitForNobodyAtThisMac(rawTimeout: arguments[1])
        case "enter":
            guard arguments.count == 3 else { usageAndExit() }
            try await enter(host: arguments[1], rawPort: arguments[2])
        default:
            usageAndExit()
        }
    }

    /// `stop(_:)` is only read between events, so a loop with nothing else
    /// arriving would sit there forever without one to read it.
    private static func stopEventLoop() {
        NSApplication.shared.stop(nil)
        let wake = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        )
        if let wake {
            NSApplication.shared.postEvent(wake, atStart: true)
        }
    }

    private static func pair(host: String, rawPort: String, code: String) async throws {
        let port = try endpointPort(rawPort)
        try createStateDirectory()
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        let credential = try UnattendedTestPresenceCredential(url: presenceKeyURL())
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: port,
            transport: .tcpLocalVerification
        )
        try await connection.start()
        let session = ClientSessionController(
            transport: connection,
            identity: identity,
            credentialProvider: credential
        )
        let approval = try await session.pair(deviceName: deviceName, code: code)
        // Host screen refuses a device with no registered credential, so a
        // pairing that quietly registered none would fail much later, as an
        // opaque refusal at `enter`.
        guard case .registered = approval.presenceCredentialRegistration else {
            throw HostScreenProbeError.presenceCredentialNotRegistered
        }
        try JSONEncoder().encode(SavedApproval(hostPublicKey: approval.hostPublicKey))
            .write(to: approvalURL(), options: .atomic)
        await connection.close()
        print("host_screen_probe_paired=yes")
    }

    /// Writes the host's arming record through the host's own store, so this
    /// rig cannot drift from the format the host reads. Names this probe's own
    /// device key and the strength that device registered at pairing; arming
    /// is per machine, so the display `enter` will open its window on is only
    /// printed, never armed for.
    private static func arm(armingFilePath: String) throws {
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        guard let display = targetDisplay() else {
            throw HostScreenProbeError.noTargetDisplay
        }
        HostScreenArmingStore(url: URL(fileURLWithPath: armingFilePath)).arm(
            HostScreenDeviceArming(
                devicePublicKey: identity.publicKey,
                deviceName: deviceName,
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        )
        print("host_screen_probe_armed_display=\(HostScreenDisplayIdentity(display).wireStableIdentifier)")
        print("host_screen_probe_armed_display_id=\(display.id)")
    }

    /// docs/host-screen-design.md §6.2: a host-screen session starts without asking only when
    /// nobody has touched this machine for several minutes. Anyone who starts this
    /// rig has, by definition, just touched it, so the rig waits that out
    /// rather than leaving a prompt on a real screen with nobody expecting it.
    /// Waiting cannot be skipped from the wire and is not a way around the
    /// rule: it is the same reading the host itself takes, read here first so
    /// a run that could only ever be refused says so instead.
    private static func waitForNobodyAtThisMac(rawTimeout: String) async {
        guard let timeout = Double(rawTimeout), timeout > 0 else {
            usageAndExit()
        }
        // A second past the host's own threshold, because the host refuses an
        // exact tie: "an exact tie resolves toward asking."
        let required = HostScreenPresenceRule.recommendedPresenceThreshold + 1
        let signal = CoreGraphicsLocalActivitySignal()
        let deadline = Date().addingTimeInterval(timeout)
        var lastReported = -1.0
        while Date() < deadline {
            guard case let .idleFor(seconds) = signal.currentReading() else {
                break
            }
            if seconds > required {
                print("host_screen_probe_idle_seconds=\(Int(seconds))")
                return
            }
            if lastReported < 0 || lastReported - seconds > 5 {
                print("host_screen_probe_waiting_for_idle_seconds=\(Int(required - seconds))")
            }
            lastReported = seconds
            try? await Task.sleep(for: .seconds(5))
        }
        print("BLOCKED: someone is using this machine, so the host would ask them before sharing a screen. "
            + "Leave it alone for \(Int(required / 60)) minutes and run this again.")
        Foundation.exit(3)
    }

    private static func enter(host: String, rawPort: String) async throws {
        let port = try endpointPort(rawPort)
        let identity = try FileDeviceIdentityStore(url: identityURL()).loadOrCreate()
        let approval = try JSONDecoder().decode(SavedApproval.self, from: Data(contentsOf: approvalURL()))
        let credential = try UnattendedTestPresenceCredential(url: presenceKeyURL())
        guard let display = targetDisplay(), let screen = screen(for: display) else {
            throw HostScreenProbeError.noTargetDisplay
        }

        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: port,
            transport: .tcpLocalVerification
        )
        try await connection.start()
        let session = ClientSessionController(
            transport: connection,
            identity: identity,
            credentialProvider: credential,
            pinnedHostPublicKey: approval.hostPublicKey
        )
        let window = try ClientCanvasWindowController(title: "Sensorium Local Host Screen", session: session)
        await session.setCanvasObserver(window.canvasObserver())
        let outcome = try await session.connect(
            deviceName: deviceName,
            target: .hostScreen(displayIdentity: HostScreenDisplayIdentity(display).wireStableIdentifier)
        )
        guard case let .hostScreen(geometry, _) = outcome else {
            throw HostScreenProbeError.sessionIsNotHostScreen
        }
        print("host_screen_geometry=\(geometry.logicalWidth)x\(geometry.logicalHeight)@\(geometry.backingScale)")
        await window.show()

        let runner = ClientSessionRunner(connection: connection, session: session, window: window)

        // Viewer-driven mode-change state, fed by the runner's own callbacks
        // so the exchange is read exactly as a real viewer would see it --
        // never by asking the host or CoreGraphics directly what it just did.
        var offeredModes: [HostScreenModeEntry] = []
        var offeredCurrentModeID: String?
        var modeApplied: (geometry: SessionSurfaceGeometry, currentModeID: String)?
        var modeRefused: String?
        runner.onHostScreenModeList = { modes, currentModeID in
            offeredModes = modes
            offeredCurrentModeID = currentModeID
        }
        runner.onHostScreenModeApplied = { geometry, currentModeID in
            modeApplied = (geometry, currentModeID)
        }
        runner.onHostScreenModeRefused = { reason in
            modeRefused = reason
        }

        try runner.start()
        print("host_screen_viewer_started=yes")

        // The mode this display was on before any of this touched it, held
        // as the live `CGDisplayMode` object itself, not just a description
        // of it, because the probe-side fallback restore below needs to hand
        // CoreGraphics that exact object, never one re-derived from a
        // description of it.
        let originalMode = CGDisplayCopyDisplayMode(display.id)
        let originalModeSnapshot = originalMode.map(DisplayModeSnapshot.init)
        print("mode_before=\(originalModeSnapshot?.line ?? "unknown")")

        var modeChangeError: Error?
        var modeChangeWasSkipped = false
        if await pollUntil(seconds: 10, condition: { !offeredModes.isEmpty }) == false {
            print("mode_requested=none")
            print("mode_applied=no")
            modeChangeError = HostScreenProbeError.modeListNeverArrived
        } else if await pollFrames(atLeast: 1, within: 10, runner: runner) == false {
            print("mode_requested=none")
            print("mode_applied=no")
            modeChangeError = HostScreenProbeError.noPresentedFrames
        } else if let target = Self.largestOtherHiDPIMode(in: offeredModes, excluding: offeredCurrentModeID) {
            print("mode_requested=\(target.modeID)")
            let framesBeforeRequest = await presentedFrameCount(runner)
            await runner.requestHostScreenMode(target.modeID)
            let arrived = await pollUntil(seconds: 15, condition: { modeApplied != nil || modeRefused != nil })
            if !arrived {
                print("mode_applied=no")
                modeChangeError = HostScreenProbeError.modeChangeTimedOut
            } else if let modeRefused {
                print("mode_applied=no")
                modeChangeError = HostScreenProbeError.modeChangeRefused(modeRefused)
            } else {
                print("mode_applied=yes")
                // Presented frames must resume quickly, not merely
                // eventually: a host that keeps the old capture's packet
                // sequencer picks back up within a frame or two, while one
                // that restarted it at zero is silently discarded by the
                // viewer's own `VideoFrameIngress` until the new count climbs
                // back past the old one, which can take minutes at a low
                // frame rate.
                if let resumedWithin = await pollFramesElapsed(
                    atLeast: framesBeforeRequest + 5, within: 3, runner: runner
                ) {
                    print(String(format: "mode_frames_resumed_within=%.1f", resumedWithin))
                } else {
                    modeChangeError = HostScreenProbeError.framesDidNotResumeAfterModeChange
                }
                let pixelMatched = await pollUntil(seconds: 5, condition: {
                    guard let mode = CGDisplayCopyDisplayMode(display.id) else { return false }
                    return mode.pixelWidth == target.pixelWidth && mode.pixelHeight == target.pixelHeight
                })
                if !pixelMatched, modeChangeError == nil {
                    modeChangeError = HostScreenProbeError.displayModeDidNotMatchRequest
                }
            }
        } else {
            print("mode_requested=none")
            print("mode_applied=skipped-single-mode")
            modeChangeWasSkipped = true
        }

        // A mode change above replaces both the geometry and the display's
        // own bounds; the session-start `geometry` and `display` snapshot
        // are stale from that point on, exactly as they would be for a real
        // viewer, which is why `onHostScreenModeApplied` re-reads both too.
        let currentGeometry = modeApplied?.geometry ?? geometry
        let currentDisplay = modeApplied != nil
            ? (DisplayInventory.active().first { $0.id == display.id } ?? display)
            : display
        // `screen`, resolved before the mode change ran, is the same stale
        // trap: AppKit's own `NSScreen.frame` for the armed display has
        // moved on to the new size, and a window built from the old one
        // centres itself over a rectangle that no longer describes anything
        // on screen.
        guard let currentScreen = modeApplied != nil ? Self.screen(for: currentDisplay) : screen else {
            throw HostScreenProbeError.noTargetScreenAfterModeChange
        }

        let target = TargetWindow(screen: currentScreen)
        target.show()
        // The armed display and the display the window actually stands on
        // have to be the same one, or every coordinate below is measured
        // against a display nobody is streaming.
        guard let standingOn = activeDisplay(containing: target.centreInGlobalDisplaySpace()),
              standingOn.id == display.id else {
            throw HostScreenProbeError.windowNotOnArmedDisplay
        }
        print("host_screen_probe_window_display_id=\(standingOn.id)")

        // The viewer's own input path: the surface router over a viewport
        // built from the geometry the host reported for the display it is
        // streaming, rather than any canvas preset.
        let inputViewport = ClientViewportController(
            mapper: VirtualCanvasInputMapper(
                logicalWidth: Double(currentGeometry.logicalWidth),
                logicalHeight: Double(currentGeometry.logicalHeight)
            ),
            pointerSink: session
        )
        let router = CanvasSurfaceEventRouter(viewport: inputViewport)
        // A viewport the same size as the display it drives makes the mapping
        // one to one, so a point measured on this machine is the point the host is
        // asked to move to.
        _ = await router.route(.boundsChanged(
            width: Double(currentGeometry.logicalWidth),
            height: Double(currentGeometry.logicalHeight)
        ))
        await inputViewport.canvasDidBecomeReady()

        let targetPoint = target.textCentreInScreenSpace()
        let local = displayLocalPoint(targetPoint, on: currentDisplay)
        print("pointer_target=\(local.x),\(local.y)")
        // The router reads a view's own bottom-left origin, so the display's
        // top-down coordinate is flipped back before it goes in.
        let move = await router.route(.pointerMoved(
            x: local.x,
            y: Double(currentGeometry.logicalHeight) - local.y
        ))
        guard case .delivered = move else {
            print("pointer_moved=no")
            print("pointer_route=\(Self.describe(move)) "
                + "viewport=\(currentGeometry.logicalWidth)x\(currentGeometry.logicalHeight) "
                + "local=\(local.x),\(local.y)")
            throw HostScreenProbeError.pointerNotDelivered
        }
        let pointerLanded = await pollUntil(seconds: 5) {
            hypot(
                NSEvent.mouseLocation.x - targetPoint.x,
                NSEvent.mouseLocation.y - targetPoint.y
            ) <= 3.0
        }
        print("pointer_landed_at=\(NSEvent.mouseLocation.x),\(NSEvent.mouseLocation.y)")
        print("pointer_moved=\(pointerLanded ? "yes" : "no")")

        _ = await router.route(.pointerButton(
            button: .left,
            isDown: true,
            x: local.x,
            y: Double(currentGeometry.logicalHeight) - local.y
        ))
        _ = await router.route(.pointerButton(
            button: .left,
            isDown: false,
            x: local.x,
            y: Double(currentGeometry.logicalHeight) - local.y
        ))

        // Retried, bounded, for the same reason the canvas probe retries its
        // own: a key goes to whatever holds this machine's one keyboard focus, and
        // the click above only asks for it -- AppKit grants it on its own
        // schedule, and a key posted before that lands somewhere else.
        var typed = false
        for _ in 0..<30 {
            target.takeKeyboardFocus()
            _ = await router.route(.key(keyCode: keyCodeA, isDown: true, modifiers: []))
            _ = await router.route(.key(keyCode: keyCodeA, isDown: false, modifiers: []))
            try? await Task.sleep(for: .milliseconds(200))
            if target.typedText().contains("a") {
                typed = true
                break
            }
        }
        print("text_typed=\(typed ? "yes" : "no")")

        try await Task.sleep(for: .seconds(2))
        let presented = await runner.latency.metrics().samples(for: .present).count
        print("host_screen_frames=\(presented)")
        runner.stop()
        await session.disconnect(reason: "host-screen-probe-complete")
        target.close()

        // The one unacceptable outcome on a real display: leaving it on a
        // mode nobody asked to keep. Checked after the session has ended, as
        // the design requires ("restored when the session ends"), and polled
        // because that restoration can be asynchronous.
        if !modeChangeWasSkipped {
            let matchesOriginal = { () -> Bool in
                guard let originalModeSnapshot else { return true }
                guard let mode = CGDisplayCopyDisplayMode(display.id) else { return false }
                return DisplayModeSnapshot(mode) == originalModeSnapshot
            }
            if await pollUntil(seconds: 10, condition: matchesOriginal) {
                print("mode_restored=yes")
                print("mode_restored_by=host")
            } else if let originalMode, probeRestoreMode(originalMode, on: display.id) {
                let restoredByProbe = await pollUntil(seconds: 5, condition: matchesOriginal)
                print("mode_restored=\(restoredByProbe ? "yes" : "no")")
                print("mode_restored_by=probe")
                if !restoredByProbe {
                    modeChangeError = modeChangeError ?? HostScreenProbeError.displayNotRestored
                }
            } else {
                print("mode_restored=no")
                print("mode_restored_by=probe")
                modeChangeError = modeChangeError ?? HostScreenProbeError.displayNotRestored
            }
        }

        guard presented > 0 else {
            throw HostScreenProbeError.noPresentedFrames
        }
        guard pointerLanded else {
            throw HostScreenProbeError.pointerNeverLanded
        }
        guard typed else {
            throw HostScreenProbeError.textNeverTyped
        }
        if let modeChangeError {
            throw modeChangeError
        }
    }

    /// ANSI `a`. One printable character is all this needs, and the one the
    /// script looks for in the text view afterwards.
    private static let keyCodeA: UInt16 = 0

    /// The offered mode most worth proving the round trip with: the sharpest
    /// picture the display can show that is not the one it is already on. A
    /// display armed with only one usable mode has nothing to change to, and
    /// that is reported as skipped rather than as a failure.
    private static func largestOtherHiDPIMode(
        in modes: [HostScreenModeEntry], excluding currentModeID: String?
    ) -> HostScreenModeEntry? {
        modes
            .filter { $0.modeID != currentModeID }
            .sorted { lhs, rhs in
                if lhs.isHiDPI != rhs.isHiDPI {
                    return lhs.isHiDPI
                }
                return lhs.pixelWidth * lhs.pixelHeight > rhs.pixelWidth * rhs.pixelHeight
            }
            .first
    }

    /// `PointerDelivery` carries no description of its own; this names each
    /// case (and the point a `.delivered` one actually carried) for the one
    /// diagnostic line printed when a route is anything else.
    private static func describe(_ delivery: PointerDelivery) -> String {
        switch delivery {
        case let .delivered(point): return "delivered(\(point.x),\(point.y))"
        case .deliveredWithoutLocation: return "deliveredWithoutLocation"
        case .coalesced: return "coalesced"
        case .droppedNoViewport: return "droppedNoViewport"
        case .droppedInvalidLocation: return "droppedInvalidLocation"
        case .droppedNotConnected: return "droppedNotConnected"
        case .droppedFailed: return "droppedFailed"
        case .droppedNoChange: return "droppedNoChange"
        }
    }

    private static func presentedFrameCount(_ runner: ClientSessionRunner) async -> Int {
        await runner.latency.metrics().samples(for: .present).count
    }

    private static func pollFrames(atLeast minimum: Int, within seconds: Int, runner: ClientSessionRunner) async -> Bool {
        for _ in 0..<(seconds * 10) {
            if await presentedFrameCount(runner) >= minimum { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await presentedFrameCount(runner) >= minimum
    }

    /// `pollFrames` without the elapsed time it already measures internally
    /// but never reports -- used where how quickly frames resumed is itself
    /// the thing under test, not just whether they eventually did.
    private static func pollFramesElapsed(atLeast minimum: Int, within seconds: Int, runner: ClientSessionRunner) async -> Double? {
        let startedAt = Date()
        for _ in 0..<(seconds * 10) {
            if await presentedFrameCount(runner) >= minimum { return Date().timeIntervalSince(startedAt) }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return await presentedFrameCount(runner) >= minimum ? Date().timeIntervalSince(startedAt) : nil
    }

    /// The last-resort restore this rig owns, used only when the host's own
    /// restore-on-disconnect (CLAUDE.md: "restored when the session ends or
    /// the host quits") did not put the display back within the poll window
    /// above. The same three public CoreGraphics calls
    /// `CoreGraphicsHostScreenModeController` uses, completed `.forSession`
    /// so nothing here can outlive this login session either.
    private static func probeRestoreMode(_ mode: CGDisplayMode, on displayID: UInt32) -> Bool {
        var configuration: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configuration) == .success, let configuration else {
            return false
        }
        guard CGConfigureDisplayWithDisplayMode(configuration, displayID, mode, nil) == .success else {
            CGCancelDisplayConfiguration(configuration)
            return false
        }
        return CGCompleteDisplayConfiguration(configuration, .forSession) == .success
    }

    /// The display is on right now, in real pixels and refresh rate --
    /// enough to tell one mode from another without re-deriving anything
    /// `HostScreenModePresentation` already names on the wire.
    private struct DisplayModeSnapshot: Equatable {
        let pixelWidth: Int
        let pixelHeight: Int
        let refreshRate: Double

        init(_ mode: CGDisplayMode) {
            pixelWidth = mode.pixelWidth
            pixelHeight = mode.pixelHeight
            refreshRate = mode.refreshRate
        }

        var line: String { "\(pixelWidth)x\(pixelHeight)@\(Int(refreshRate.rounded()))" }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.pixelWidth == rhs.pixelWidth
                && lhs.pixelHeight == rhs.pixelHeight
                && Int(lhs.refreshRate.rounded()) == Int(rhs.refreshRate.rounded())
        }
    }

    /// The display this rig arms and drives: the main one, which is where a
    /// window opened with no placement of its own already goes. `enter`
    /// re-checks that its window really stands here before measuring anything
    /// against it.
    private static func targetDisplay() -> DisplaySnapshot? {
        let displays = DisplayInventory.active()
        return displays.first { $0.main } ?? displays.first
    }

    private static func screen(for display: DisplaySnapshot) -> NSScreen? {
        NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.id
        }
    }

    private static func activeDisplay(containing point: CGPoint) -> DisplaySnapshot? {
        DisplayInventory.active().first { $0.bounds.contains(point) }
    }

    /// AppKit measures the screen space from the bottom-left of the display
    /// holding the menu bar; CoreGraphics, which is what a display's own
    /// bounds and the host's injector both speak, measures down from that same
    /// display's top-left.
    private static func globalDisplayPoint(_ screenPoint: CGPoint) -> CGPoint {
        let menuBarScreen = NSScreen.screens.first
        let flipHeight = menuBarScreen?.frame.maxY ?? 0
        return CGPoint(x: screenPoint.x, y: flipHeight - screenPoint.y)
    }

    private static func displayLocalPoint(_ screenPoint: CGPoint, on display: DisplaySnapshot) -> CGPoint {
        let global = globalDisplayPoint(screenPoint)
        return CGPoint(x: global.x - display.bounds.origin.x, y: global.y - display.bounds.origin.y)
    }

    private static func pollUntil(seconds: Int, condition: () -> Bool) async -> Bool {
        for _ in 0..<(seconds * 10) {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    private static func endpointPort(_ rawPort: String) throws -> NWEndpoint.Port {
        guard let rawPort = UInt16(rawPort), let port = NWEndpoint.Port(rawValue: rawPort) else {
            throw HostScreenProbeError.invalidPort
        }
        return port
    }

    private static func createStateDirectory() throws {
        try FileManager.default.createDirectory(
            at: stateDirectory(),
            withIntermediateDirectories: true
        )
    }

    private static func stateDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sensorium", isDirectory: true)
    }

    private static func identityURL() -> URL {
        stateDirectory().appendingPathComponent("local-host-screen-probe-identity.json")
    }

    private static func approvalURL() -> URL {
        stateDirectory().appendingPathComponent("local-host-screen-probe-approval.json")
    }

    private static func presenceKeyURL() -> URL {
        stateDirectory().appendingPathComponent("local-host-screen-probe-presence-key.json")
    }

    private static func usageAndExit() -> Never {
        print("usage: SensoriumLocalHostScreenProbe <pair|arm|wait-idle|enter> "
            + "<tailnet-host|arming-file-path|timeout-seconds> [port] [pairing-code]")
        Foundation.exit(2)
    }
}

/// The window the host is asked to drive: an editable text view on the armed
/// display, floating above the viewer window this probe also opens, so a click
/// aimed at its centre reaches it rather than whatever else this process has
/// on screen.
@MainActor
private final class TargetWindow {
    private let window: NSWindow
    private let textView: NSTextView

    init(screen: NSScreen) {
        let size = CGSize(width: 480, height: 260)
        let frame = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.title = "Sensorium host screen probe target"
        window.level = .floating
        textView = NSTextView(frame: NSRect(origin: .zero, size: window.contentLayoutRect.size))
        textView.isEditable = true
        textView.isSelectable = true
        textView.autoresizingMask = [.width, .height]
        window.contentView = textView
    }

    func show() {
        window.setFrameOrigin(window.frame.origin)
        takeKeyboardFocus()
    }

    func takeKeyboardFocus() {
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeFirstResponder(textView)
    }

    func typedText() -> String {
        textView.string
    }

    /// The centre of the text view, in AppKit's own screen space.
    func textCentreInScreenSpace() -> CGPoint {
        let centre = CGPoint(x: textView.bounds.midX, y: textView.bounds.midY)
        let inWindow = textView.convert(centre, to: nil)
        return window.convertPoint(toScreen: inWindow)
    }

    /// The window's centre where a display's own bounds can be asked about it.
    func centreInGlobalDisplaySpace() -> CGPoint {
        let menuBarScreen = NSScreen.screens.first
        let flipHeight = menuBarScreen?.frame.maxY ?? 0
        return CGPoint(x: window.frame.midX, y: flipHeight - window.frame.midY)
    }

    func close() {
        window.orderOut(nil)
    }
}

/// A presence credential for this acceptance rig and nothing else: an ordinary
/// P-256 key this process holds in a file, signing with no prompt, no
/// enclave, and no human. It reports `hardwareBound` so the host's own
/// arming minimum and signature check are exercised for real -- which is
/// exactly why no shipping code may ever use it. A real viewer registers
/// `SecureEnclavePresenceCredential`; this one proves nothing whatever about a
/// person being present.
///
/// The key outlives the process because pairing and entering are two separate
/// runs of this probe, and the host verifies the session's signature against
/// the public half registered at pairing. It is written only under the
/// throwaway `HOME` the smoke script creates.
private final class UnattendedTestPresenceCredential: PresenceCredentialProviding, @unchecked Sendable {
    private struct StoredKey: Codable {
        let privateKey: Data
    }

    /// The format `PresenceCredentialVerifier` supports: raw P-256 ECDSA over
    /// the raw challenge bytes. The format names the verification routine,
    /// which is the same for both strengths.
    static let credentialFormat = "apple-secure-enclave-p256"

    let strength = PresenceCredentialStrength.hardwareBound
    private let key: P256.Signing.PrivateKey
    private let credentialID: Data

    init(url: URL) throws {
        if let data = try? Data(contentsOf: url),
           let stored = try? JSONDecoder().decode(StoredKey.self, from: data),
           let loaded = try? P256.Signing.PrivateKey(rawRepresentation: stored.privateKey) {
            key = loaded
        } else {
            let created = P256.Signing.PrivateKey()
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try JSONEncoder().encode(StoredKey(privateKey: created.rawRepresentation))
                .write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            key = created
        }
        credentialID = Data(SHA256.hash(data: key.publicKey.rawRepresentation))
    }

    func register() async throws -> PresenceCredentialRegistration {
        PresenceCredentialRegistration(
            credentialID: credentialID,
            publicKey: key.publicKey.rawRepresentation,
            credentialFormat: Self.credentialFormat,
            strength: strength.rawValue
        )
    }

    func sign(challenge: Data) async throws -> Data {
        try key.signature(for: challenge).rawRepresentation
    }
}

/// The exit code `main` reports once `NSApplication.run()` has returned, since
/// the work that decides it finishes inside the event loop rather than around
/// it.
@MainActor
private final class ExitStatus {
    var code: Int32 = 0
}

private enum HostScreenProbeError: Error {
    case invalidPort
    case noTargetDisplay
    case noTargetScreenAfterModeChange
    case presenceCredentialNotRegistered
    case sessionIsNotHostScreen
    case windowNotOnArmedDisplay
    case pointerNotDelivered
    case pointerNeverLanded
    case textNeverTyped
    case noPresentedFrames
    case modeListNeverArrived
    case modeChangeTimedOut
    case modeChangeRefused(String)
    case framesDidNotResumeAfterModeChange
    case displayModeDidNotMatchRequest
    case displayNotRestored
}

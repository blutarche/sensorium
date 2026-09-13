import AppKit
import CoreGraphics
import Foundation

/// Test-only content generator for throughput measurement.
///
/// `NativeCanvasWorkspace` is the default, shipping session workspace, and it
/// is deliberately static (an editable text view) until a user types or
/// clicks. ScreenCaptureKit correctly delivers very few frames for genuinely
/// static content, so a benchmark run against the default workspace measures
/// idle behaviour, not achievable throughput. This type exists solely so a
/// throughput measurement can observe capture/encode/send under continuously
/// changing content; it renders no meaningful information and is never
/// selected unless the operator explicitly opts in (see `sensoriumd`'s
/// `SENSORIUM_BENCH_ANIMATED_WORKSPACE` environment toggle, off by default).
///
/// Gives the same stored answers as the shipping workspace for
/// `installedWindow`, `hasKeyFocus`, `canvasBounds`, and `raise`, so key
/// confinement behaves identically under measurement.
@MainActor
public final class AnimatedMeasurementWorkspace: CanvasWorkspacePresenting {
    private let physicalDisplayIDs: Set<UInt32>
    private var window: NSWindow?
    private var timer: Timer?
    /// The connection whose window is installed right now, carrying the same
    /// ownership discipline the shipping workspace does. See
    /// `CanvasWorkspacePresenting` and `CanvasOwnerToken`.
    private var owner: CanvasOwnerToken?
    /// Identifies the window this workspace has up, exactly as the shipping
    /// workspace's does. See `NativeCanvasWorkspace.windowToken`.
    private var windowToken: CanvasWorkspaceWindowToken?
    private var canvasDisplayID: UInt32?
    /// The rectangle that canvas occupies. See
    /// `NativeCanvasWorkspace.placementBounds`.
    private var placementBounds: CGRect?
    private let keyFocus = WorkspaceKeyFocusTracker()
    /// Shared with `VirtualDisplaySession` and `NativeCanvasWorkspace` so
    /// this workspace's own placement — including the readiness wait below,
    /// which pumps the run loop and can dispatch a second connection's
    /// `.canvasRequest` — is serialised against theirs. See
    /// `CanvasCreationGate`: this workspace is test-only and never shipped in
    /// the default `serve` path, but it is still a live path to the same
    /// display-ID allocator corruption a second, unguarded canvas creation
    /// causes.
    private let creationGate: CanvasCreationGate

    public init(physicalDisplayIDs: Set<UInt32>, creationGate: CanvasCreationGate = CanvasCreationGate()) {
        self.physicalDisplayIDs = physicalDisplayIDs
        self.creationGate = creationGate
    }

    private static let readinessMaxAttempts = 40
    private static let readinessPollInterval: TimeInterval = 0.05

    public func start(canvasDisplayID: UInt32, owner: CanvasOwnerToken) throws {
        try creationGate.run {
            stop()
            // A freshly created virtual display registers with WindowServer
            // asynchronously; wait for it the same way `NativeCanvasWorkspace`
            // does before trusting its bounds/registration.
            let readiness = CanvasDisplayReadiness.awaitReady(
                expectedWidth: VirtualCanvasConfiguration.remoteDefault.logicalWidth,
                expectedHeight: VirtualCanvasConfiguration.remoteDefault.logicalHeight,
                maxAttempts: Self.readinessMaxAttempts,
                probe: {
                    CanvasDisplayReadinessSample(
                        bounds: CGDisplayBounds(canvasDisplayID),
                        isRegisteredInScreens: self.screen(for: canvasDisplayID) != nil
                    )
                },
                pump: {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(Self.readinessPollInterval))
                }
            )
            let sample = readiness.sample
            print("Sensorium host: canvas readiness attempts=\(readiness.attempts) ready=\(readiness.isReady)")
            let placement = try CanvasWorkspacePlacement.resolve(
                ownedHandle: VirtualDisplayHandle(rawValue: canvasDisplayID),
                display: CanvasWorkspaceDisplay(
                    id: canvasDisplayID,
                    bounds: sample.bounds,
                    isBuiltin: CGDisplayIsBuiltin(canvasDisplayID) != 0,
                    isOnline: CGDisplayIsOnline(canvasDisplayID) != 0
                ),
                physicalDisplayIDs: physicalDisplayIDs
            )
            guard screen(for: canvasDisplayID) != nil else {
                throw NativeCanvasWorkspaceError.screenUnavailable
            }

            let application = NSApplication.shared
            WorkspaceActivationPolicy.shared.windowOpened()

            let window = NSWindow(
                contentRect: placement.bounds,
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Sensorium Throughput Measurement"
            window.isReleasedWhenClosed = false
            // Pinned to its canvas exactly as the shipping workspace's window
            // is: a measurement window draggable onto a physical display would
            // take confined keystrokes there with it.
            window.isMovable = false
            window.isMovableByWindowBackground = false
            window.setFrame(placement.bounds, display: true)

            let content = AnimatedMeasurementContentView(frame: NSRect(origin: .zero, size: placement.bounds.size))
            window.contentView = content
            window.makeKeyAndOrderFront(nil)
            application.activate(ignoringOtherApps: true)
            self.window = window
            self.canvasDisplayID = canvasDisplayID
            placementBounds = placement.bounds
            keyFocus.track(window)

            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak content] _ in
                MainActor.assumeIsolated {
                    content?.advance()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            self.owner = owner
            windowToken = CanvasWorkspaceWindowToken()
        }
    }

    public func stop(owner: CanvasOwnerToken) {
        guard self.owner == owner else {
            return
        }
        stop()
    }

    public func stop() {
        owner = nil
        windowToken = nil
        canvasDisplayID = nil
        placementBounds = nil
        keyFocus.stop()
        timer?.invalidate()
        timer = nil
        guard let window else {
            return
        }
        window.orderOut(nil)
        window.close()
        self.window = nil
        WorkspaceActivationPolicy.shared.windowClosed()
    }

    public func installedWindow(owner: CanvasOwnerToken) -> CanvasWorkspaceWindowToken? {
        guard window != nil, self.owner == owner else {
            return nil
        }
        return windowToken
    }

    public func hasKeyFocus(owner: CanvasOwnerToken) -> Bool {
        guard window != nil, self.owner == owner else {
            return false
        }
        return keyFocus.hasKeyFocus
    }

    public func canvasBounds(owner: CanvasOwnerToken) -> CGRect? {
        guard window != nil, self.owner == owner else {
            return nil
        }
        return placementBounds
    }

    public func raise(owner: CanvasOwnerToken) -> Bool {
        guard let window, let canvasDisplayID, self.owner == owner else {
            return false
        }
        guard CanvasWorkspacePlacement.isOnOwnedCanvas(
            canvasDisplayID: canvasDisplayID,
            windowScreenDisplayID: NativeCanvasWorkspace.displayID(of: window.screen)
        ) else {
            return false
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        keyFocus.refresh()
        return true
    }

    private func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }
}

/// Continuously redraws a moving, color-cycling shape so every capture
/// interval has new pixel content. Never used by the default session
/// workspace.
@MainActor
private final class AnimatedMeasurementContentView: NSView {
    private var phaseDegrees: CGFloat = 0

    func advance() {
        phaseDegrees += 6
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()

        let side = min(bounds.width, bounds.height) / 4
        let radians = phaseDegrees * .pi / 180
        let x = (bounds.width - side) / 2 + cos(radians) * (bounds.width / 3)
        let y = (bounds.height - side) / 2 + sin(radians) * (bounds.height / 3)
        let hue = phaseDegrees.truncatingRemainder(dividingBy: 360) / 360
        NSColor(calibratedHue: hue, saturation: 0.85, brightness: 0.95, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: y, width: side, height: side)).fill()
    }
}

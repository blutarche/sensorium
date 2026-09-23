#if canImport(CGtk4) && canImport(CWayland) && canImport(CEGL) && canImport(CAVCodec)
import Foundation
import SensoriumCore

/// Builds the Linux session windows: one Wayland surface per canvas, decoding
/// through libavcodec.
@MainActor
public final class LinuxSessionWindowFactory: SessionWindowFactory {
    private let tracesPresentation: Bool

    /// `tracesPresentation` is `--trace`, which the viewer already takes for
    /// its latency trace file: a run asking for one wants the picture's own
    /// running counts too.
    public init(tracesPresentation: Bool = false) {
        self.tracesPresentation = tracesPresentation
    }

    public func makeSessionWindow(
        title: String,
        session: ClientSessionController,
        surfaceID: UInt32,
        hostName: String,
        shortcutMode: SystemShortcutMode,
        initialStreamScalePreference: StreamScalePreference,
        savedHostStore: any SavedHostStoring,
        savedHostPublicKey: Data
    ) throws -> any ViewerSessionWindow {
        let window = try WaylandSessionWindow(
            title: title,
            session: session,
            surfaceID: surfaceID,
            initialStreamScalePreference: initialStreamScalePreference,
            makeDecoder: AVCodecVideoDecoder.factory
        )
        // The compositor's own close control ends the session, the same way
        // the macOS window's red button does. The window is not torn down
        // under a session that is still live.
        window.onClosed = { [weak window] in window?.chrome.onCloseRequested?() }
        // What every strip confirmation and every tooltip names: the machine
        // being worked on, not the one this viewer runs on.
        window.setChromeHostName(hostName)
        if tracesPresentation {
            WaylandSessionTrace(window: window).start()
        }
        return window
    }
}

/// What else on this platform has to know which session windows exist: the
/// clipboard a session asked for before any window was open, and the
/// interceptor that asks the compositor to stop taking its own shortcuts.
/// Both belong to the primary window, and both have to be given it the moment
/// it exists and taken back the moment it is gone.
@MainActor
public final class LinuxViewerWindowRegistry: ViewerWindowRegistry {
    private let environment: LinuxViewerEnvironment
    private weak var primary: WaylandSessionWindow?

    public init(environment: LinuxViewerEnvironment) {
        self.environment = environment
    }

    public func register(_ window: any ViewerSessionWindow) {
        guard let window = window as? WaylandSessionWindow, window.surfaceID == 0 else { return }
        primary = window
        window.shortcutInterceptor = environment.shortcutInterceptor
        environment.shortcutInhibit.window = window
        environment.pasteboardBox.set(window.pasteboard)
    }

    public func unregister(_ window: any ViewerSessionWindow) {
        guard let window = window as? WaylandSessionWindow, window === primary else { return }
        primary = nil
        environment.shortcutInhibit.window = nil
        environment.pasteboardBox.set(nil)
    }
}
#endif

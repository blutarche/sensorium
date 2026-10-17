#if canImport(CGtk4) && canImport(CWayland) && canImport(CEGL) && canImport(CAVCodec)
import Foundation
import SensoriumCore

/// Builds the Linux session windows: one Wayland surface per canvas, decoding
/// through libavcodec.
@MainActor
public final class LinuxSessionWindowFactory: SessionWindowFactory {
    private let tracesPresentation: Bool
    private let pinMemoryStore: any ShortcutStripPinMemoryStoring

    /// `tracesPresentation` is `--trace`, which the viewer already takes for
    /// its latency trace file: a run asking for one wants the picture's own
    /// running counts too.
    ///
    /// `pinMemoryStore` is where the shortcut strip's pin is kept, shared by
    /// every window so a pin chosen in one holds in the next.
    public init(
        tracesPresentation: Bool = false,
        pinMemoryStore: any ShortcutStripPinMemoryStoring = InMemoryShortcutStripPinMemoryStore()
    ) {
        self.tracesPresentation = tracesPresentation
        self.pinMemoryStore = pinMemoryStore
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
            pinMemoryStore: pinMemoryStore,
            makeDecoder: AVCodecVideoDecoder.factory
        )
        // The compositor's own close control ends the session, the same way
        // the macOS window's red button does. The window is not torn down
        // under a session that is still live.
        window.onClosed = { [weak window] in window?.chrome.onCloseRequested?() }
        // What every strip confirmation and every tooltip names: the machine
        // being worked on, not the one this viewer runs on.
        window.setChromeHostName(hostName)
        window.shortcutMode = shortcutMode
        if tracesPresentation {
            WaylandSessionTrace(window: window).start()
        }
        return window
    }
}

/// What else on this platform has to know which session windows exist: the
/// clipboard a session asked for before any window was open, and the
/// interceptor that asks the compositor to stop taking its own shortcuts.
/// The clipboard belongs to the primary window alone. The interceptor is the
/// primary window's, and every other window gets one of its own that acts for
/// the same session, since the compositor inhibits shortcuts per surface.
/// Each has to be given its window the moment it exists and taken back the
/// moment it is gone.
@MainActor
public final class LinuxViewerWindowRegistry: ViewerWindowRegistry {
    private let environment: LinuxViewerEnvironment
    private weak var primary: WaylandSessionWindow?
    private var windows: [WeakSessionWindow] = []
    /// The interceptors of the windows after the primary. A window refers to
    /// its interceptor weakly, so they are kept here until the window goes.
    private var secondaryInterceptors: [ObjectIdentifier: WaylandShortcutInterceptor] = [:]
    /// The app menu's own items, chosen in any session window.
    public var onApplicationCommand: ((ViewerMenuCommand) -> Void)?

    public init(environment: LinuxViewerEnvironment) {
        self.environment = environment
    }

    public func register(_ window: any ViewerSessionWindow) {
        guard let window = window as? WaylandSessionWindow else { return }
        windows.append(WeakSessionWindow(window: window))
        window.onMenuCommand = { [weak self] in self?.onApplicationCommand?($0) }
        guard window.surfaceID == 0 else {
            let interceptor = WaylandShortcutInterceptor(inhibiting: window, leader: environment.shortcutInterceptor)
            secondaryInterceptors[ObjectIdentifier(window)] = interceptor
            window.shortcutInterceptor = interceptor
            return
        }
        primary = window
        window.shortcutInterceptor = environment.shortcutInterceptor
        environment.shortcutInhibit.window = window
        environment.pasteboardBox.set(window.pasteboard)
    }

    public func unregister(_ window: any ViewerSessionWindow) {
        windows.removeAll { $0.window == nil || $0.window === window }
        if let window = window as? WaylandSessionWindow {
            secondaryInterceptors.removeValue(forKey: ObjectIdentifier(window))
        }
        guard let window = window as? WaylandSessionWindow, window === primary else { return }
        primary = nil
        environment.shortcutInhibit.window = nil
        environment.pasteboardBox.set(nil)
    }

    /// Hide's half for the session windows.
    public func minimizeSessionWindows() {
        for entry in windows {
            entry.window?.performMenuCommand(.minimize)
        }
    }
}

private struct WeakSessionWindow {
    weak var window: WaylandSessionWindow?
}
#endif

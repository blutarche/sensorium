#if os(Linux)
import Foundation

/// Why the indicator could not be shown. A host that cannot show it must not
/// stream the screen, so each case names what the person at the host would
/// have to change.
public enum IndicatorError: Error, Equatable, CustomStringConvertible, Sendable {
    /// There is no Wayland display to connect to.
    case noDisplay(String)
    /// The compositor does not offer `zwlr_layer_shell_v1`, so nothing can be
    /// drawn above other windows. GNOME's compositor is one such.
    case layerShellUnavailable
    /// The compositor lacks a core global the pill is drawn through.
    case compositorIncomplete(String)
    /// The compositor reports no outputs, so there is nowhere to show the pill.
    case noOutputs
    /// The compositor closed a pill surface, or did not configure it.
    case surfaceRefused

    public var description: String {
        switch self {
        case .noDisplay(let reason):
            return "The live-session indicator cannot connect to the display: \(reason)"
        case .layerShellUnavailable:
            return "This desktop cannot show the live-session indicator: its compositor has no layer shell."
        case .compositorIncomplete(let missing):
            return "This desktop cannot show the live-session indicator: its compositor offers no \(missing)."
        case .noOutputs:
            return "The live-session indicator has no screen to appear on."
        case .surfaceRefused:
            return "The desktop refused to show the live-session indicator."
        }
    }
}

/// One of the pill's two surfaces: the layer-shell corner pill, or the tray
/// item. `LinuxHostIndicator` drives both through this, and a test drives it
/// with a recording stand-in.
@MainActor
public protocol IndicatorPresenting: AnyObject {
    /// Called when the person at the host asks to stop. May be called from any
    /// event, at most once per `present`.
    var onStop: (() -> Void)? { get set }
    func present(deviceName: String) throws
    func dismiss()
}

/// The live-session indicator of the Linux host.
///
/// While a host-screen session is live, a corner pill on every output and a
/// tray item name the connected device and carry a Stop control. The pill is
/// required: if it cannot be shown `show` throws, and the session is refused
/// before any frame leaves. The tray item is a second place to stop from and
/// is best effort, because a desktop may have no tray at all.
///
/// The shape matches the macOS host's badge: `show(deviceName:)`, `hide()` and
/// an `onStop` callback.
@MainActor
public final class LinuxHostIndicator {
    /// Called once per `show` when either control is used. The session is not
    /// ended by the indicator itself; whoever owns the session ends it.
    public var onStop: (() -> Void)?

    private let pill: any IndicatorPresenting
    private let tray: any IndicatorPresenting
    private var isShowing = false
    private var stopped = false

    /// The real indicator: layer-shell pill and StatusNotifierItem tray entry.
    public convenience init(appearance: IndicatorAppearance = .dark) {
        self.init(pill: LayerShellPillPresenter(appearance: appearance), tray: StatusNotifierTrayPresenter())
    }

    /// An indicator over any two surfaces, for a test to stand in for the
    /// compositor and the bus.
    public init(pill: any IndicatorPresenting, tray: any IndicatorPresenting) {
        self.pill = pill
        self.tray = tray
        pill.onStop = { [weak self] in self?.stopRequested() }
        tray.onStop = { [weak self] in self?.stopRequested() }
    }

    /// Shows the indicator for `deviceName`. Throws when the pill cannot be
    /// shown, leaving nothing on screen.
    public func show(deviceName: String) throws {
        hide()
        stopped = false
        try pill.present(deviceName: deviceName)
        do {
            try tray.present(deviceName: deviceName)
        } catch {
            print("Sensorium: the tray item could not be shown: \(error)")
        }
        isShowing = true
    }

    public func hide() {
        guard isShowing else { return }
        isShowing = false
        tray.dismiss()
        pill.dismiss()
    }

    private func stopRequested() {
        guard isShowing, !stopped else { return }
        stopped = true
        onStop?()
    }
}
#endif

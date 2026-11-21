#if os(Linux)
import SensoriumHost

/// The live-session indicator as the shared host's accountable media sees
/// it. `show()` throws when the pill cannot be shown, so the session is
/// refused before any frame exists, and the indicator's Stop is the badge's
/// Stop.
@MainActor
public final class LinuxIndicatorBadge: HostScreenBadgeDisplaying {
    private let state: HostScreenBadgeState
    private let indicator: LinuxHostIndicator

    /// `indicator` belongs to this one session: hiding it must never take
    /// down another session's pill.
    public init(state: HostScreenBadgeState, indicator: LinuxHostIndicator) {
        self.state = state
        self.indicator = indicator
    }

    public func show() throws {
        let state = state
        indicator.onStop = { state.stopTapped() }
        try indicator.show(deviceName: state.content.deviceName)
    }

    public func hide() {
        indicator.hide()
    }
}
#endif

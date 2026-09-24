import Foundation
import SensoriumCore

/// Everything the session window's chrome is showing, as one value.
///
/// A Wayland session window draws four things over the picture -- the status
/// panel, the transient notice, the diagnostics panel and the shortcut strip
/// -- and which of them is on screen is decided here rather than by the
/// window, so the whole sequence a session goes through is verifiable without
/// a compositor. Nothing here decides any words: they arrive already decided
/// from `ViewerSessionStateMachine`, `SessionHUDPanel` and the host's own
/// refusals.
///
/// Every method that could start a timer is handed the time to judge against,
/// the way `ShortcutStripModel` already is, so a hide delay is checked without
/// waiting for one.
public struct SessionChromeState: Equatable, Sendable {
    public private(set) var status: ViewerSessionStatus?
    public private(set) var strip = ShortcutStripModel()
    public private(set) var telemetry: SessionHUDSnapshot?
    public private(set) var isDiagnosticsVisible = false
    public private(set) var transientNotice: String?
    private var noticeExpiresAt: TimeInterval?
    public var controls = SessionControlsWindowModel()

    public init(isStripPinned: Bool = false) {
        strip = ShortcutStripModel(isPinned: isStripPinned)
    }

    /// When `tick(now:)` next has something to do -- the earlier of the
    /// strip's own deadline and the notice's. `nil` when neither is waiting,
    /// so a live video window wakes exactly once rather than polling.
    public var nextDeadline: TimeInterval? {
        [strip.nextDeadline, noticeExpiresAt].compactMap { $0 }.min()
    }

    public var isStatusPanelVisible: Bool { status?.isOverlayVisible ?? false }
    public var isStripVisible: Bool { strip.isVisible }
    public var isHandleVisible: Bool { strip.showsHandle }
    public var isNoticeVisible: Bool { notice != nil }

    /// The one line the notice overlay draws.
    public var notice: String? { transientNotice }

    public mutating func apply(status: ViewerSessionStatus, now: TimeInterval) {
        self.status = status
        strip.phaseChanged(status.phase, now: now)
    }

    public mutating func apply(telemetry: SessionHUDSnapshot) {
        self.telemetry = telemetry
    }

    /// The diagnostics panel's rows, as the shared model builds them from
    /// what this window last heard. Empty before any telemetry has arrived.
    public var diagnosticsBlocks: [SessionHUDBlock] {
        guard let telemetry else { return [] }
        return SessionHUDPanel.blocks(telemetry: telemetry, session: status)
    }

    public mutating func toggleDiagnosticsRequested() {
        isDiagnosticsVisible.toggle()
    }

    public mutating func toggleStripRequested(now: TimeInterval) {
        strip.toggleRequested()
        _ = now
    }

    public mutating func pointerOverHandle(_ isOver: Bool, now: TimeInterval) {
        strip.pointerOverHandle(isOver, now: now)
    }

    public mutating func pointerOverStrip(_ isOver: Bool, now: TimeInterval) {
        strip.pointerOverStrip(isOver, now: now)
    }

    public mutating func handleClicked() {
        strip.handleClicked()
    }

    public mutating func pressStrip(_ action: ShortcutStripAction) -> ShortcutStripPress? {
        strip.press(action)
    }

    public mutating func confirmPendingStripAction() -> ShortcutStripAction? {
        strip.confirmPending()
    }

    public mutating func cancelPendingStripAction() {
        strip.cancelPending()
    }

    public mutating func togglePinRequested(now: TimeInterval) {
        strip.togglePinRequested(now: now)
    }

    public mutating func escapePressed() -> Bool {
        strip.escapePressed()
    }

    /// One sentence about a request that did not go through, over a session
    /// that is otherwise fine. It takes itself away on its own.
    public mutating func showNotice(_ line: String, now: TimeInterval) {
        transientNotice = line
        noticeExpiresAt = now + WaylandOverlayLayout.noticeAutoDismissSeconds
    }

    public mutating func dismissNotice() {
        transientNotice = nil
        noticeExpiresAt = nil
    }

    public mutating func tick(now: TimeInterval) {
        strip.tick(now: now)
        if let expiry = noticeExpiresAt, now >= expiry {
            dismissNotice()
        }
    }
}

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
    private var tooltip = ShortcutStripTooltip()
    public var controls = SessionControlsWindowModel()

    public init(isStripPinned: Bool = false) {
        strip = ShortcutStripModel(isPinned: isStripPinned)
    }

    /// A chrome whose strip starts as the person last left it.
    public init(pinMemoryStore: any ShortcutStripPinMemoryStoring) {
        self.init(isStripPinned: pinMemoryStore.isPinned())
    }

    /// When `tick(now:)` next has something to do -- the earliest of the
    /// strip's own deadline, the notice's and a tooltip's. `nil` when none is
    /// waiting, so a live video window wakes exactly once rather than polling.
    public var nextDeadline: TimeInterval? {
        [strip.nextDeadline, noticeExpiresAt, tooltip.deadline].compactMap { $0 }.min()
    }

    /// The strip item whose tooltip is on screen: the one the pointer has
    /// rested on for `ShortcutStripTooltip.delaySeconds`.
    public var stripTooltip: ShortcutStripTooltipTarget? { tooltip.shown }

    public var isStatusPanelVisible: Bool { status?.isOverlayVisible ?? false }
    /// Whether a scrim belongs behind the status panel -- shown for every
    /// phase the panel itself is up for, opaque or translucent alike; see
    /// `isScrimOpaque`.
    public var isScrimVisible: Bool { isStatusPanelVisible }
    /// Whether that scrim is the opaque fill or the translucent one -- the
    /// same rule `ViewerSessionStatusOverlay` uses on macOS: opaque while
    /// there is no picture underneath yet, translucent once a frozen picture
    /// needs marking as stale (`status.dimsCanvas`).
    public var isScrimOpaque: Bool { isStatusPanelVisible && !(status?.dimsCanvas ?? false) }
    public var isStripVisible: Bool { strip.isVisible }
    public var isHandleVisible: Bool { strip.showsHandle }
    public var isNoticeVisible: Bool { notice != nil }

    /// The one line the notice overlay draws.
    public var notice: String? { transientNotice }

    public mutating func apply(status: ViewerSessionStatus, now: TimeInterval) {
        self.status = status
        strip.phaseChanged(status.phase, now: now)
        settleTooltip()
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
        settleTooltip()
    }

    public mutating func pointerOverHandle(_ isOver: Bool, now: TimeInterval) {
        strip.pointerOverHandle(isOver, now: now)
        settleTooltip()
    }

    public mutating func pointerOverStrip(_ isOver: Bool, now: TimeInterval) {
        strip.pointerOverStrip(isOver, now: now)
        settleTooltip()
    }

    /// The strip item under the pointer, or `nil` when the pointer is on none
    /// of them. An item that is not on screen right now has no tooltip.
    public mutating func pointerRests(onTooltipTarget target: ShortcutStripTooltipTarget?, now: TimeInterval) {
        tooltip.pointerRests(on: target.flatMap { isOnScreen($0) ? $0 : nil }, now: now)
    }

    /// The pointer is somewhere on the open strip. The open strip hides the
    /// handle, but the handle's spot stays the pointer's way in: a pointer
    /// resting on it is not one that left, so a strip closed by Escape or the
    /// chord stays closed as the handle comes back up under the pointer rather
    /// than opening again at once. `ShortcutStripView` makes the same
    /// judgement on macOS.
    public mutating func pointerOnStrip(isOnHandleSpot: Bool, now: TimeInterval) {
        strip.pointerOverHandle(isOnHandleSpot && strip.isHandleVisible, now: now)
        strip.pointerOverStrip(true, now: now)
        settleTooltip()
    }

    /// The pointer left the open strip for the picture or another overlay,
    /// which takes the handle's spot with it.
    public mutating func pointerLeftStrip(now: TimeInterval) {
        strip.pointerOverHandle(false, now: now)
        strip.pointerOverStrip(false, now: now)
        settleTooltip()
    }

    public mutating func handleClicked() {
        tooltip.pressed()
        strip.handleClicked()
        settleTooltip()
    }

    public mutating func pressStrip(_ action: ShortcutStripAction) -> ShortcutStripPress? {
        tooltip.pressed()
        defer { settleTooltip() }
        return strip.press(action)
    }

    public mutating func confirmPendingStripAction() -> ShortcutStripAction? {
        tooltip.pressed()
        defer { settleTooltip() }
        return strip.confirmPending()
    }

    public mutating func cancelPendingStripAction() {
        tooltip.pressed()
        strip.cancelPending()
        settleTooltip()
    }

    public mutating func togglePinRequested(now: TimeInterval) {
        tooltip.pressed()
        strip.togglePinRequested(now: now)
        settleTooltip()
    }

    /// The pin button: toggles the pin and writes the result to `store`, so
    /// the next session starts the same way.
    public mutating func togglePinRequested(now: TimeInterval, remembering store: any ShortcutStripPinMemoryStoring) {
        togglePinRequested(now: now)
        store.remember(isPinned: strip.isPinned)
    }

    public mutating func escapePressed() -> Bool {
        defer { settleTooltip() }
        return strip.escapePressed()
    }

    public mutating func stripPointerPressed() {
        tooltip.pressed()
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
        settleTooltip()
        tooltip.tick(now: now)
    }

    /// Forgets the item under the pointer once it has left the screen -- the
    /// strip closed, a question replaced its actions, or the open strip
    /// covered the handle -- so its tooltip neither stays up over nothing nor
    /// comes back without a fresh rest.
    private mutating func settleTooltip() {
        guard let hovered = tooltip.hovered, !isOnScreen(hovered) else { return }
        tooltip = ShortcutStripTooltip()
    }

    private func isOnScreen(_ target: ShortcutStripTooltipTarget) -> Bool {
        switch target {
        case .action:
            if case .confirming = strip.visibility { return false }
            return strip.isVisible
        case .pin:
            return strip.isVisible
        case .handle:
            return strip.showsHandle
        }
    }
}

/// When a strip tooltip is on screen. Reads no clock, like
/// `ShortcutStripModel`: every call is handed the time to judge against.
public struct ShortcutStripTooltip: Equatable, Sendable {
    /// How long the pointer rests on one item before its tooltip appears.
    public static let delaySeconds: TimeInterval = 0.5

    /// The item under the pointer, whether or not its tooltip shows yet.
    private(set) var hovered: ShortcutStripTooltipTarget?
    private(set) var shown: ShortcutStripTooltipTarget?
    /// When `hovered`'s tooltip is due.
    private(set) var deadline: TimeInterval?
    /// Set by a press and cleared when the pointer moves to another item, so
    /// a tooltip does not come back over a button that was just used.
    private var isSuppressed = false

    public init() {}

    /// Moving to another item, or off them all, starts the wait again.
    mutating func pointerRests(on target: ShortcutStripTooltipTarget?, now: TimeInterval) {
        guard target != hovered else { return }
        hovered = target
        shown = nil
        isSuppressed = false
        deadline = target == nil ? nil : now + Self.delaySeconds
    }

    mutating func pressed() {
        shown = nil
        deadline = nil
        isSuppressed = true
    }

    mutating func tick(now: TimeInterval) {
        guard let due = deadline, now >= due else { return }
        deadline = nil
        if !isSuppressed {
            shown = hovered
        }
    }
}

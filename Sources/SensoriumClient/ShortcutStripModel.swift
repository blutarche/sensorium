import Foundation

/// What the strip is doing right now. `hiding` is a state of its own rather
/// than a boolean plus a timer, so the delay is verifiable against a clock the
/// caller supplies instead of a real one.
public enum ShortcutStripVisibility: Equatable, Sendable {
    case hidden
    case shown
    case hiding
    /// The row has been replaced by one question about a disruptive shortcut.
    case confirming(ShortcutStripAction)
}

/// What a press means: fire now, or ask first. Asking names no action, because
/// the question the strip is holding is already its own visibility.
public enum ShortcutStripPress: Equatable, Sendable {
    case send(ShortcutStripAction)
    case askToConfirm
}

/// When the shortcut strip is on screen, and what a press of one of its buttons
/// does. Holds no view and reads no clock -- every method is handed the time it
/// should judge against -- so the hide delay is verified without a window and
/// without waiting.
///
/// The strip covers the top of a window whose whole point is the picture
/// underneath, so all a live session leaves on screen is the handle: a small
/// tab that opens the strip when it is hovered or clicked. Only the handle
/// opens it, and only while there is a live session to send input to.
public struct ShortcutStripModel: Equatable, Sendable {
    /// Long enough that a pointer slipping off the strip on its way to a button
    /// does not have it vanish underneath.
    public static let hideDelaySeconds: Double = 1

    public private(set) var visibility: ShortcutStripVisibility = .hidden
    private var phase: ViewerSessionPhase
    private var isOverHandle = false
    private var isOverStrip = false
    /// Set when the strip is closed deliberately while the pointer is still on
    /// the handle, and cleared when the pointer leaves it. Without it, the
    /// click that closes the strip is followed at once by a hover that opens
    /// it again, and the strip cannot be closed by clicking at all.
    private var isHoverSuppressed = false
    /// When `tick(now:)` next has something to do. Public so a caller can wake
    /// exactly once at that moment rather than polling a live video window.
    public private(set) var nextDeadline: TimeInterval?
    /// The question the strip is holding, kept across a hide that has started
    /// but not finished: a pointer that slips off and comes straight back finds
    /// what it left. Cleared the moment the strip is actually closed.
    private var pendingConfirmation: ShortcutStripAction?
    /// Set by the strip's own pin button, and by nothing else. While it holds,
    /// the pointer leaving the strip or the handle is not a reason to hide --
    /// only the summoning chord and Escape still close a pinned strip.
    public private(set) var isPinned: Bool

    public init(phase: ViewerSessionPhase = .connecting, isPinned: Bool = false) {
        self.phase = phase
        self.isPinned = isPinned
        // A pin remembered from a previous session must not need a hover to
        // take effect again: the strip starts already open, and only the
        // pin toggle, the chord or Escape can close it from here.
        if isPinned {
            visibility = .shown
        }
    }

    public var isVisible: Bool {
        visibility != .hidden
    }

    /// The one mark a live session leaves on the picture. There is nothing to
    /// send shortcuts to otherwise, so there is nothing to offer either.
    public var isHandleVisible: Bool {
        phase == .live
    }

    /// Whether the hover handle pill itself draws. Hidden while a pinned
    /// strip is shown -- pinning already found the strip without it, and a
    /// hover target sitting uselessly atop an already-open strip is only
    /// clutter -- and on the same terms as `isHandleVisible` otherwise, so an
    /// unpinned session or a pinned one Escape just closed still gets it back.
    public var showsHandle: Bool {
        isHandleVisible && !(isPinned && isVisible)
    }

    /// Hovering the handle opens the strip at once. The handle is a visible
    /// target, so a pointer resting on it is already the deliberate approach
    /// that a delay would otherwise have been proving.
    public mutating func pointerOverHandle(_ isOver: Bool, now: TimeInterval) {
        guard isOverHandle != isOver else { return }
        isOverHandle = isOver
        if !isOver {
            isHoverSuppressed = false
        }
        pointerEngagementChanged(now: now)
    }

    public mutating func pointerOverStrip(_ isOver: Bool, now: TimeInterval) {
        guard isOverStrip != isOver else { return }
        isOverStrip = isOver
        pointerEngagementChanged(now: now)
    }

    /// A click on the handle: the way in for a pointer that arrived by
    /// clicking, and the way out for one that is already there.
    public mutating func handleClicked() {
        toggle()
    }

    /// The viewer-local chord that summons the strip without the pointer.
    public mutating func toggleRequested() {
        toggle()
    }

    /// A strip on its way out is on its way out, not on screen: asking for it
    /// during that second brings it back, rather than closing what is already
    /// closing and leaving the ask with nothing to show for it.
    private mutating func toggle() {
        guard phase == .live else { return }
        switch visibility {
        case .hidden, .hiding:
            open()
        case .shown, .confirming:
            closeDeliberately()
        }
    }

    /// Escape closes an open strip the pointer is in, and reports that it did.
    /// Anywhere else it is an ordinary keystroke the machine being worked on is
    /// entitled to, and the caller passes it on.
    public mutating func escapePressed() -> Bool {
        guard phase == .live, isVisible, isOverStrip || isOverHandle else { return false }
        closeDeliberately()
        return true
    }

    /// The strip sends input to a machine, so a session that is not live takes
    /// it away at once rather than leaving buttons over a frozen picture.
    public mutating func phaseChanged(_ phase: ViewerSessionPhase, now: TimeInterval) {
        self.phase = phase
        guard phase != .live else { return }
        // Neither the strip nor the handle is on screen, so no mouse-exit will
        // ever arrive for either one.
        isOverHandle = false
        isOverStrip = false
        isHoverSuppressed = false
        // A pinned strip is a lifecycle event's business only to the extent
        // above: it is never the reason one closes. Connecting, reconnecting,
        // losing the session and a fresh live canvas all pass through here,
        // and none of them may take a pin away -- only the pin button, the
        // chord or Escape do that.
        guard !isPinned else { return }
        hideNow()
    }

    public mutating func tick(now: TimeInterval) {
        guard let deadline = nextDeadline, now >= deadline else { return }
        nextDeadline = nil
        switch visibility {
        case .hiding:
            hideNow()
        case .hidden, .shown, .confirming:
            break
        }
    }

    /// Nothing happens on a strip nobody can see: a press can only have come
    /// from a button that is on screen.
    public mutating func press(_ action: ShortcutStripAction) -> ShortcutStripPress? {
        guard phase == .live, isVisible else { return nil }
        guard action.needsConfirmation else {
            return .send(action)
        }
        pendingConfirmation = action
        visibility = .confirming(action)
        nextDeadline = nil
        return .askToConfirm
    }

    /// The person answered the question. The action comes back exactly once.
    public mutating func confirmPending() -> ShortcutStripAction? {
        guard case let .confirming(action) = visibility else { return nil }
        pendingConfirmation = nil
        visibility = .shown
        return action
    }

    public mutating func cancelPending() {
        guard case .confirming = visibility else { return }
        pendingConfirmation = nil
        visibility = .shown
    }

    /// The strip's own pin button. Flipping it re-runs the same pointer
    /// judgement that a hover would: pinning a strip the pointer has already
    /// left changes nothing until the pointer moves again, and unpinning one
    /// the pointer has already left starts the ordinary hide at once rather
    /// than waiting for a motion event that may never come.
    public mutating func togglePinRequested(now: TimeInterval) {
        isPinned.toggle()
        pointerEngagementChanged(now: now)
    }

    private mutating func pointerEngagementChanged(now: TimeInterval) {
        guard phase == .live else { return }
        if isOverHandle || isOverStrip {
            switch visibility {
            case .hidden:
                // The strip itself never opens on a hover: while it is closed
                // there is nothing of it under the pointer but the handle.
                guard isOverHandle, !isHoverSuppressed else { return }
                open()
            case .hiding:
                visibility = pendingConfirmation.map(ShortcutStripVisibility.confirming) ?? .shown
                nextDeadline = nil
            case .shown, .confirming:
                break
            }
        } else {
            // A pinned strip stays up regardless of where the pointer is; only
            // the chord and Escape reach it, and both close it directly rather
            // than through this path.
            guard !isPinned else { return }
            switch visibility {
            case .shown, .confirming:
                visibility = .hiding
                nextDeadline = now + Self.hideDelaySeconds
            case .hidden, .hiding:
                break
            }
        }
    }

    private mutating func open() {
        visibility = pendingConfirmation.map(ShortcutStripVisibility.confirming) ?? .shown
        nextDeadline = nil
    }

    /// Closed by a click, the chord or Escape, rather than by the pointer
    /// wandering off: immediate, and with no hide delay to reverse.
    private mutating func closeDeliberately() {
        hideNow()
        // There is no strip left to be over, so a belief that the pointer is
        // over one must not outlive it. The handle is still there, and a
        // pointer resting on it is what the suppression is for.
        isOverStrip = false
        isHoverSuppressed = isOverHandle
    }

    private mutating func hideNow() {
        visibility = .hidden
        nextDeadline = nil
        pendingConfirmation = nil
    }
}

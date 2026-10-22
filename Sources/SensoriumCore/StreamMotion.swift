import Foundation

/// Decides, one captured change at a time, whether the picture is moving or
/// settled, so the host can encode a moving picture smaller and a settled one
/// at the size the viewer asked for.
///
/// Encode time grows with the pixels in a frame, and while a person scrolls or
/// drags every frame changes. A smaller frame is ready sooner and more of them
/// fit in a second, which is worth more then than detail nobody can read in
/// motion. Once the picture stops, the detail is what matters again.
///
/// Each change of mode costs the viewer a key frame, so motion has to be shown
/// rather than guessed: a run of broad changes close together, or a broad
/// change right after the viewer scrolled or dragged. A change that covers
/// little of the screen, a caret or a spinner, is neither evidence of motion
/// nor a reason to stay in it.
///
/// Pure and clock-injected: every call carries its own time, so the whole rule
/// is testable as arithmetic. One instance per stream.
public struct StreamMotionDetector: Sendable {
    public enum Mode: Equatable, Sendable {
        case settled
        case moving
    }

    /// How long the screen has to go without a broad change before a moving
    /// picture is sent at full size again. Long enough that the pause between
    /// two flicks of a scroll does not cost two key frames, short enough that
    /// a page someone stopped on to read is sharp before they have found
    /// their place on it.
    public static let settleSeconds = 0.5
    /// How soon after a viewer scroll or drag a broad change counts as its
    /// answer. A host app redraws within a frame or two of the input it is
    /// given, and a change much later than that is something else.
    public static let interactionWindowSeconds = 0.25
    /// How many broad changes in a row, each within
    /// `continuousChangeGapSeconds` of the last, are motion when the viewer
    /// sent no input that explains them: an animation, a video, a window the
    /// host itself is moving.
    public static let continuousChangeCount = 4
    /// The longest gap inside a run of changes: 20 frames a second. Typing,
    /// clicking and most of what a person does at a keyboard changes the
    /// screen less often than this.
    public static let continuousChangeGapSeconds = 0.05
    /// The share of the frame a change has to cover to count. Below it, the
    /// change is a small part of a screen that is otherwise still, and
    /// softening the whole picture for it would cost the rest of the screen
    /// its detail for nothing.
    public static let broadChangeFraction = 0.1

    public private(set) var mode = Mode.settled
    private var lastInteractionSeconds: Double?
    private var lastBroadChangeSeconds: Double?
    private var runLength = 0

    public init() {}

    /// The viewer scrolled, or moved the pointer with a button held. Nothing
    /// on screen has changed because of it yet, so the picture does not
    /// change either; the change it causes is what starts motion.
    public mutating func viewerInteracted(atSeconds: Double) {
        lastInteractionSeconds = atSeconds
    }

    /// One captured change, covering `changedFraction` of the frame, or `nil`
    /// when capture did not say how much changed. An unknown extent counts as
    /// the whole frame, the same way capture treats a frame it cannot read
    /// the change list of as a change.
    ///
    /// Returns the mode this change is encoded in.
    @discardableResult
    public mutating func screenChanged(atSeconds: Double, changedFraction: Double?) -> Mode {
        guard (changedFraction ?? 1) >= Self.broadChangeFraction else {
            return mode
        }
        if let lastBroadChangeSeconds, atSeconds - lastBroadChangeSeconds <= Self.continuousChangeGapSeconds {
            runLength += 1
        } else {
            runLength = 1
        }
        lastBroadChangeSeconds = atSeconds
        if mode == .settled {
            let answersInput = lastInteractionSeconds.map {
                atSeconds - $0 >= 0 && atSeconds - $0 <= Self.interactionWindowSeconds
            } ?? false
            if answersInput || runLength >= Self.continuousChangeCount {
                mode = .moving
            }
        }
        return mode
    }

    /// When a moving picture is due back at full size if nothing broad changes
    /// before then. `nil` while settled.
    public var settleDeadlineSeconds: Double? {
        guard mode == .moving, let lastBroadChangeSeconds else {
            return nil
        }
        return lastBroadChangeSeconds + Self.settleSeconds
    }

    /// Settles the picture if its deadline has passed. Answers whether it did,
    /// which is the one moment the full-size picture has to be sent: nothing
    /// is changing, so no captured frame will send it.
    @discardableResult
    public mutating func settleIfDue(atSeconds: Double) -> Bool {
        guard let deadline = settleDeadlineSeconds, atSeconds >= deadline else {
            return false
        }
        mode = .settled
        // A run broken by a whole settle delay is over: the next motion has
        // to show itself again rather than inherit this one.
        runLength = 0
        return true
    }
}

/// Reads the viewer's input for the input that moves the picture: a scroll, or
/// the pointer moving with a button held, which is a drag. Hovering, clicking
/// and typing change little of the screen, and the picture stays sharp for
/// them.
///
/// It follows the buttons itself rather than asking the host which are down,
/// so one instance has to see every input event of one stream, in order.
public struct StreamMotionInput: Sendable {
    private var heldButtons = Set<CanvasPointerButton>()

    public init() {}

    public mutating func isMotion(_ event: SensoriumInputEvent) -> Bool {
        switch event {
        case .scrolled:
            return true
        case .pointerMoved, .pointerMovedRelative:
            return !heldButtons.isEmpty
        case .pointerButton(let button, let isDown, _, _):
            if isDown {
                heldButtons.insert(button)
            } else {
                heldButtons.remove(button)
            }
            return false
        case .releaseAllInput:
            heldButtons.removeAll()
            return false
        case .key, .pointerCaptureChanged:
            return false
        }
    }
}

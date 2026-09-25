import CoreGraphics
import Foundation

/// How long it has been since there was local input at this machine -- or that
/// this could not be told. Never a bare `TimeInterval`: a reading that could
/// not be taken has to stay distinguishable from a genuinely long idle time,
/// because the two call for opposite outcomes in `HostScreenPresenceRule` --
/// a broken sensor must never silently read as nobody being home.
public enum HostLocalActivityReading: Equatable, Sendable {
    case idleFor(TimeInterval)
    case unavailable
}

/// Behind a protocol so every consumer -- `HostScreenPresenceRule` here, and
/// the local-activity input-pause policy elsewhere, which reuses the same
/// reading -- can be tested against a controlled fake instead of whatever
/// happens to be true on the machine running the test.
public protocol HostLocalActivitySignal: Sendable {
    func currentReading() -> HostLocalActivityReading
}

/// The one place `CGEventSource.secondsSinceLastEventType` is called.
/// Deliberately thin -- everything that decides what a reading *means*
/// lives in `HostScreenPresenceRule`, not here.
public final class CoreGraphicsLocalActivitySignal: HostLocalActivitySignal {
    private let secondsSinceLastEvent: @Sendable (CGEventSourceStateID, CGEventType) -> Double

    public convenience init() {
        self.init(secondsSinceLastEvent: {
            CGEventSource.secondsSinceLastEventType($0, eventType: $1)
        })
    }

    /// Which state ID and event type this asks about decide whether the
    /// whole host-presence rule works, and CoreGraphics answers that
    /// question on a real machine only. This seam is what lets a test read
    /// the question instead of the answer.
    public init(secondsSinceLastEvent: @escaping @Sendable (CGEventSourceStateID, CGEventType) -> Double) {
        self.secondsSinceLastEvent = secondsSinceLastEvent
    }

    /// `kCGAnyInputEventType`, which CoreGraphics exposes to Swift under no
    /// name of its own. `CGEventType.null` is not a stand-in for it: nothing
    /// ever posts a null event, so asking about one answers with the time
    /// since this machine booted, which reports nobody home however hard
    /// somebody is typing.
    public static let anyInputEventType = CGEventType(rawValue: ~0)!

    /// Input this host posts can reset this counter too: a key event posted
    /// at `.cgSessionEventTap` reset it on a real host, as a post at
    /// `.cghidEventTap` does. Every post is therefore recorded, and
    /// `SelfPostDiscountingLocalActivitySignal` reads this signal for the
    /// relock decision, so those posts are never mistaken there for a real
    /// person. The ask-first presence gate reads this signal raw instead --
    /// see `HostScreenActivitySignals`.
    public static let sourceStateID: CGEventSourceStateID = .hidSystemState

    public func currentReading() -> HostLocalActivityReading {
        let seconds = secondsSinceLastEvent(Self.sourceStateID, Self.anyInputEventType)
        guard seconds.isFinite, seconds >= 0 else {
            return .unavailable
        }
        return .idleFor(seconds)
    }
}

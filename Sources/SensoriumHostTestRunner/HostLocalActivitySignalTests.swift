import CoreGraphics
import Foundation
import SensoriumHost

/// What the host asks CoreGraphics when it wants to know whether somebody is
/// at this Mac. The design's whole host-presence rule (§6.2) hangs off this
/// one reading: ask the wrong question and the rule silently never fires, so
/// a person actively using their Mac is never asked before their screen is
/// shared -- which is exactly what CLAUDE.md's invariant requires it to do.
@MainActor
func runHostLocalActivitySignalTests() async {
    do {
        // The reading asks about input, not about an event nobody posts
        let requested = RequestedEventQueries()
        let signal = CoreGraphicsLocalActivitySignal(secondsSinceLastEvent: { stateID, eventType in
            requested.record(stateID, eventType)
            return 12
        })
        _ = signal.currentReading()
        expect(
            requested.all().map(\.eventType) == [CGEventType(rawValue: ~0)!],
            "the idle reading asks how long since any input event, the one question that answers 'is somebody here'"
        )
        expect(
            !requested.all().map(\.eventType).contains(.null),
            "it never asks about the null event type, which is never posted and so answers with this machine's uptime"
        )
        expect(
            requested.all().map(\.stateID) == [.hidSystemState],
            "the idle reading asks about hardware input alone (hidSystemState), never combinedSessionState -- that "
                + "counter also resets on this host's own injected remote input (CoreGraphicsInputInjector posts to "
                + ".cgSessionEventTap for exactly this reason), which would make the host believe a person is "
                + "present right after any session with input, unattended or not"
        )

        print("PASS: the host's local-activity reading asks CoreGraphics about hidSystemState input events")
    }

    do {
        // A real reading passes through; an impossible one is not a long idle
        expect(
            CoreGraphicsLocalActivitySignal(secondsSinceLastEvent: { _, _ in 41 }).currentReading() == .idleFor(41),
            "a plain reading is reported as the idle time it is"
        )
        expect(
            CoreGraphicsLocalActivitySignal(secondsSinceLastEvent: { _, _ in -1 }).currentReading() == .unavailable,
            "a negative reading is unavailable, never an idle time"
        )
        expect(
            CoreGraphicsLocalActivitySignal(secondsSinceLastEvent: { _, _ in .nan }).currentReading() == .unavailable,
            "a reading that is not a number is unavailable, never an idle time"
        )

        print("PASS: an unreadable local-activity reading stays distinguishable from a long idle time")
    }
}

/// Every `(stateID, eventType)` pair the signal asked CoreGraphics about,
/// across whatever thread its own reader happens to run on.
private final class RequestedEventQueries: @unchecked Sendable {
    private let lock = NSLock()
    private var queries: [(stateID: CGEventSourceStateID, eventType: CGEventType)] = []

    func record(_ stateID: CGEventSourceStateID, _ eventType: CGEventType) {
        lock.lock()
        defer { lock.unlock() }
        queries.append((stateID, eventType))
    }

    func all() -> [(stateID: CGEventSourceStateID, eventType: CGEventType)] {
        lock.lock()
        defer { lock.unlock() }
        return queries
    }
}

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

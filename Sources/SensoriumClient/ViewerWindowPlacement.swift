import Foundation

/// Where a canvas window goes when it is created.
public enum ViewerWindowPlacement: Equatable, Sendable {
    /// Nothing remembered: put it in the middle of the screen.
    case center
    /// A second canvas that has never been placed: offset from the first, or
    /// it lands exactly on top of it and opening it looks like nothing
    /// happened.
    case cascade
    /// The user has already put this window somewhere; that is where it goes.
    case restoreSaved
}

/// The placement decision, kept apart from AppKit so both halves of it -- a
/// first-ever launch and every launch after it -- are verified without a
/// window.
public enum ViewerWindowPlacementPolicy {
    public static func placement(surfaceID: UInt32, hasSavedFrame: Bool) -> ViewerWindowPlacement {
        if hasSavedFrame {
            return .restoreSaved
        }
        return surfaceID == 0 ? .center : .cascade
    }

    /// One name per canvas, because two windows sharing an autosave name
    /// would restore onto each other.
    public static func frameAutosaveName(surfaceID: UInt32) -> String {
        "SensoriumCanvas.\(surfaceID)"
    }
}

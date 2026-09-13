import SensoriumCore

/// One focus transition worth telling the host about.
public struct ViewerFocusReport: Equatable, Sendable {
    /// The canvas that now has focus, or `nil` when nothing does.
    public let surfaceID: UInt32?
    /// Whether any canvas has focus at all. `false` means the user is working
    /// in a local app; it is not "surface 0".
    public let hasViewerFocus: Bool

    public init(surfaceID: UInt32?, hasViewerFocus: Bool) {
        self.surfaceID = surfaceID
        self.hasViewerFocus = hasViewerFocus
    }
}

/// Turns AppKit's per-window focus notifications into the transitions the host
/// can act on, and nothing else. Repeating a state the host has already been
/// told produces no report: the host only needs to know when focus *moves*,
/// and a message per event would cost more wire than the scheduling it buys.
///
/// Shared by every viewer window in a session, because deduplication is a
/// property of the session's focus, not of one window's.
///
/// Only two inputs, deliberately. A window becoming key says which canvas the
/// user is looking at; the whole application resigning active says the user is
/// looking at neither. A window *resigning* key is not an input: moving from
/// one canvas window to the other resigns the first before the second becomes
/// key, so acting on it would report a "no focus at all" state that never
/// happened, once per window switch.
@MainActor
public final class ViewerFocusReporter {
    private enum ReportedFocus: Equatable {
        case none
        case surface(UInt32)
    }

    private var reported: ReportedFocus?

    public init() {}

    /// Call when a viewer window takes key focus.
    public func viewerWindowDidBecomeKey(surfaceID: UInt32) -> ViewerFocusReport? {
        transition(
            to: .surface(surfaceID),
            report: ViewerFocusReport(surfaceID: surfaceID, hasViewerFocus: true)
        )
    }

    /// Call when the whole viewer application stops being the active one.
    public func viewerDidResignActive() -> ViewerFocusReport? {
        transition(to: .none, report: ViewerFocusReport(surfaceID: nil, hasViewerFocus: false))
    }

    /// Forgets what the host was told. A reconnected session is a host that
    /// has heard nothing, so the next transition must be reported even though
    /// nothing changed on this side.
    public func reset() {
        reported = nil
    }

    private func transition(to focus: ReportedFocus, report: ViewerFocusReport) -> ViewerFocusReport? {
        guard reported != focus else {
            return nil
        }
        reported = focus
        return report
    }
}

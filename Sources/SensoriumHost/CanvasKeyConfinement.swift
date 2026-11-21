import Foundation

/// One on-screen window as the key-confinement scan sees it: which process
/// owns it, and where it stands in the global, top-left-origin coordinate
/// space `CGDisplayBounds` and `kCGWindowBounds` share -- the same space
/// `CanvasWorkspacePlacement.bounds` and `CanvasWindowPlacement` are stated in,
/// so a canvas rectangle and a window rectangle are directly comparable.
public struct ScannedWindow: Equatable, Sendable {
    public let processIdentifier: pid_t
    public let bounds: CGRect

    public init(processIdentifier: pid_t, bounds: CGRect) {
        self.processIdentifier = processIdentifier
        self.bounds = bounds
    }
}

/// What one look at the machine's windows saw: who is frontmost, and every
/// on-screen window at that instant.
public struct FrontmostWindowScan: Equatable, Sendable {
    /// `nil` when no application is frontmost, which the predicate treats
    /// exactly as it treats an application with no windows: a refusal.
    public let frontmostProcessIdentifier: pid_t?
    /// Every on-screen window, at every window layer, not only the frontmost
    /// application's. Filtering happens in the predicate so the filter itself
    /// is asserted rather than assumed.
    public let onScreenWindows: [ScannedWindow]

    public init(frontmostProcessIdentifier: pid_t?, onScreenWindows: [ScannedWindow]) {
        self.frontmostProcessIdentifier = frontmostProcessIdentifier
        self.onScreenWindows = onScreenWindows
    }
}

/// Reads which application currently holds the machine's keyboard and where
/// its windows are.
///
/// Asked once per key and never cached. Any cache lifetime is a leak window:
/// a window moved off the canvas while it still holds the keyboard would keep
/// receiving posted keys until the cache expired, and those keys would land on
/// a physical display. Measured cost of the real implementation is 0.395 ms
/// p50 / 0.479 ms p95 / 3.3 ms max over 49 on-screen windows, against a key
/// repeat interval of roughly 33 ms.
@MainActor
public protocol FrontmostWindowScanning: AnyObject {
    func scan() -> FrontmostWindowScan
}

/// Whether a key may be posted while some application holds the keyboard, and
/// when not, which of the three checks refused.
public enum CanvasKeyConfinementDecision: Equatable, Sendable {
    case allow
    /// This connection owns no workspace window on the addressed surface, so
    /// it has no canvas to confine anything to.
    case rejectUnownedWorkspace
    /// The frontmost application has no on-screen window at all. Vacuously
    /// "nothing outside the canvas", which is exactly the state a
    /// just-activated application is in, so it must refuse rather than pass.
    case rejectNoWindow
    /// At least one of the frontmost application's windows is not wholly
    /// inside the canvas, so a key posted now could land on a physical
    /// display.
    case rejectWindowOutsideCanvas

    /// The short form written to the host log. Never carries key material.
    public var reasonCode: String {
        switch self {
        case .allow: "allowed"
        case .rejectUnownedWorkspace: "unowned-workspace"
        case .rejectNoWindow: "no-window-found"
        case .rejectWindowOutsideCanvas: "window-outside-canvas"
        }
    }
}

/// The geometric half of key confinement: not "is the focused window mine" but
/// "is the focused window on the canvas I own".
///
/// Pure by construction, because this is the decision that stops a remote
/// keystroke from reaching the user's physical monitor and it has to be
/// assertable directly rather than only through AppKit.
public enum CanvasKeyConfinement {
    /// - Parameters:
    ///   - ownsWorkspace: The per-connection owner check, unchanged, as a hard
    ///     AND. Geometry carries no connection identity, so without this a
    ///     dying connection could post into a window a reconnect now owns.
    ///     This check replaces nothing; it is added to.
    ///   - canvasBounds: The owned canvas rectangle. `nil` means the same
    ///     thing `ownsWorkspace: false` means -- nothing owned to confine to.
    ///   - scan: One synchronous look at the machine's windows.
    public static func decide(
        ownsWorkspace: Bool,
        canvasBounds: CGRect?,
        scan: FrontmostWindowScan
    ) -> CanvasKeyConfinementDecision {
        guard ownsWorkspace, let canvasBounds else {
            return .rejectUnownedWorkspace
        }
        let frontmost = scan.onScreenWindows.filter {
            $0.processIdentifier == scan.frontmostProcessIdentifier
        }
        // Non-empty is required and is not a formality: "no window outside the
        // canvas" is true of an application that has opened none yet, which is
        // precisely the moment it was activated.
        guard !frontmost.isEmpty else {
            return .rejectNoWindow
        }
        // Containment, never intersection. A window straddling the canvas edge
        // is partly on a physical display, and a key posted to it would be
        // typed there.
        guard frontmost.allSatisfy({ canvasBounds.contains($0.bounds) }) else {
            return .rejectWindowOutsideCanvas
        }
        return .allow
    }
}

/// The safe default for every caller that has not stated a scanner: nothing is
/// frontmost, so the geometric branch always refuses: keys reach this
/// connection's own workspace window and nothing else.
@MainActor
public final class NoFrontmostWindowScan: FrontmostWindowScanning {
    public init() {}

    public func scan() -> FrontmostWindowScan {
        FrontmostWindowScan(frontmostProcessIdentifier: nil, onScreenWindows: [])
    }
}

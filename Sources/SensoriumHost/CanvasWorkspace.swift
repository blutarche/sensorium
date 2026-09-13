import CoreGraphics
import Foundation

/// Identifies one installed workspace window, so a caller that fronted a
/// window can tell it apart from a later window installed in its place. Only
/// ever compared, never interpreted.
public struct CanvasWorkspaceWindowToken: Hashable, Sendable {
    private let id: UUID

    public init() {
        id = UUID()
    }
}

/// A product-owned visual surface that exists only while Sensorium owns a
/// session canvas. Implementations must refuse every display other than the
/// supplied session-owned identifier.
///
/// One workspace instance per surface is shared by every connection, so it
/// carries the same ownership discipline `VirtualDisplaySession` carries for
/// the canvas display: `owner` names the connection whose window is currently
/// installed, and a later connection taking the surface over becomes the owner.
@MainActor
public protocol CanvasWorkspacePresenting: AnyObject {
    func start(canvasDisplayID: UInt32, owner: CanvasOwnerToken) throws
    /// The window installed for `owner` right now, or `nil` when this
    /// workspace has no window installed or the caller is not the connection
    /// that installed the one it has.
    ///
    /// Answered from stored state alone -- never an AppKit round trip --
    /// because a key sender re-asks it for every single key: ownership of a
    /// shared workspace can change, and the window can be closed outright,
    /// between one keystroke and the next. Comparing the returned token
    /// against the one a `raise` succeeded on is what separates "still the
    /// window I fronted" from "a different window in its place", so an
    /// actual raise happens only on a real change.
    func installedWindow(owner: CanvasOwnerToken) -> CanvasWorkspaceWindowToken?
    /// Whether the window `installedWindow` names holds this machine's one
    /// process-wide keyboard focus right now.
    ///
    /// Owning an installed window is not the same as being where keys land.
    /// Every window on every display competes for that one focus, so this
    /// workspace's window can stop holding it without this workspace or its
    /// owner touching anything: a person clicks a window on the built-in
    /// display, or an app activates itself, or another connection stands its
    /// own canvas window up. A key posted on the strength of window identity
    /// alone would then be typed onto a physical display.
    ///
    /// Asked per key next to `installedWindow`, and answered from stored state
    /// for the same reason -- AppKit's focus state is main-*thread* state, and
    /// this is reached from a main actor that is not guaranteed to be AppKit's
    /// main thread.
    func hasKeyFocus(owner: CanvasOwnerToken) -> Bool
    /// The owned canvas rectangle this workspace's window was placed on, in
    /// the global, top-left-origin space `CGDisplayBounds` and
    /// `CGWindowListCopyWindowInfo` share. `nil` when no window is installed
    /// or the caller is not the connection that installed the one there is.
    ///
    /// This is what a key can be confined *to* once the window holding the
    /// keyboard is not this workspace's own -- an application launched onto
    /// the canvas. Answered from stored state alone, like `installedWindow`,
    /// and for the same reason: it is asked once per key.
    func canvasBounds(owner: CanvasOwnerToken) -> CGRect?
    /// Stops only if the caller still owns this workspace. A dropped
    /// connection's teardown races the reconnect that already took the surface
    /// over; without this it closes the live connection's window and leaves it
    /// streaming a bare canvas.
    func stop(owner: CanvasOwnerToken)
    /// Unconditional stop, for host shutdown and for a takeover replacing this
    /// window with its own.
    func stop()
    /// Brings this surface's already installed window to the front, so
    /// this machine's one process-wide keyboard focus lands on this canvas.
    /// Returns whether it did: `false` means there is no window installed to front or
    /// the caller does not own the one that is, and the caller must not post a
    /// keyboard event it cannot confine.
    ///
    /// Owner-checked like `stop(owner:)` and for the same race: these
    /// workspaces are shared across connections, so a connection whose socket
    /// died unnoticed must not pull forward the window a reconnect installed.
    /// It never installs one, so it cannot revive a stopped workspace or move
    /// a window off the canvas `start` placed it on.
    @discardableResult
    func raise(owner: CanvasOwnerToken) -> Bool
}

/// The safe default for protocol and media tests that do not open AppKit.
@MainActor
public final class NoCanvasWorkspace: CanvasWorkspacePresenting {
    private var owner: CanvasOwnerToken?

    public init() {}

    public func start(canvasDisplayID: UInt32, owner: CanvasOwnerToken) throws {
        self.owner = owner
    }

    /// Never a window: this workspace installs none, so there is nothing for
    /// a key to be confined to whoever asks.
    public func installedWindow(owner: CanvasOwnerToken) -> CanvasWorkspaceWindowToken? {
        nil
    }

    /// No window means nothing that could hold the keyboard, so this is the
    /// same refusal `installedWindow` gives, for the same reason.
    public func hasKeyFocus(owner: CanvasOwnerToken) -> Bool {
        false
    }

    /// No window means no placement was ever resolved, so there is no canvas
    /// rectangle to confine anything to either.
    public func canvasBounds(owner: CanvasOwnerToken) -> CGRect? {
        nil
    }

    public func stop(owner: CanvasOwnerToken) {
        guard self.owner == owner else {
            return
        }
        stop()
    }

    public func stop() {
        owner = nil
    }

    /// This workspace presents nothing, so there is no window a keystroke
    /// could land in and nothing to front. Refusing rather than reporting the
    /// start it did record is what keeps a caller from posting a key event
    /// that would go to whatever this machine's keyboard focus is on instead.
    public func raise(owner: CanvasOwnerToken) -> Bool {
        false
    }
}

/// The minimum live display evidence required before AppKit is allowed to place
/// the product workspace. It intentionally carries no physical-display details
/// beyond those needed to reject an unsafe target.
public struct CanvasWorkspaceDisplay: Equatable, Sendable {
    public let id: UInt32
    public let bounds: CGRect
    public let isBuiltin: Bool
    public let isOnline: Bool

    public init(id: UInt32, bounds: CGRect, isBuiltin: Bool, isOnline: Bool) {
        self.id = id
        self.bounds = bounds
        self.isBuiltin = isBuiltin
        self.isOnline = isOnline
    }
}

public enum CanvasWorkspacePlacementError: Error, Equatable {
    case unownedCanvas
    case unregisteredCanvas
    case physicalDisplayRejected
    case offlineCanvas
    case unexpectedCanvasDimensions
}

/// A validated placement for the only window Sensorium itself creates during a
/// session. The guard is independent from capture selection so a future UI
/// change cannot silently redirect the workspace to a physical display.
public struct CanvasWorkspacePlacement: Equatable, Sendable {
    public let displayID: UInt32
    public let bounds: CGRect

    public static func resolve(
        ownedHandle: VirtualDisplayHandle,
        display: CanvasWorkspaceDisplay,
        physicalDisplayIDs: Set<UInt32>
    ) throws -> CanvasWorkspacePlacement {
        guard display.id == ownedHandle.rawValue else {
            throw CanvasWorkspacePlacementError.unownedCanvas
        }
        // CoreGraphics reports zero bounds for a display ID that has not (or
        // no longer) registered with WindowServer. That is a platform failure,
        // not a physical display, and must not be reported as one.
        guard display.bounds != .zero else {
            throw CanvasWorkspacePlacementError.unregisteredCanvas
        }
        // `CGDisplayIsBuiltin` cannot identify attached external monitors, so
        // reject every display present before this session started as well.
        guard !display.isBuiltin, !physicalDisplayIDs.contains(display.id) else {
            throw CanvasWorkspacePlacementError.physicalDisplayRejected
        }
        guard display.isOnline else {
            throw CanvasWorkspacePlacementError.offlineCanvas
        }
        guard Int(display.bounds.width) == VirtualCanvasConfiguration.remoteDefault.logicalWidth,
              Int(display.bounds.height) == VirtualCanvasConfiguration.remoteDefault.logicalHeight else {
            throw CanvasWorkspacePlacementError.unexpectedCanvasDimensions
        }
        return CanvasWorkspacePlacement(displayID: display.id, bounds: display.bounds)
    }

    /// Whether a window resolved onto `canvasDisplayID` is still standing on
    /// it. `resolve` runs once, at install time; nothing re-runs it, so a
    /// window that later ends up on another display would be fronted -- and
    /// typed into -- on a physical monitor.
    ///
    /// A `nil` screen is deliberately not a mismatch. AppKit names no screen
    /// for a window it has not placed yet, and for one whose display is
    /// mid-reconfiguration; refusing on that would drop keys through an
    /// ordinary canvas rebuild, while proving nothing about where the window
    /// is. Only a screen that is positively some other display is a refusal.
    public static func isOnOwnedCanvas(canvasDisplayID: UInt32, windowScreenDisplayID: UInt32?) -> Bool {
        guard let windowScreenDisplayID else {
            return true
        }
        return windowScreenDisplayID == canvasDisplayID
    }
}

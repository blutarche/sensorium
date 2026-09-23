/// The overlays a Linux session window draws over the picture, and which one
/// a pointer event belongs to.
///
/// A Wayland compositor names the surface a pointer is on, and this window's
/// chrome is made of subsurfaces of its own, so the question "is the pointer
/// on the picture or on the viewer's own controls" is answered by comparing
/// that surface against the ones the chrome put up. Nothing here holds a
/// Wayland object, so the rule can be driven without a compositor.
public enum WaylandOverlayKind: CaseIterable, Sendable {
    case statusPanel
    case notice
    case diagnostics
    case shortcutStrip
    case stripHandle
}

/// Which surfaces belong to the chrome right now.
///
/// A hidden overlay is not a target: its surface still exists, but nothing
/// is drawn on it and a pointer that lands there is on the picture.
public struct WaylandOverlayPointerTargets {
    public struct Target {
        public var kind: WaylandOverlayKind
        public var surface: OpaquePointer?
        public var isVisible: Bool

        public init(kind: WaylandOverlayKind, surface: OpaquePointer?, isVisible: Bool) {
            self.kind = kind
            self.surface = surface
            self.isVisible = isVisible
        }
    }

    public var targets: [Target]

    public init(targets: [Target]) {
        self.targets = targets
    }

    public func kind(for surface: OpaquePointer?) -> WaylandOverlayKind? {
        guard let surface else { return nil }
        return targets.first { $0.isVisible && $0.surface == surface }?.kind
    }
}

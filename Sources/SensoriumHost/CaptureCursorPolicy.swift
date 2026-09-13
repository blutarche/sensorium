/// Neither target draws the host cursor into the frames: the viewer draws
/// its own, so a baked-in cursor would only add a second, laggy one.
/// `showsCursor` is a stream option and touches nothing about the display.
public enum CaptureCursorPolicy {
    public enum Target: Sendable {
        case sessionCanvas
        case hostScreen
    }

    public static func showsCursor(for target: Target) -> Bool {
        switch target {
        case .sessionCanvas: return false
        case .hostScreen: return false
        }
    }
}

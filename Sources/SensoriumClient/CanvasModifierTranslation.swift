#if canImport(AppKit)
import AppKit
import SensoriumCore

extension CanvasModifierFlags {
    /// Keeps only the four modifiers the protocol forwards. Caps lock, function,
    /// and numeric-pad state stay on the viewer.
    public init(appKitFlags: NSEvent.ModifierFlags) {
        var flags: CanvasModifierFlags = []
        if appKitFlags.contains(.shift) {
            flags.insert(.shift)
        }
        if appKitFlags.contains(.control) {
            flags.insert(.control)
        }
        if appKitFlags.contains(.option) {
            flags.insert(.option)
        }
        if appKitFlags.contains(.command) {
            flags.insert(.command)
        }
        self = flags
    }
}
#endif

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

/// Whether a key event is one of the viewer's own chords: Control-Option-Command
/// plus its key, see `ViewerMenuModifiers.viewerChord`. Anything else, such as
/// Command-Shift-L, is ordinary input for the host.
public enum ViewerChord {
    public static func matches(flags: NSEvent.ModifierFlags, key: String?, expected: String) -> Bool {
        CanvasModifierFlags(appKitFlags: flags) == [.control, .option, .command]
            && key?.lowercased() == expected
    }
}
#endif

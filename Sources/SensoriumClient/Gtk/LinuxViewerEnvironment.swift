#if canImport(CGtk4)
import Foundation
import SensoriumCore
#if canImport(Glibc)
import Glibc
#endif

/// Linux's own answers to `ViewerPlatformEnvironment`: where the viewer's
/// files live, what this machine calls itself, and the local facilities a
/// session needs that are not a window.
///
/// Two of those facilities belong to a window that does not exist yet -- the
/// clipboard and the compositor's shortcut inhibitor -- so this owns the one
/// place each of them is published and `LinuxSessionWindowFactory` fills them
/// in when it opens the session's window.
@MainActor
public final class LinuxViewerEnvironment: ViewerPlatformEnvironment {
    /// Where the window's clipboard is published once there is a window.
    public let pasteboardBox = ClipboardPasteboardBox()
    /// Where the window that can ask the compositor for its shortcuts is
    /// published once there is one.
    public let shortcutInhibit = WaylandShortcutInhibitBinding()
    /// The one interceptor every session's forwarder is built around. The
    /// window it acts for changes; it does not.
    public let shortcutInterceptor: WaylandShortcutInterceptor

    public init() {
        shortcutInterceptor = WaylandShortcutInterceptor(inhibiting: shortcutInhibit)
    }

    public func applicationSupportDirectory() -> URL {
        LinuxViewerLocations.applicationSupportDirectory(
            environment: ProcessInfo.processInfo.environment,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    public func deviceName() -> String {
        LinuxViewerLocations.deviceName(hostname: Self.systemHostname(), etcHostname: Self.writtenDownHostname())
    }

    public func makePasteboard() -> any ClipboardPasteboard {
        WaylandPasteboardProxy(source: pasteboardBox)
    }

    /// Accessibility is a macOS permission with no Linux counterpart, so it is
    /// simply granted here; what decides whether reserved chords actually
    /// arrive is the compositor's own shortcut inhibitor, which is what the
    /// interceptor asks for.
    public func makeShortcutForwarder(mode: SystemShortcutMode) -> SystemShortcutForwarder {
        SystemShortcutForwarder(
            mode: mode,
            accessibility: FixedAccessibilityAuthorization(granted: true),
            interceptor: shortcutInterceptor
        )
    }

    public var isShortcutInterceptionGranted: Bool { true }

    /// Tailscale on Linux is a daemon and a command-line tool, with no
    /// application to open. The picker leaves the button out entirely rather
    /// than offering one that would do nothing.
    public func tailscaleAppURL() -> URL? { nil }

    public func openTailscaleApp(_ url: URL) {}

    private static func systemHostname() -> String? {
        #if canImport(Glibc)
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return nil }
        return String(cString: buffer)
        #else
        return ProcessInfo.processInfo.hostName
        #endif
    }

    private static func writtenDownHostname() -> String? {
        try? String(contentsOfFile: "/etc/hostname", encoding: .utf8)
    }
}
#endif

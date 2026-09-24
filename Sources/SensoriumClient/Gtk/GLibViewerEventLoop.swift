#if canImport(CGtk4)
import CGtk4
import Foundation

/// GTK, brought up once per process.
///
/// Separate from the event loop below because the order matters and the CLI
/// depends on it: `Sensorium pair` and a usage error must reach their answer
/// without a display, so nothing starts the toolkit until the viewer has
/// decided it is opening a window. Every window type here asks for it first,
/// so no caller has to remember to.
@MainActor
public enum GtkToolkit {
    private static var hasStarted = false

    /// `gtk_init_check` rather than `gtk_init`, which aborts the process where
    /// no display can be opened. A viewer started outside a graphical session
    /// says so in a sentence and stops, rather than dying to a toolkit
    /// assertion.
    public static func start() {
        guard !hasStarted else { return }
        hasStarted = true
        guard gtk_init_check() != 0 else {
            FileHandle.standardError.write(Data(
                "Sensorium could not open a window: this machine has no graphical session to open one in.\n".utf8
            ))
            exit(1)
        }
        GtkViewerStyle.install()
    }
}

/// GTK's loop, as the viewer's controller drives it.
///
/// GTK holds a Wayland connection of its own and `WaylandSessionWindow` holds
/// another. Both are dispatched by the one default `GMainContext`, which
/// `GLibMainLoop` already runs -- so the picture and the launch window are
/// driven by the same loop on the same thread, and a `@MainActor` job lands on
/// that thread too.
@MainActor
public final class GLibViewerEventLoop: ViewerEventLoop {
    public init() {
        GtkToolkit.start()
    }

    public func run() {
        GLibMainLoop.run()
    }

    public func stop() {
        GLibMainLoop.stop()
    }
}
#endif

#if os(macOS)
import AppKit
import Foundation

/// A launched instance of an app, as the installer watches it.
@MainActor
public protocol UpdateLaunchedApp: AnyObject {
    var processIdentifier: pid_t { get }
    var hasExited: Bool { get }
    /// Asks the app to quit, as the Quit menu item would.
    func requestQuit()
    func forceQuit()
}

/// Opens an app as a new instance beside the running one. Behind a protocol
/// so tests never launch anything.
@MainActor
public protocol UpdateAppLaunching: AnyObject {
    func launch(appAt url: URL, arguments: [String]) async throws -> any UpdateLaunchedApp
}

/// The real launcher, through LaunchServices, so the new instance is an app
/// of its own rather than a child of this process, and macOS judges its
/// permissions as its own.
@MainActor
public final class WorkspaceUpdateAppLauncher: UpdateAppLaunching {
    public init() {}

    public func launch(appAt url: URL, arguments: [String]) async throws -> any UpdateLaunchedApp {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        configuration.arguments = arguments
        let application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        return RunningApplication(application)
    }
}

@MainActor
private final class RunningApplication: UpdateLaunchedApp {
    private let application: NSRunningApplication

    init(_ application: NSRunningApplication) {
        self.application = application
    }

    var processIdentifier: pid_t { application.processIdentifier }
    var hasExited: Bool { application.isTerminated }
    func requestQuit() { application.terminate() }
    func forceQuit() { application.forceTerminate() }
}
#endif

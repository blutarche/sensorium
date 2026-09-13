import CoreGraphics
import Foundation

/// Where one launched window is to be put, in the same global, top-left-origin
/// coordinate space `CGDisplayBounds` and the Accessibility API both use.
public struct CanvasWindowPlacement: Equatable, Sendable {
    public let origin: CGPoint
    public let size: CGSize

    public init(origin: CGPoint, size: CGSize) {
        self.origin = origin
        self.size = size
    }

    public var frame: CGRect {
        CGRect(origin: origin, size: size)
    }
}

/// The v1 invariant applied to a window this host did not create.
///
/// `resolve` takes a `CanvasWorkspacePlacement`, never a display ID or a raw
/// rectangle, and that is the whole safety argument: a placement only exists
/// once `CanvasWorkspacePlacement.resolve` has refused every builtin display,
/// every display present before the session, and every offline or
/// wrongly-sized one. So the only coordinates this type can produce are inside
/// the session-owned canvas, and `isWithinOwnedCanvas` keeps that checkable.
public enum CanvasLaunchedWindowPlacement {
    public static func resolve(canvas: CanvasWorkspacePlacement, windowFrame: CGRect) -> CanvasWindowPlacement {
        let bounds = canvas.bounds
        // Shrunk, never grown. A window wider than the canvas that was merely
        // moved to the canvas origin would still overhang into the coordinate
        // space of whatever display sits beside it -- which is a physical one.
        let size = CGSize(
            width: min(windowFrame.width, bounds.width),
            height: min(windowFrame.height, bounds.height)
        )
        let origin = CGPoint(
            x: bounds.minX + ((bounds.width - size.width) / 2).rounded(),
            y: bounds.minY + ((bounds.height - size.height) / 2).rounded()
        )
        return CanvasWindowPlacement(origin: origin, size: size)
    }

    public static func isWithinOwnedCanvas(_ placement: CanvasWindowPlacement, canvas: CanvasWorkspacePlacement) -> Bool {
        canvas.bounds.contains(placement.frame)
    }
}

/// How one launched application's windows ended up. `launchFailed` is the only
/// case adoption itself cannot produce: nothing started, so there is nothing
/// whose windows could be moved.
public enum CanvasApplicationLaunchOutcome: Equatable, Sendable {
    case launchFailed(message: String)
    case placed(windows: Int)
    case placementRefused(windows: Int)
    case noWindows(attempts: Int)
    case accessibilityDenied
}

public enum CanvasWindowAdoptionStep: Equatable, Sendable {
    case place
    case wait
    case giveUp
}

/// When to stop waiting for a launched application to open a window. A launched
/// application has no window for a while and may never open one, so the wait is
/// bounded by construction rather than by a condition that might not arrive.
public enum CanvasWindowAdoptionPolicy {
    /// 40 × 0.25s: ten seconds, which covers a cold launch of a large
    /// application on this machine without leaving a click looking dead for
    /// long.
    public static let maxAttempts = 40
    public static let pollInterval: TimeInterval = 0.25

    public static func step(attempt: Int, windowCount: Int, maxAttempts: Int = maxAttempts) -> CanvasWindowAdoptionStep {
        if windowCount > 0 {
            return .place
        }
        return attempt + 1 >= maxAttempts ? .giveUp : .wait
    }
}

/// The Accessibility boundary, kept to two operations so the whole adoption
/// loop can be driven without a real process or a real grant.
public protocol LaunchedWindowPlacing: AnyObject, Sendable {
    /// Frames of the process's windows, in CoreGraphics global coordinates.
    /// Empty while the application has not opened one yet.
    func windowFrames(processIdentifier: pid_t) -> [CGRect]
    /// Moves and resizes one window, indexed as `windowFrames` returned it.
    /// `false` when the Accessibility API refused.
    func place(processIdentifier: pid_t, windowIndex: Int, placement: CanvasWindowPlacement) -> Bool
}

/// Polls a freshly launched application for windows and moves the ones it finds
/// onto the owned canvas.
public struct CanvasWindowAdopter: Sendable {
    private let placer: any LaunchedWindowPlacing
    private let isAccessibilityTrusted: @Sendable () -> Bool
    private let maxAttempts: Int
    private let pollInterval: TimeInterval
    private let wait: @Sendable (TimeInterval) -> Void

    public init(
        placer: any LaunchedWindowPlacing,
        isAccessibilityTrusted: @escaping @Sendable () -> Bool,
        maxAttempts: Int = CanvasWindowAdoptionPolicy.maxAttempts,
        pollInterval: TimeInterval = CanvasWindowAdoptionPolicy.pollInterval,
        wait: @escaping @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.placer = placer
        self.isAccessibilityTrusted = isAccessibilityTrusted
        self.maxAttempts = maxAttempts
        self.pollInterval = pollInterval
        self.wait = wait
    }

    /// Blocks for up to `maxAttempts × pollInterval`. Callers run it off the
    /// main thread; the launch itself has already happened by the time this
    /// starts, so a slow poll delays only the move, never the application.
    public func adopt(processIdentifier: pid_t, canvas: CanvasWorkspacePlacement) -> CanvasApplicationLaunchOutcome {
        // Asked before anything else so a host without the grant reports that
        // one fact, rather than ten seconds of empty polling that looks
        // identical to an application which opened no window.
        guard isAccessibilityTrusted() else {
            return .accessibilityDenied
        }
        var attempt = 0
        while true {
            let frames = placer.windowFrames(processIdentifier: processIdentifier)
            switch CanvasWindowAdoptionPolicy.step(attempt: attempt, windowCount: frames.count, maxAttempts: maxAttempts) {
            case .place:
                var placed = 0
                for (index, frame) in frames.enumerated() {
                    let placement = CanvasLaunchedWindowPlacement.resolve(canvas: canvas, windowFrame: frame)
                    if placer.place(processIdentifier: processIdentifier, windowIndex: index, placement: placement) {
                        placed += 1
                    }
                }
                return placed > 0 ? .placed(windows: placed) : .placementRefused(windows: frames.count)
            case .wait:
                wait(pollInterval)
                attempt += 1
            case .giveUp:
                return .noWindows(attempts: attempt + 1)
            }
        }
    }
}

public struct CanvasApplicationOpenError: Error, Equatable, Sendable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Starting an application. Separate from placing its windows so the launcher
/// can be exercised end to end without starting anything.
public protocol CanvasApplicationOpening: AnyObject, Sendable {
    func open(
        _ application: LaunchableApplication,
        completion: @escaping @Sendable (Result<pid_t, CanvasApplicationOpenError>) -> Void
    )
}

/// The host's own log lines for a launch. A launch that could not be placed
/// still happened, and each ending has a different remedy, so they are five
/// distinct lines rather than one generic failure.
public enum CanvasApplicationLaunchReport {
    public static func line(application: String, outcome: CanvasApplicationLaunchOutcome) -> String {
        switch outcome {
        case let .launchFailed(message):
            return "Sensorium host: could not launch \(application): \(message)"
        case let .placed(windows):
            return "Sensorium host: launched \(application) and moved \(windows) window(s) onto the session canvas"
        case let .placementRefused(windows):
            return "Sensorium host: launched \(application) but the Accessibility API refused to move its \(windows) window(s) onto the session canvas"
        case let .noWindows(attempts):
            return "Sensorium host: launched \(application) but it opened no window within \(attempts) attempts; nothing was moved onto the session canvas"
        case .accessibilityDenied:
            return "Sensorium host: launched \(application) but could not move its window onto the session canvas: Accessibility is not granted to this host."
        }
    }
}

/// What a remote user's Return key does: start the chosen application, then
/// bring what it opened onto the canvas they are actually looking at.
@MainActor
public final class CanvasApplicationLauncher {
    private let canvas: CanvasWorkspacePlacement
    private let opener: any CanvasApplicationOpening
    private let adopter: CanvasWindowAdopter
    private let runOffMain: @Sendable (@escaping @Sendable () -> Void) -> Void
    private let log: @Sendable (String) -> Void
    private let onOutcome: @Sendable (String, CanvasApplicationLaunchOutcome) -> Void

    public init(
        canvas: CanvasWorkspacePlacement,
        opener: any CanvasApplicationOpening,
        adopter: CanvasWindowAdopter,
        runOffMain: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void = {
            DispatchQueue.global(qos: .userInitiated).async(execute: $0)
        },
        log: @escaping @Sendable (String) -> Void = { print($0) },
        // Separate from `log` on purpose. The log line is one string for the
        // host's own record; a UI that has to tell success from failure needs
        // the outcome itself, and recovering it by matching the string back
        // apart is exactly how a failure ends up drawn like a success.
        onOutcome: @escaping @Sendable (String, CanvasApplicationLaunchOutcome) -> Void = { _, _ in }
    ) {
        self.canvas = canvas
        self.opener = opener
        self.adopter = adopter
        self.runOffMain = runOffMain
        self.log = log
        self.onOutcome = onOutcome
    }

    public func launch(_ application: LaunchableApplication) {
        let canvas = canvas
        let adopter = adopter
        let runOffMain = runOffMain
        let log = log
        let onOutcome = onOutcome
        let name = application.name
        opener.open(application) { result in
            switch result {
            case let .failure(error):
                let outcome = CanvasApplicationLaunchOutcome.launchFailed(message: error.message)
                log(CanvasApplicationLaunchReport.line(application: name, outcome: outcome))
                onOutcome(name, outcome)
            case let .success(processIdentifier):
                // Off the main thread: adoption polls for up to ten seconds,
                // and the main thread is AppKit's, which is also the thread
                // this canvas's workspace window draws its launcher on.
                runOffMain {
                    let outcome = adopter.adopt(processIdentifier: processIdentifier, canvas: canvas)
                    log(CanvasApplicationLaunchReport.line(application: name, outcome: outcome))
                    onOutcome(name, outcome)
                }
            }
        }
    }
}

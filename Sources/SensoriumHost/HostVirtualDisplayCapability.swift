import Foundation

/// Whether this machine can actually create the session canvas, checked the only
/// honest way there is: there is no public capability query for the private
/// runtime classes `CoreGraphicsVirtualDisplayAdapter` resolves by name, so
/// a model-name or architecture guess would be a guess. A machine that fails
/// it offers no private desktop for the rest of the run, instead of hitting
/// an unexplained failure partway into a session, and still hosts its own
/// screens.
@MainActor
public enum HostVirtualDisplayCapability {
    public enum Verdict: Equatable, Sendable {
        case supported
        /// Words for the host window, not a raw `Error` description: the
        /// underlying error is almost always `CoreGraphicsVirtualDisplayError`,
        /// whose cases name a step, not a hardware reason a reader would
        /// recognize.
        case unsupported(reason: String)
        /// This host offers no private desktop, so nothing was checked.
        case notOffered
    }

    /// The launch-time check. With the private desktop off it creates nothing
    /// at all, since no session on this host will ask for a canvas.
    public static func startupCheck(
        offersPrivateDesktop: Bool,
        log: @escaping (String) -> Void = { _ in },
        shutdown: CanvasShutdown? = nil,
        makeAdapter: ((@escaping (String) -> Void) -> any VirtualDisplayAdapter)? = nil
    ) -> Verdict {
        guard offersPrivateDesktop else {
            return .notOffered
        }
        return probe(log: log, shutdown: shutdown, makeAdapter: makeAdapter)
    }

    /// Creates a real virtual display and releases it immediately -- never
    /// keeps one, never touches a physical display, and leaves nothing
    /// behind either way. `makeAdapter` is handed the same `log` the real
    /// adapter gets, so the identity fallback reaches the host log from
    /// here too.
    public static func probe(
        log: @escaping (String) -> Void = { _ in },
        shutdown: CanvasShutdown? = nil,
        makeAdapter: ((@escaping (String) -> Void) -> any VirtualDisplayAdapter)? = nil
    ) -> Verdict {
        let adapter = makeAdapter?(log) ?? defaultProbeAdapter(shutdown: shutdown, log: log)
        do {
            let handle = try adapter.acquire(configuration: .remoteDefault)
            adapter.release(handle)
            return .supported
        } catch CoreGraphicsVirtualDisplayError.runtimeUnavailable {
            return .unsupported(reason: Self.runtimeMissingReason)
        } catch {
            return .unsupported(reason: Self.everyIdentityRefusedReason)
        }
    }

    /// The canvas the probe creates when no test has injected an adapter.
    ///
    /// Its own purpose, so its identities are none of the ones a session
    /// canvas asks for: the probe runs at launch, moments before the first
    /// session starts, and a probe that took a session's identity for even
    /// that long would push the session onto a fallback it never needed.
    package static func defaultProbeAdapter(
        shutdown: CanvasShutdown? = nil,
        log: @escaping (String) -> Void
    ) -> CoreGraphicsVirtualDisplayAdapter {
        CoreGraphicsVirtualDisplayAdapter(
            surface: CanvasSurfaceID.allCases[0],
            purpose: .capabilityProbe,
            shutdown: shutdown,
            log: log
        )
    }

    /// The two reasons name the step that failed, because they call for
    /// different things from whoever reads them: nothing will ever give the
    /// first machine a private desktop, while the second is usually one
    /// restart away from having one.
    static let runtimeMissingReason =
        "This machine cannot make a private desktop: the part of macOS that makes one is not present here."

    static let everyIdentityRefusedReason =
        "macOS would not make a private desktop. One left behind by an earlier Sensorium Host is the "
            + "likely cause; restarting this machine clears it."
}

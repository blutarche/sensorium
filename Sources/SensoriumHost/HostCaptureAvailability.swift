import Foundation

/// Whether this process can still get a picture out of this machine.
///
/// Capture can reach a state no session can recover from: the streams start
/// without error and deliver nothing at all, and every canvas identity this
/// process has released stays refused. Both are machine and framework state
/// this process caused, and nothing it can do afterwards repairs either --
/// only ending the process does. So this is recorded for the life of the
/// process rather than per session: the next connection would fail exactly
/// the same way, and answering it with a black window instead of a refusal
/// would hide the one remedy there is.
///
/// One instance per process in production, reached through `shared`; a test
/// makes its own, so nothing it records outlives it.
@MainActor
public final class HostCaptureAvailability {
    public static let shared = HostCaptureAvailability()

    /// Quitting and reopening is the only remedy, so it is the whole line.
    public static let operatorLogLine =
        "capture on this machine delivers nothing; Sensorium Host needs to be quit and opened again"

    /// Said instead of the line above when this machine's displays are
    /// asleep. macOS draws nothing at all while they are, so the silence
    /// has a cause quitting the host does not touch, and nothing about this
    /// process is recorded as broken.
    public static let displaysAsleepLogLine =
        "capture on this machine delivers nothing while its displays are asleep; the session ended"

    public private(set) var isUnavailable = false

    /// Told once, when the state is first recorded, so whoever shows the
    /// person at this machine its status can say so without polling.
    public var onBecomingUnavailable: (() -> Void)?

    public init() {}

    /// Records the state and, the first time, says so through the caller's
    /// own log. Later calls are silent: the second stream to find capture
    /// dead is not news, and a line per failing session would bury the one
    /// that matters.
    public func markUnavailable(log: (String) -> Void) {
        guard !isUnavailable else {
            return
        }
        isUnavailable = true
        log(Self.operatorLogLine)
        onBecomingUnavailable?()
    }
}

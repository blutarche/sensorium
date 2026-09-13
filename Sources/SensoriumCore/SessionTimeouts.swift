import Foundation

/// How long each phase may take before the client stops waiting. A wedged host
/// must surface as a timeout the user can act on, never as an indefinite hang.
public struct SessionTimeouts: Equatable, Sendable {
    public let handshake: TimeInterval
    /// Creating a virtual display involves a display-configuration round trip and
    /// is legitimately slower than a handshake.
    public let canvasCreation: TimeInterval
    /// A host-screen connect may sit behind a person at the host answering
    /// `hostScreenPresencePromptTimeout`'s own confirmation prompt, plus the
    /// viewer's own presence check and network transport -- all of it slower
    /// than `canvasCreation`, which waits on no other person.
    public let hostScreenGrant: TimeInterval

    public init(handshake: TimeInterval, canvasCreation: TimeInterval, hostScreenGrant: TimeInterval) {
        precondition(handshake > 0 && canvasCreation > 0 && hostScreenGrant > 0)
        self.handshake = handshake
        self.canvasCreation = canvasCreation
        self.hostScreenGrant = hostScreenGrant
    }

    /// docs/host-screen-design.md §6.2's own figure -- "No answer within thirty seconds denies" --
    /// held here rather than in `SensoriumHost.HostScreenPresenceRule` so a
    /// client-side deadline sized against it and the host's own prompt window
    /// read the same constant and cannot drift apart. `HostScreenPresenceRule`
    /// depends on `SensoriumCore` and reads this value rather than defining
    /// its own.
    public static let hostScreenPresencePromptTimeout: TimeInterval = 30

    public static let remoteDefault = SessionTimeouts(
        handshake: 5,
        canvasCreation: 15,
        // The host's own prompt window plus room for the viewer's own
        // presence check and network transport.
        hostScreenGrant: hostScreenPresencePromptTimeout + 15
    )
}

import Foundation

/// What a canvas is for.
///
/// Two things about a canvas follow from this rather than from the code that
/// happens to create it: which identities it may present, and what a person at
/// the host sees it called in their display settings. Both have to differ
/// between the canvas a session streams and the throwaway one the host creates
/// to test whether this machine can create a canvas at all, because those two
/// exist at the same moment on every launch.
public enum CanvasPurpose: Sendable {
    /// A canvas a session streams, created when the session starts and removed
    /// when it ends.
    case session

    /// The canvas `HostVirtualDisplayCapability` creates at launch and releases
    /// immediately, only to find out whether creating one is possible here.
    case capabilityProbe

    /// The name the display carries on the host.
    public var displayName: String {
        switch self {
        case .session:
            return "Sensorium Virtual Display"
        case .capabilityProbe:
            return "Sensorium Capability Check"
        }
    }

    /// What the host log calls this canvas when it has to report which identity
    /// it ended up presenting.
    var logDescription: String {
        switch self {
        case .session:
            return "session canvas"
        case .capabilityProbe:
            return "startup capability check"
        }
    }
}

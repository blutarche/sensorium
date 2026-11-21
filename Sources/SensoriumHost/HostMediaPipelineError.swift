import Foundation

@available(macOS 13.0, *)
public enum HostMediaPipelineError: Error, Equatable {
    /// A still-screen refresh was encoded and then not taken by whatever is
    /// behind this pipeline: the packetizer refused it, or the transport
    /// discarded it. Reported rather than swallowed, because the alternative
    /// is telling the person reading the host log that a picture went out.
    case stillRefreshNotDelivered
}

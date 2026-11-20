import Foundation

public enum CoreGraphicsVirtualDisplayError: Error, Equatable {
    /// The macOS runtime classes the bridge creates a display with are not
    /// present at all. No identity can help; the machine cannot host.
    case runtimeUnavailable
    case creationFailed
    case metricsUnavailable
}

public struct VirtualDisplayMetrics: Equatable, Sendable {
    public let maxPixelsWide: Int
    public let maxPixelsHigh: Int
    public let hiDPIScale: Int
}

/// Creates one display under one named identity.
///
/// Separate from the adapter so the identity walk and the creation of one
/// display are separable.
@MainActor
public protocol VirtualDisplayCreating: AnyObject {
    func create(
        configuration: VirtualCanvasConfiguration,
        identity: CanvasDisplayIdentity
    ) throws -> VirtualDisplayHandle
    func destroy(_ handle: VirtualDisplayHandle)
    func metrics(for handle: VirtualDisplayHandle) throws -> VirtualDisplayMetrics
}

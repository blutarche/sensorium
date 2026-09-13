import Foundation

public struct VirtualCanvasConfiguration: Equatable, Sendable {
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let scale: Int

    public init(logicalWidth: Int, logicalHeight: Int, scale: Int) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.scale = scale
    }

    public static let remoteDefault = Self(logicalWidth: 1920, logicalHeight: 1200, scale: 2)
}

public struct VirtualDisplayHandle: Equatable, Hashable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
}

@MainActor
public protocol VirtualDisplayAdapter: Sendable {
    func acquire(configuration: VirtualCanvasConfiguration) throws -> VirtualDisplayHandle
    func release(_ handle: VirtualDisplayHandle)
}
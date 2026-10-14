import Foundation

public struct VirtualCanvasConfiguration: Equatable, Sendable {
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let scale: Int
    /// How many times its one declared mode's pixel size the display may be
    /// backed by at most, in each direction. macOS offers a mode at 2x only
    /// when its pixel size is at most half that largest backing, so a display
    /// that must be set to its own logical size at 2x after it is created
    /// asks for 2. A session canvas asks for 1.
    public let maxPixelHeadroom: Int

    public init(logicalWidth: Int, logicalHeight: Int, scale: Int, maxPixelHeadroom: Int = 1) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.scale = scale
        self.maxPixelHeadroom = maxPixelHeadroom
    }

    /// The pixel size of the one mode the display is created with.
    public var modePixelWidth: Int { logicalWidth * scale }
    public var modePixelHeight: Int { logicalHeight * scale }
    /// The largest pixel size the display may be backed by.
    public var maxPixelWidth: Int { modePixelWidth * maxPixelHeadroom }
    public var maxPixelHeight: Int { modePixelHeight * maxPixelHeadroom }

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
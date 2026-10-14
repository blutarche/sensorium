import Foundation

public struct VirtualCanvasConfiguration: Equatable, Sendable {
    public let logicalWidth: Int
    public let logicalHeight: Int
    public let scale: Int
    /// Whether the one mode the display declares is its logical size rather
    /// than its pixel size. macOS offers a display at its logical size at 2x
    /// only when the one mode it declares is that logical size, with a
    /// largest backing of twice it. A session canvas declares its mode at its
    /// pixel size.
    public let declaresModeInPoints: Bool

    public init(logicalWidth: Int, logicalHeight: Int, scale: Int, declaresModeInPoints: Bool = false) {
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
        self.scale = scale
        self.declaresModeInPoints = declaresModeInPoints
    }

    /// The size of the one mode the display is created with.
    public var declaredModeWidth: Int { declaresModeInPoints ? logicalWidth : logicalWidth * scale }
    public var declaredModeHeight: Int { declaresModeInPoints ? logicalHeight : logicalHeight * scale }
    /// The largest pixel size the display may be backed by.
    public var maxPixelWidth: Int { logicalWidth * scale }
    public var maxPixelHeight: Int { logicalHeight * scale }

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
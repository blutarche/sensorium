#if os(Linux)

import Foundation

/// One screen the portal granted: a PipeWire node and what the compositor
/// said about the monitor behind it.
public struct PortalStream: Equatable, Sendable {
    /// The PipeWire node to read frames from and to name in absolute pointer
    /// motion.
    public var nodeID: UInt32
    /// The portal's opaque identifier for this stream. It persists across
    /// restored sessions.
    public var id: String?
    /// The monitor's position in compositor coordinates.
    public var position: PortalPoint?
    /// The monitor's size in compositor coordinates, which are logical: not
    /// the pixel size of the frames when the monitor is scaled.
    public var size: PortalSize?
    /// The node's PipeWire object serial, which is never reused.
    public var pipeWireSerial: UInt64?

    public init(
        nodeID: UInt32,
        id: String? = nil,
        position: PortalPoint? = nil,
        size: PortalSize? = nil,
        pipeWireSerial: UInt64? = nil
    ) {
        self.nodeID = nodeID
        self.id = id
        self.position = position
        self.size = size
        self.pipeWireSerial = pipeWireSerial
    }
}

public struct PortalPoint: Equatable, Sendable {
    public var x: Int32
    public var y: Int32

    public init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }
}

public struct PortalSize: Equatable, Sendable {
    public var width: Int32
    public var height: Int32

    public init(width: Int32, height: Int32) {
        self.width = width
        self.height = height
    }
}

/// Device types the portal reports as granted, a bitmask.
public struct PortalDevices: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let keyboard = PortalDevices(rawValue: 1)
    public static let pointer = PortalDevices(rawValue: 2)
}

/// What a started portal session was granted.
public struct PortalGrant: Equatable, Sendable {
    public var sessionHandle: String
    public var devices: PortalDevices
    public var streams: [PortalStream]
    /// The token to restore this grant next time, when the portal gave one.
    public var restoreToken: String?

    public init(sessionHandle: String, devices: PortalDevices, streams: [PortalStream], restoreToken: String?) {
        self.sessionHandle = sessionHandle
        self.devices = devices
        self.streams = streams
        self.restoreToken = restoreToken
    }
}

public enum PortalError: Error, Equatable, Sendable {
    /// The portal's RemoteDesktop interface is older than the version that
    /// can persist a grant, so a restart would always show the dialog.
    case interfaceTooOld(interface: String, found: UInt32, required: UInt32)
    /// `Start` did not answer in time: the portal is waiting on a dialog
    /// nobody is answering. The session was closed, which takes the dialog
    /// down. Screen sharing needs to be allowed again.
    case grantNeeded
    /// The person at the host closed the dialog, or the portal ended the
    /// request. `response` is the portal's code: 1 cancelled, 2 ended.
    case declined(response: UInt32)
    /// A step that needed no person did not answer in time.
    case timedOut(step: String)
    case malformedResponse(String)
    /// The new restore token could not be written, so the session was closed
    /// rather than used with a grant that would be lost at the next launch.
    case tokenNotStored(String)
    case sessionClosed
}

/// How long each portal step may take before it is given up on.
public struct PortalTimeouts: Sendable {
    /// `Start` is the step that shows the dialog on a first grant.
    public var start: TimeInterval
    /// Every other step answers without a person.
    public var step: TimeInterval

    public init(start: TimeInterval = 15, step: TimeInterval = 10) {
        self.start = start
        self.step = step
    }
}

/// Where input events go. `PortalSession` is the real one; the input
/// injector is tested against a fake.
public protocol PortalInputSink: Sendable {
    func notifyPointerMotionAbsolute(stream: UInt32, x: Double, y: Double) throws
    func notifyPointerMotion(dx: Double, dy: Double) throws
    func notifyPointerButton(evdevButton: Int32, pressed: Bool) throws
    func notifyPointerAxis(dx: Double, dy: Double, finish: Bool) throws
    func notifyPointerAxisDiscrete(axis: PortalAxis, steps: Int32) throws
    func notifyKeyboardKeycode(evdevKeycode: Int32, pressed: Bool) throws
}

public enum PortalAxis: UInt32, Sendable {
    case vertical = 0
    case horizontal = 1
}

#endif

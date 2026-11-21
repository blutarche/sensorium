#if os(Linux)

import Foundation

/// A started portal session: screen capture and input under one grant.
///
/// Input goes out as fire-and-forget method calls so a stream of pointer
/// motion is never serialized behind round trips. A closed session sends
/// nothing and opens nothing.
public final class PortalSession: PortalInputSink, @unchecked Sendable {
    public let grant: PortalGrant
    private let bus: any DBusConnecting
    private let lock = NSLock()
    private var isClosed = false

    init(bus: any DBusConnecting, grant: PortalGrant) {
        self.bus = bus
        self.grant = grant
    }

    /// A descriptor for the PipeWire remote the granted streams live on. The
    /// caller owns it: capture takes it over and closes it.
    public func openPipeWireRemote() async throws -> Int32 {
        try requireOpen()
        let reply = try await bus.call(DBusCall(
            destination: PortalNames.destination,
            path: PortalNames.objectPath,
            interface: PortalNames.screenCast,
            method: "OpenPipeWireRemote",
            parameters: [.objectPath(grant.sessionHandle), .vardict([:])]
        ))
        guard let descriptor = reply.fileDescriptor else {
            throw PortalError.malformedResponse("OpenPipeWireRemote returned no file descriptor")
        }
        return descriptor
    }

    /// Ends the session. The portal revokes nothing by this: the restore token
    /// stays good for the next launch. Calling it again does nothing.
    public func close() async {
        let wasOpen = lock.withLock {
            defer { isClosed = true }
            return !isClosed
        }
        if wasOpen {
            await Self.closeSession(bus: bus, path: grant.sessionHandle)
        }
    }

    func desktopDidClose() {
        lock.withLock { isClosed = true }
    }

    static func closeSession(bus: any DBusConnecting, path: String) async {
        _ = try? await bus.call(DBusCall(
            destination: PortalNames.destination,
            path: path,
            interface: PortalNames.session,
            method: "Close"
        ))
    }

    private func requireOpen() throws {
        if lock.withLock({ isClosed }) {
            throw PortalError.sessionClosed
        }
    }

    private func notify(_ method: String, _ arguments: [PortalValue], options: [String: PortalValue] = [:]) throws {
        try requireOpen()
        try bus.send(DBusCall(
            destination: PortalNames.destination,
            path: PortalNames.objectPath,
            interface: PortalNames.remoteDesktop,
            method: method,
            parameters: [.objectPath(grant.sessionHandle), .vardict(options)] + arguments
        ))
    }

    public func notifyPointerMotionAbsolute(stream: UInt32, x: Double, y: Double) throws {
        try notify("NotifyPointerMotionAbsolute", [.uint32(stream), .double(x), .double(y)])
    }

    public func notifyPointerMotion(dx: Double, dy: Double) throws {
        try notify("NotifyPointerMotion", [.double(dx), .double(dy)])
    }

    public func notifyPointerButton(evdevButton: Int32, pressed: Bool) throws {
        try notify("NotifyPointerButton", [.int32(evdevButton), .uint32(pressed ? 1 : 0)])
    }

    public func notifyPointerAxis(dx: Double, dy: Double, finish: Bool) throws {
        try notify("NotifyPointerAxis", [.double(dx), .double(dy)], options: finish ? ["finish": .bool(true)] : [:])
    }

    public func notifyPointerAxisDiscrete(axis: PortalAxis, steps: Int32) throws {
        try notify("NotifyPointerAxisDiscrete", [.uint32(axis.rawValue), .int32(steps)])
    }

    public func notifyKeyboardKeycode(evdevKeycode: Int32, pressed: Bool) throws {
        try notify("NotifyKeyboardKeycode", [.int32(evdevKeycode), .uint32(pressed ? 1 : 0)])
    }
}

#endif

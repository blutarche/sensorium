#if os(Linux)

import Foundation

/// One method call: where it goes and what it carries. `parameters` are the
/// method's in-arguments in order.
public struct DBusCall: Equatable, Sendable {
    public var destination: String
    public var path: String
    public var interface: String
    public var method: String
    public var parameters: [PortalValue]

    public init(destination: String, path: String, interface: String, method: String, parameters: [PortalValue] = []) {
        self.destination = destination
        self.path = path
        self.interface = interface
        self.method = method
        self.parameters = parameters
    }
}

/// The out-arguments of a method call. A reply whose signature carries a
/// Unix file descriptor hands it over in `fileDescriptor`, which the receiver
/// owns and must close.
public struct DBusReply: Sendable {
    public var body: [PortalValue]
    public var fileDescriptor: Int32?

    public init(body: [PortalValue] = [], fileDescriptor: Int32? = nil) {
        self.body = body
        self.fileDescriptor = fileDescriptor
    }
}

public struct DBusSignal: Equatable, Sendable {
    public var path: String
    public var interface: String
    public var member: String
    public var body: [PortalValue]

    public init(path: String, interface: String, member: String, body: [PortalValue]) {
        self.path = path
        self.interface = interface
        self.member = member
        self.body = body
    }
}

public enum DBusError: Error, Equatable, Sendable {
    /// The bus answered with an error, such as a method the service does not
    /// have or a name nobody owns.
    case remote(name: String, message: String)
    case connectionFailed(String)
    case malformedReply(String)
}

/// Signals delivered for one subscription. Cancelling stops delivery and
/// ends the stream.
public final class DBusSignalSubscription: Sendable {
    public let signals: AsyncStream<DBusSignal>
    private let onCancel: @Sendable () -> Void

    public init(signals: AsyncStream<DBusSignal>, onCancel: @escaping @Sendable () -> Void) {
        self.signals = signals
        self.onCancel = onCancel
    }

    public func cancel() {
        onCancel()
    }
}

/// The bus the portal and the screen saver service are reached through.
/// `GDBusConnecting` is the real one; tests use a fake.
public protocol DBusConnecting: Sendable {
    /// This connection's unique name, such as `:1.42`.
    var uniqueName: String { get }

    func call(_ call: DBusCall) async throws -> DBusReply

    /// Sends a method call and does not wait for its reply. Used for input
    /// events, where a reply carries nothing and waiting would serialize
    /// every pointer move behind a round trip.
    func send(_ call: DBusCall) throws

    /// A blocking call with a time limit, for the screen saver reads that
    /// have to answer from a synchronous caller.
    func callSynchronously(_ call: DBusCall, timeout: TimeInterval) throws -> DBusReply

    /// Starts delivering a signal. The subscription is active when this
    /// returns, so a caller can subscribe and then make the call that causes
    /// the signal without a race.
    func subscribe(path: String, interface: String, member: String) -> DBusSignalSubscription
}

#endif

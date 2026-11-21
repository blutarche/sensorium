#if os(Linux)

import CGio
import Foundation

/// A GLib main loop on a thread of its own. GDBus delivers replies and
/// signals in the main context that was current when they were asked for, so
/// every such request is made on this thread; the host's own threads never
/// have to iterate a GLib context.
final class GLibWorkerLoop: @unchecked Sendable {
    private let context: OpaquePointer
    private let loop: OpaquePointer
    private let started = DispatchSemaphore(value: 0)
    private var thread: Thread?

    init() {
        context = g_main_context_new()
        loop = g_main_loop_new(context, 0)
        nonisolated(unsafe) let context = context
        nonisolated(unsafe) let loop = loop
        let started = started
        let worker = Thread {
            g_main_context_push_thread_default(context)
            started.signal()
            g_main_loop_run(loop)
            g_main_context_pop_thread_default(context)
        }
        worker.name = "sensorium-dbus"
        thread = worker
        worker.start()
        started.wait()
    }

    deinit {
        g_main_loop_quit(loop)
        g_main_loop_unref(loop)
        g_main_context_unref(context)
    }

    private final class Box {
        let work: () -> Void
        init(_ work: @escaping () -> Void) { self.work = work }
    }

    /// Runs `work` on the loop's thread and does not wait for it.
    func async(_ work: @escaping () -> Void) {
        let box = Unmanaged.passRetained(Box(work)).toOpaque()
        g_main_context_invoke_full(
            context,
            G_PRIORITY_DEFAULT,
            { data in
                Unmanaged<Box>.fromOpaque(data!).takeUnretainedValue().work()
                return 0
            },
            box,
            { data in Unmanaged<Box>.fromOpaque(data!).release() }
        )
    }

    /// Runs `work` on the loop's thread and returns what it returned.
    func sync<T>(_ work: @escaping () -> T) -> T {
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox<T>()
        async {
            result.value = work()
            done.signal()
        }
        done.wait()
        return result.value!
    }

    private final class ResultBox<T>: @unchecked Sendable {
        var value: T?
    }
}

/// The real bus: GDBus on a worker loop.
public final class GDBusConnecting: DBusConnecting, @unchecked Sendable {
    private let connection: OpaquePointer
    private let worker = GLibWorkerLoop()
    public let uniqueName: String

    /// Connects to the session bus named by `DBUS_SESSION_BUS_ADDRESS`.
    public static func connectToSessionBus() throws -> GDBusConnecting {
        var error: UnsafeMutablePointer<GError>?
        guard let connection = g_bus_get_sync(G_BUS_TYPE_SESSION, nil, &error) else {
            throw Self.error(from: error)
        }
        return GDBusConnecting(connection: connection)
    }

    /// Connects to the system bus, where logind describes the login session.
    public static func connectToSystemBus() throws -> GDBusConnecting {
        var error: UnsafeMutablePointer<GError>?
        guard let connection = g_bus_get_sync(G_BUS_TYPE_SYSTEM, nil, &error) else {
            throw Self.error(from: error)
        }
        return GDBusConnecting(connection: connection)
    }

    /// Connects to the message bus at `address`.
    public static func connect(address: String) throws -> GDBusConnecting {
        var error: UnsafeMutablePointer<GError>?
        // AUTHENTICATION_CLIENT | MESSAGE_BUS_CONNECTION.
        let flags = GDBusConnectionFlags(rawValue: (1 << 0) | (1 << 3))
        guard let connection = g_dbus_connection_new_for_address_sync(address, flags, nil, nil, &error) else {
            throw Self.error(from: error)
        }
        return GDBusConnecting(connection: connection)
    }

    private init(connection: OpaquePointer) {
        self.connection = connection
        uniqueName = g_dbus_connection_get_unique_name(connection).map { String(cString: $0) } ?? ""
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(connection))
    }

    private static func error(from error: UnsafeMutablePointer<GError>?) -> DBusError {
        guard let error else { return .connectionFailed("unknown error") }
        defer { g_error_free(error) }
        let message = String(cString: error.pointee.message)
        if g_dbus_error_is_remote_error(error) != 0, let remote = g_dbus_error_get_remote_error(error) {
            defer { g_free(remote) }
            return .remote(name: String(cString: remote), message: message)
        }
        return .connectionFailed(message)
    }

    private static func reply(from result: OpaquePointer, descriptorList: UnsafeMutablePointer<GUnixFDList>?) -> DBusReply {
        var descriptor: Int32?
        if let descriptorList {
            if g_unix_fd_list_get_length(descriptorList) > 0 {
                var ignored: UnsafeMutablePointer<GError>?
                let fd = g_unix_fd_list_get(descriptorList, 0, &ignored)
                if fd >= 0 {
                    descriptor = fd
                } else if let ignored {
                    g_error_free(ignored)
                }
            }
            g_object_unref(UnsafeMutableRawPointer(descriptorList))
        }
        guard case let .tuple(body) = GVariantBridge.consume(result) else {
            return DBusReply(body: [], fileDescriptor: descriptor)
        }
        return DBusReply(body: body, fileDescriptor: descriptor)
    }

    private final class Pending {
        let continuation: CheckedContinuation<DBusReply, Error>
        init(_ continuation: CheckedContinuation<DBusReply, Error>) { self.continuation = continuation }
    }

    public func call(_ call: DBusCall) async throws -> DBusReply {
        try await withCheckedThrowingContinuation { continuation in
            let pending = Unmanaged.passRetained(Pending(continuation)).toOpaque()
            let connection = connection
            // The completion is delivered in the context current at this
            // call, so the call is made on the worker's thread.
            worker.async {
                g_dbus_connection_call_with_unix_fd_list(
                    connection,
                    call.destination,
                    call.path,
                    call.interface,
                    call.method,
                    GVariantBridge.makeTuple(call.parameters),
                    nil,
                    GDBusCallFlags(rawValue: 0),
                    -1,
                    nil,
                    nil,
                    { _, result, data in
                        let pending = Unmanaged<Pending>.fromOpaque(data!).takeRetainedValue()
                        var descriptorList: UnsafeMutablePointer<GUnixFDList>?
                        var error: UnsafeMutablePointer<GError>?
                        let connection = g_async_result_get_source_object(result).map { OpaquePointer($0) }
                        defer { if let connection { g_object_unref(UnsafeMutableRawPointer(connection)) } }
                        guard let connection,
                              let reply = g_dbus_connection_call_with_unix_fd_list_finish(connection, &descriptorList, result, &error) else {
                            pending.continuation.resume(throwing: GDBusConnecting.error(from: error))
                            return
                        }
                        pending.continuation.resume(returning: GDBusConnecting.reply(from: reply, descriptorList: descriptorList))
                    },
                    pending
                )
            }
        }
    }

    public func send(_ call: DBusCall) throws {
        // With no completion callback GDBus marks the message as expecting no
        // reply, so this returns as soon as the message is queued.
        g_dbus_connection_call(
            connection,
            call.destination,
            call.path,
            call.interface,
            call.method,
            GVariantBridge.makeTuple(call.parameters),
            nil,
            GDBusCallFlags(rawValue: 0),
            -1,
            nil,
            nil,
            nil
        )
    }

    public func callSynchronously(_ call: DBusCall, timeout: TimeInterval) throws -> DBusReply {
        var error: UnsafeMutablePointer<GError>?
        guard let result = g_dbus_connection_call_sync(
            connection,
            call.destination,
            call.path,
            call.interface,
            call.method,
            GVariantBridge.makeTuple(call.parameters),
            nil,
            GDBusCallFlags(rawValue: 0),
            Int32(clamping: Int(timeout * 1000)),
            nil,
            &error
        ) else {
            throw Self.error(from: error)
        }
        return Self.reply(from: result, descriptorList: nil)
    }

    private final class SignalSink: @unchecked Sendable {
        let continuation: AsyncStream<DBusSignal>.Continuation
        init(_ continuation: AsyncStream<DBusSignal>.Continuation) { self.continuation = continuation }
    }

    public func subscribe(path: String, interface: String, member: String) -> DBusSignalSubscription {
        var continuation: AsyncStream<DBusSignal>.Continuation!
        let stream = AsyncStream<DBusSignal> { continuation = $0 }
        let sink = SignalSink(continuation)
        let connection = connection
        let identifier = worker.sync { () -> UInt32 in
            g_dbus_connection_signal_subscribe(
                connection,
                nil,
                interface,
                member,
                path,
                nil,
                GDBusSignalFlags(rawValue: 0),
                { _, _, objectPath, interfaceName, signalName, parameters, data in
                    let sink = Unmanaged<SignalSink>.fromOpaque(data!).takeUnretainedValue()
                    guard let objectPath, let interfaceName, let signalName, let parameters,
                          case let .tuple(body) = GVariantBridge.value(from: parameters) else {
                        return
                    }
                    sink.continuation.yield(DBusSignal(
                        path: String(cString: objectPath),
                        interface: String(cString: interfaceName),
                        member: String(cString: signalName),
                        body: body
                    ))
                },
                Unmanaged.passRetained(sink).toOpaque(),
                { data in Unmanaged<SignalSink>.fromOpaque(data!).release() }
            )
        }
        // The cancel closure holds this object so the connection outlives
        // the subscription it is cancelling.
        return DBusSignalSubscription(signals: stream) { [self] in
            worker.async {
                g_dbus_connection_signal_unsubscribe(self.connection, identifier)
            }
            sink.continuation.finish()
        }
    }
}

#endif

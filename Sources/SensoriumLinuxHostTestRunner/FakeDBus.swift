#if os(Linux)

import Foundation
import SensoriumLinuxHost

/// A scripted bus. Portal request methods answer with a request handle and,
/// unless told to stay silent, a `Response` signal on that handle, the way the
/// portal does. Everything it is asked is kept, in order, in `log`.
final class FakeDBus: DBusConnecting, @unchecked Sendable {
    enum Reaction {
        /// Reply with the request handle, then emit `Response(code, results)`.
        case respond(code: UInt32, results: [String: PortalValue])
        /// Reply with the request handle and never respond: a dialog nobody answers.
        case silent
        case reply([PortalValue], fileDescriptor: Int32?)
        case fail(DBusError)
    }

    let uniqueName = ":1.42"
    private let lock = NSLock()
    private var entries: [String] = []
    private var recordedCalls: [DBusCall] = []
    private var reactions: [String: Reaction] = [:]
    private var properties: [String: PortalValue] = [:]
    private var handleOverrides: [String: String] = [:]
    private var continuations: [String: [AsyncStream<DBusSignal>.Continuation]] = [:]
    private var cancelled = 0
    private var hooks: [String: @Sendable (DBusCall) -> Void] = [:]

    var log: [String] { lock.withLock { entries } }
    var calls: [DBusCall] { lock.withLock { recordedCalls } }
    var cancelledSubscriptions: Int { lock.withLock { cancelled } }

    func react(_ key: String, _ reaction: Reaction) {
        lock.withLock { reactions[key] = reaction }
    }

    func setProperty(_ interface: String, _ name: String, _ value: PortalValue) {
        lock.withLock { properties["\(interface).\(name)"] = value }
    }

    /// Makes `key`'s request handle differ from the one the caller predicted,
    /// as an older portal's does.
    func overrideHandle(_ key: String, with path: String) {
        lock.withLock { handleOverrides[key] = path }
    }

    func onCall(_ key: String, _ hook: @escaping @Sendable (DBusCall) -> Void) {
        lock.withLock { hooks[key] = hook }
    }

    func calls(named key: String) -> [DBusCall] {
        calls.filter { Self.key(of: $0) == key }
    }

    static func key(of call: DBusCall) -> String {
        let interface = call.interface.split(separator: ".").last.map(String.init) ?? call.interface
        return "\(interface).\(call.method)"
    }

    func call(_ call: DBusCall) async throws -> DBusReply {
        let key = Self.key(of: call)
        let hook: (@Sendable (DBusCall) -> Void)? = lock.withLock {
            entries.append("call \(key)")
            recordedCalls.append(call)
            return hooks[key]
        }
        hook?(call)

        if call.method == "Get", call.interface == "org.freedesktop.DBus.Properties",
           case let .string(interface)? = call.parameters.first,
           case let .string(name)? = call.parameters.dropFirst().first {
            let value = lock.withLock { properties["\(interface).\(name)"] }
            guard let value else { throw DBusError.remote(name: "org.freedesktop.DBus.Error.InvalidArgs", message: "no \(name)") }
            return DBusReply(body: [.variant(value)])
        }

        let reaction = lock.withLock { reactions[key] }
        switch reaction {
        case let .respond(code, results)?:
            let path = requestPath(for: call, key: key)
            let signal = DBusSignal(
                path: path,
                interface: "org.freedesktop.portal.Request",
                member: "Response",
                body: [.uint32(code), .vardict(results)]
            )
            if lock.withLock({ handleOverrides[key] }) != nil {
                // An older portal answers after the caller has had the handle,
                // so the caller can only be listening on it if it moved.
                Task {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    self.emit(signal)
                }
            } else {
                emit(signal)
            }
            return DBusReply(body: [.objectPath(path)])
        case .silent?:
            return DBusReply(body: [.objectPath(requestPath(for: call, key: key))])
        case let .reply(body, fileDescriptor)?:
            return DBusReply(body: body, fileDescriptor: fileDescriptor)
        case let .fail(error)?:
            throw error
        case nil:
            return DBusReply()
        }
    }

    func send(_ call: DBusCall) throws {
        let key = Self.key(of: call)
        lock.withLock {
            entries.append("send \(key)")
            recordedCalls.append(call)
        }
        if case let .fail(error)? = lock.withLock({ reactions[key] }) {
            throw error
        }
    }

    func callSynchronously(_ call: DBusCall, timeout: TimeInterval) throws -> DBusReply {
        let key = Self.key(of: call)
        lock.withLock {
            entries.append("sync \(key)")
            recordedCalls.append(call)
        }
        switch lock.withLock({ reactions[key] }) {
        case let .reply(body, fileDescriptor)?: return DBusReply(body: body, fileDescriptor: fileDescriptor)
        case let .fail(error)?: throw error
        default: return DBusReply()
        }
    }

    func subscribe(path: String, interface: String, member: String) -> DBusSignalSubscription {
        var continuation: AsyncStream<DBusSignal>.Continuation!
        let stream = AsyncStream<DBusSignal> { continuation = $0 }
        let captured = continuation!
        lock.withLock {
            entries.append("subscribe \(member) \(path)")
            continuations[path, default: []].append(captured)
        }
        return DBusSignalSubscription(signals: stream) { [self] in
            lock.withLock { cancelled += 1 }
            captured.finish()
        }
    }

    /// Emits a signal to everyone subscribed to its path.
    func emit(_ signal: DBusSignal) {
        let targets = lock.withLock { continuations[signal.path] ?? [] }
        for target in targets {
            target.yield(signal)
        }
    }

    private func requestPath(for call: DBusCall, key: String) -> String {
        if let override = lock.withLock({ handleOverrides[key] }) {
            return override
        }
        let options = call.parameters.last?.vardictValue ?? [:]
        let leaf = options["handle_token"]?.stringValue ?? "missing"
        return "/org/freedesktop/portal/desktop/request/1_42/\(leaf)"
    }
}

#endif

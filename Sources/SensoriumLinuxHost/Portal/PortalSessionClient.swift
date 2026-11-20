#if os(Linux)

import Foundation

enum PortalNames {
    static let destination = "org.freedesktop.portal.Desktop"
    static let objectPath = "/org/freedesktop/portal/desktop"
    static let remoteDesktop = "org.freedesktop.portal.RemoteDesktop"
    static let screenCast = "org.freedesktop.portal.ScreenCast"
    static let session = "org.freedesktop.portal.Session"
    static let request = "org.freedesktop.portal.Request"
    static let properties = "org.freedesktop.DBus.Properties"

    /// The RemoteDesktop interface version that added `persist_mode` and
    /// `restore_token`.
    static let minimumRemoteDesktopVersion: UInt32 = 2
    /// `AvailableCursorModes` bit for a cursor delivered as stream metadata.
    static let cursorModeMetadata: UInt32 = 4
}

/// One `Request.Response`: how the interaction ended and what it produced.
struct PortalResponse {
    var code: UInt32
    var results: [String: PortalValue]
}

/// Opens one RemoteDesktop session with ScreenCast sources selected on it, so
/// one grant covers screen capture and input.
///
/// Every portal step is a request: a call that returns a handle at once and
/// answers later in a `Response` signal on that handle. The handle can be
/// predicted from the caller's unique name and a token the caller picks, so
/// each call subscribes before it is made and never misses a fast answer.
public final class PortalSessionClient: Sendable {
    private let bus: any DBusConnecting
    private let tokenStore: RestoreTokenStore
    private let timeouts: PortalTimeouts
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let makeToken: @Sendable () -> String

    /// `sleep` and `makeToken` are seams: a test makes the timeout fire at
    /// once and the tokens predictable.
    public init(
        bus: any DBusConnecting,
        tokenStore: RestoreTokenStore,
        timeouts: PortalTimeouts = PortalTimeouts(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        makeToken: @escaping @Sendable () -> String = {
            "sensorium" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        }
    ) {
        self.bus = bus
        self.tokenStore = tokenStore
        self.timeouts = timeouts
        self.sleep = sleep
        self.makeToken = makeToken
    }

    /// Creates the session, selects keyboard, pointer and one monitor, and
    /// starts it. On a first grant this waits for the person at the host to
    /// answer the system dialog, for at most `timeouts.start`.
    ///
    /// The new restore token is written to the token store before this
    /// returns, so nothing can use the session first. Any failure after the
    /// session exists closes it.
    public func openSession() async throws -> PortalSession {
        let remoteVersion = try await readUInt32(PortalNames.remoteDesktop, "version")
        guard remoteVersion >= PortalNames.minimumRemoteDesktopVersion else {
            throw PortalError.interfaceTooOld(
                interface: PortalNames.remoteDesktop,
                found: remoteVersion,
                required: PortalNames.minimumRemoteDesktopVersion
            )
        }
        // An absent property means a ScreenCast portal too old to offer any
        // cursor mode but the default.
        let cursorModes = (try? await readUInt32(PortalNames.screenCast, "AvailableCursorModes")) ?? 0

        let created = try await perform(
            step: "CreateSession",
            interface: PortalNames.remoteDesktop,
            method: "CreateSession",
            leading: [],
            options: ["session_handle_token": .string(makeToken())],
            timeout: timeouts.step
        )
        guard created.code == 0 else { throw PortalError.declined(response: created.code) }
        guard let sessionHandle = created.results["session_handle"]?.stringValue, !sessionHandle.isEmpty else {
            throw PortalError.malformedResponse("CreateSession returned no session_handle")
        }
        let sessionValue = PortalValue.objectPath(sessionHandle)

        do {
            var deviceOptions: [String: PortalValue] = [
                "types": .uint32(PortalDevices([.keyboard, .pointer]).rawValue),
                "persist_mode": .uint32(2)
            ]
            let offeredToken = tokenStore.load()
            if let offeredToken {
                deviceOptions["restore_token"] = .string(offeredToken)
            }
            try await expectSuccess(
                step: "SelectDevices",
                interface: PortalNames.remoteDesktop,
                method: "SelectDevices",
                leading: [sessionValue],
                options: deviceOptions
            )

            // A RemoteDesktop session persists through SelectDevices alone;
            // the portal refuses persistence options on SelectSources here.
            var sourceOptions: [String: PortalValue] = [
                "types": .uint32(1),
                "multiple": .bool(false)
            ]
            if cursorModes & PortalNames.cursorModeMetadata != 0 {
                sourceOptions["cursor_mode"] = .uint32(PortalNames.cursorModeMetadata)
            }
            try await expectSuccess(
                step: "SelectSources",
                interface: PortalNames.screenCast,
                method: "SelectSources",
                leading: [sessionValue],
                options: sourceOptions
            )

            let started: PortalResponse
            do {
                started = try await perform(
                    step: "Start",
                    interface: PortalNames.remoteDesktop,
                    method: "Start",
                    leading: [sessionValue, .string("")],
                    options: [:],
                    timeout: timeouts.start
                )
            } catch PortalError.timedOut {
                throw PortalError.grantNeeded
            }
            guard started.code == 0 else { throw PortalError.declined(response: started.code) }

            let grant = try Self.parseGrant(sessionHandle: sessionHandle, results: started.results)
            if let issued = grant.restoreToken {
                do {
                    try tokenStore.save(issued)
                } catch {
                    throw PortalError.tokenNotStored("\(error)")
                }
            } else if offeredToken != nil {
                // The portal consumed the token it was given and issued no
                // replacement, so the stored one is dead.
                try? tokenStore.clear()
            }
            return PortalSession(bus: bus, grant: grant)
        } catch {
            await PortalSession.closeSession(bus: bus, path: sessionHandle)
            throw error
        }
    }

    private func readUInt32(_ interface: String, _ name: String) async throws -> UInt32 {
        let reply = try await bus.call(DBusCall(
            destination: PortalNames.destination,
            path: PortalNames.objectPath,
            interface: PortalNames.properties,
            method: "Get",
            parameters: [.string(interface), .string(name)]
        ))
        guard let value = reply.body.first?.uint32Value else {
            throw PortalError.malformedResponse("\(interface).\(name) is not a uint32")
        }
        return value
    }

    private func expectSuccess(
        step: String,
        interface: String,
        method: String,
        leading: [PortalValue],
        options: [String: PortalValue]
    ) async throws {
        let response = try await perform(
            step: step,
            interface: interface,
            method: method,
            leading: leading,
            options: options,
            timeout: timeouts.step
        )
        guard response.code == 0 else { throw PortalError.declined(response: response.code) }
    }

    /// One request: subscribe to the predicted handle, call, follow the
    /// handle if the portal returned another, then wait for the response.
    private func perform(
        step: String,
        interface: String,
        method: String,
        leading: [PortalValue],
        options: [String: PortalValue],
        timeout: TimeInterval
    ) async throws -> PortalResponse {
        let token = makeToken()
        var allOptions = options
        allOptions["handle_token"] = .string(token)
        let expected = Self.requestPath(uniqueName: bus.uniqueName, token: token)

        var subscription = bus.subscribe(path: expected, interface: PortalNames.request, member: "Response")
        defer { subscription.cancel() }
        let reply = try await bus.call(DBusCall(
            destination: PortalNames.destination,
            path: PortalNames.objectPath,
            interface: interface,
            method: method,
            parameters: leading + [.vardict(allOptions)]
        ))
        guard let returned = reply.body.first?.stringValue else {
            throw PortalError.malformedResponse("\(step) returned no request handle")
        }
        if returned != expected {
            subscription.cancel()
            subscription = bus.subscribe(path: returned, interface: PortalNames.request, member: "Response")
        }
        return try await awaitResponse(on: subscription, step: step, timeout: timeout)
    }

    private enum Outcome {
        case response(PortalResponse)
        case timedOut
        case ended
    }

    private func awaitResponse(
        on subscription: DBusSignalSubscription,
        step: String,
        timeout: TimeInterval
    ) async throws -> PortalResponse {
        let sleep = self.sleep
        let outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
            group.addTask {
                for await signal in subscription.signals where signal.member == "Response" {
                    if let response = Self.parseResponse(signal) {
                        return .response(response)
                    }
                }
                return .ended
            }
            group.addTask {
                try await sleep(timeout)
                return .timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? .ended
        }
        switch outcome {
        case let .response(response): return response
        case .timedOut: throw PortalError.timedOut(step: step)
        case .ended: throw PortalError.sessionClosed
        }
    }

    /// `/org/freedesktop/portal/desktop/request/SENDER/TOKEN`, where SENDER is
    /// the unique name without its colon and with dots as underscores.
    static func requestPath(uniqueName: String, token: String) -> String {
        let sender = uniqueName.drop(while: { $0 == ":" }).replacingOccurrences(of: ".", with: "_")
        return "\(PortalNames.objectPath)/request/\(sender)/\(token)"
    }

    private static func parseResponse(_ signal: DBusSignal) -> PortalResponse? {
        guard signal.body.count == 2,
              let code = signal.body[0].uint32Value,
              let results = signal.body[1].vardictValue else {
            return nil
        }
        return PortalResponse(code: code, results: results)
    }

    static func parseGrant(sessionHandle: String, results: [String: PortalValue]) throws -> PortalGrant {
        guard let streamValues = results["streams"]?.arrayValue, !streamValues.isEmpty else {
            throw PortalError.malformedResponse("the portal granted no screen")
        }
        let streams = try streamValues.map { value -> PortalStream in
            guard let parts = value.tupleValue, parts.count == 2,
                  let node = parts[0].uint32Value,
                  let properties = parts[1].vardictValue else {
                throw PortalError.malformedResponse("a stream is not (node, properties)")
            }
            return PortalStream(
                nodeID: node,
                id: properties["id"]?.stringValue,
                position: properties["position"]?.int32Pair.map { PortalPoint(x: $0.0, y: $0.1) },
                size: properties["size"]?.int32Pair.map { PortalSize(width: $0.0, height: $0.1) },
                pipeWireSerial: properties["pipewire-serial"]?.uint64Value
            )
        }
        let issued = results["restore_token"]?.stringValue
        return PortalGrant(
            sessionHandle: sessionHandle,
            devices: PortalDevices(rawValue: results["devices"]?.uint32Value ?? 0),
            streams: streams,
            restoreToken: (issued?.isEmpty ?? true) ? nil : issued
        )
    }
}

#endif

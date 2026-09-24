import Foundation
import SensoriumCore

/// One connection to a machine being paired, opened the moment its code step
/// appears -- see `sendPairIntent` below -- and reused for every attempt that
/// follows, wrong-code retries included, instead of redialling per attempt. A
/// hand-typed address has nothing to dial yet, so it never comes through here.
@MainActor
final class EagerPairing {
    private let device: ViewerPairingDevice
    private let identity: DeviceIdentity
    private let transport: ClientTransportKind
    private let transports: any ViewerTransportFactory
    private let deviceName: String
    private var connection: (any ClientControlConnection)?
    private var controller: ClientSessionController?

    init(
        device: ViewerPairingDevice,
        identity: DeviceIdentity,
        transport: ClientTransportKind,
        transports: any ViewerTransportFactory,
        deviceName: String
    ) {
        self.device = device
        self.identity = identity
        self.transport = transport
        self.transports = transports
        self.deviceName = deviceName
    }

    /// Opens the connection on first use and hands back the same controller on
    /// every later call. `nil` only when the dial itself failed.
    private func openIfNeeded() async -> ClientSessionController? {
        if let controller { return controller }
        // Parsed the way the form does, so a saved host on a non-default port
        // (`address:port`) dials where it was paired rather than the default.
        guard let parsed = ViewerPairingForm(address: device.address).parsedAddress, parsed.port != 0 else {
            return nil
        }
        let connection = transports.makeConnection(
            host: parsed.host,
            port: parsed.port,
            tlsCertificateHash: nil,
            transport: transport
        )
        do {
            try await connection.start(timeout: SessionTimeouts.remoteDefault.handshake)
        } catch {
            return nil
        }
        let controller = ClientSessionController(
            transport: connection,
            identity: identity
        )
        self.connection = connection
        self.controller = controller
        return controller
    }

    /// Whatever is open has nobody left to talk to: a different machine was
    /// picked, or the code step was left.
    func close() async {
        await connection?.close()
        connection = nil
        controller = nil
    }

    func sendPairIntent(deviceName: String) async -> ViewerPairIntentAttempt {
        guard let controller = await openIfNeeded() else {
            return .failed(.unreachable)
        }
        do {
            try await controller.sendPairIntent(deviceName: deviceName)
            return .sent
        } catch {
            return .failed(ViewerPairingOutcome.classify(error))
        }
    }

    /// A wrong code (`.refused`) leaves the connection open for the next
    /// retyped digit; anything else ends it, so the next attempt -- if there
    /// is one -- redials fresh rather than reusing a connection already known
    /// to be bad.
    func pair(
        submission: ViewerPairingSubmission,
        fallback: () async -> ViewerPairingResult
    ) async -> ViewerPairingResult {
        guard let controller = await openIfNeeded() else {
            return await fallback()
        }
        do {
            let approval = try await withThrowingTaskGroup(of: PairingApproval.self) { group in
                group.addTask {
                    try await controller.pair(deviceName: self.deviceName, code: submission.code)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(SessionTimeouts.remoteDefault.handshake))
                    throw ClientSessionError.timedOut
                }
                guard let first = try await group.next() else {
                    throw ClientSessionError.timedOut
                }
                group.cancelAll()
                return first
            }
            await connection?.close()
            connection = nil
            self.controller = nil
            return .paired(SavedHost(
                displayName: submission.displayName,
                host: submission.host,
                port: submission.port,
                hostPublicKey: approval.hostPublicKey,
                tlsCertificateHash: approval.tlsCertificateHash
            ))
        } catch {
            let outcome = ViewerPairingOutcome.classify(error)
            if EagerPairingRetryRule.decision(for: outcome) == .closeConnection {
                await connection?.close()
                connection = nil
                self.controller = nil
            }
            return .failed(outcome)
        }
    }
}

/// Holds the open connection belonging to the machine whose code step is on
/// screen, so announcing this machine and every code typed for it share one dial.
/// Picking a different machine replaces it; nothing is opened until a code step
/// asks for one.
@MainActor
final class PairingSessions {
    private let identity: DeviceIdentity
    private let transport: ClientTransportKind
    private let transports: any ViewerTransportFactory
    private let deviceName: String
    private var current: (device: ViewerPairingDevice, pairing: EagerPairing)?

    init(
        identity: DeviceIdentity,
        transport: ClientTransportKind,
        transports: any ViewerTransportFactory,
        deviceName: String
    ) {
        self.identity = identity
        self.transport = transport
        self.transports = transports
        self.deviceName = deviceName
    }

    func pairing(for device: ViewerPairingDevice) -> EagerPairing {
        if let current, current.device == device { return current.pairing }
        closeCurrent()
        let pairing = EagerPairing(
            device: device,
            identity: identity,
            transport: transport,
            transports: transports,
            deviceName: deviceName
        )
        current = (device, pairing)
        return pairing
    }

    /// Closes whatever is open, if anything is. Called when a different machine's
    /// code step replaces this one, and when the code step is left.
    func closeCurrent() {
        guard let open = current?.pairing else { return }
        current = nil
        Task { await open.close() }
    }
}

/// The session on screen right now, so one quit handler and the launch
/// window's own clicks reach it without a new handler registered per session.
@MainActor
final class ActiveSession {
    /// Set by the running session; `nil` whenever none is.
    var leave: (() -> Void)?

    /// Ends the session on screen and hands the screen back to the list.
    func leaveNow() {
        leave?()
    }
}


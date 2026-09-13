import SensoriumCore
import Foundation

/// Builds one `HostSessionController` per accepted connection.
///
/// The canvases, the pairing service and the injector factory are deliberately
/// shared — there is exactly one host machine, and its two session canvases
/// outlive any single connection. Authentication is deliberately not: a
/// controller reused across connections would let the next viewer to reach
/// the port act on the previous viewer's authority, which is exactly what
/// the pairing ceremony exists to prevent.
@MainActor
public final class HostConnectionSessionFactory {
    private let sessions: CanvasSurfaceSlots<VirtualDisplaySession>
    private let approvedPublicKeys: Set<Data>
    private let requireAuthentication: Bool
    private let inputInjectorFactory: (any InputInjectingFactory)?
    private let pairing: HostPairingService?
    /// Forwarded to each controller; see `HostSessionController.onPairingRequested`.
    private let onPairingRequested: ((String) -> Void)?
    /// Where every controller this factory builds may post a key. The
    /// workspaces behind `confined` are shared like the canvases, and for the
    /// same reason: one window per surface outlives any single connection.
    private let keyConfinement: HostKeyConfinement
    /// The person at this machine's own settings, applied to every
    /// controller this factory builds for the life of the process.
    private let maxSurfaceCount: Int
    /// Forwarded unchanged; host-screen policy is decided in
    /// `HostSessionController`. Shared across connections like `sessions`
    /// and `pairing`, because these stores outlive any one connection.
    private let hostScreenArmingProvider: (() -> HostScreenArming)?
    private let hostScreenPreSessionSnapshotProvider: (() -> [DisplaySnapshot])?
    private let hostScreenCurrentDisplaysProvider: () -> [DisplaySnapshot]
    private let hostScreenPresenceProofVerifier: (any HostScreenPresenceProofVerifying)?
    private let hostScreenResumeTicketStore: (any HostScreenResumeTicketStoring)?
    private let hostScreenLocalActivitySignal: (any HostLocalActivitySignal)?
    private let hostScreenPresenceGate: (any HostScreenPresenceGating)?
    /// Shared rather than per-connection for a reason of its own: this is
    /// what remembers the mode each display was on before any session
    /// changed it, and that memory has to outlive the connection that made
    /// the change so the host can still put the display back.
    private let hostScreenModeController: (any HostScreenModeControlling)?
    /// Shared for the same reason the mode controller is: this machine has
    /// one power state, so the hold that keeps its displays awake belongs to
    /// the process rather than to whichever connection happened to take it.
    private let displayWake: DisplayWakeController?

    public init(
        sessions: CanvasSurfaceSlots<VirtualDisplaySession>,
        approvedPublicKeys: Set<Data> = [],
        requireAuthentication: Bool = false,
        inputInjectorFactory: (any InputInjectingFactory)? = nil,
        pairing: HostPairingService? = nil,
        onPairingRequested: ((String) -> Void)? = nil,
        keyConfinement: HostKeyConfinement,
        maxSurfaceCount: Int = CanvasSurfaceID.capacity,
        hostScreenArmingProvider: (() -> HostScreenArming)? = nil,
        hostScreenPreSessionSnapshotProvider: (() -> [DisplaySnapshot])? = nil,
        hostScreenCurrentDisplaysProvider: @escaping () -> [DisplaySnapshot] = DisplayInventory.online,
        hostScreenPresenceProofVerifier: (any HostScreenPresenceProofVerifying)? = nil,
        hostScreenResumeTicketStore: (any HostScreenResumeTicketStoring)? = nil,
        hostScreenLocalActivitySignal: (any HostLocalActivitySignal)? = nil,
        hostScreenPresenceGate: (any HostScreenPresenceGating)? = nil,
        hostScreenModeController: (any HostScreenModeControlling)? = nil,
        displayWake: DisplayWakeController? = nil
    ) {
        self.sessions = sessions
        self.approvedPublicKeys = approvedPublicKeys
        self.requireAuthentication = requireAuthentication
        self.inputInjectorFactory = inputInjectorFactory
        self.pairing = pairing
        self.onPairingRequested = onPairingRequested
        self.keyConfinement = keyConfinement
        self.maxSurfaceCount = maxSurfaceCount
        self.hostScreenArmingProvider = hostScreenArmingProvider
        self.hostScreenPreSessionSnapshotProvider = hostScreenPreSessionSnapshotProvider
        self.hostScreenCurrentDisplaysProvider = hostScreenCurrentDisplaysProvider
        self.hostScreenPresenceProofVerifier = hostScreenPresenceProofVerifier
        self.hostScreenResumeTicketStore = hostScreenResumeTicketStore
        self.hostScreenLocalActivitySignal = hostScreenLocalActivitySignal
        self.hostScreenPresenceGate = hostScreenPresenceGate
        self.hostScreenModeController = hostScreenModeController
        self.displayWake = displayWake
    }

    /// `onClipboardSharingChanged` is per-call, not factory-level like
    /// `onPairingRequested` above: each connection's own
    /// `ClipboardSyncSession`, if it has one, is its own object, unlike
    /// the process-wide pairing ceremony every connection shares.
    public func makeController(onClipboardSharingChanged: ((Bool) -> Void)? = nil) -> HostSessionController {
        HostSessionController(
            sessions: sessions,
            approvedPublicKeys: approvedPublicKeys,
            requireAuthentication: requireAuthentication,
            inputInjectorFactory: inputInjectorFactory,
            pairing: pairing,
            onPairingRequested: onPairingRequested,
            onClipboardSharingChanged: onClipboardSharingChanged,
            keyConfinement: keyConfinement,
            maxSurfaceCount: maxSurfaceCount,
            hostScreenArmingProvider: hostScreenArmingProvider,
            hostScreenPreSessionSnapshotProvider: hostScreenPreSessionSnapshotProvider,
            hostScreenCurrentDisplaysProvider: hostScreenCurrentDisplaysProvider,
            hostScreenPresenceProofVerifier: hostScreenPresenceProofVerifier,
            hostScreenResumeTicketStore: hostScreenResumeTicketStore,
            hostScreenLocalActivitySignal: hostScreenLocalActivitySignal,
            hostScreenPresenceGate: hostScreenPresenceGate,
            hostScreenModeController: hostScreenModeController,
            displayWake: displayWake
        )
    }
}

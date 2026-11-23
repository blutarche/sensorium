#if os(Linux)
import Foundation

/// One portal session with the physical monitors the person chose.
public struct LinuxScreenGrant: Sendable {
    public let grant: PortalGrant
    public let input: any PortalInputSink
    public let frameSources: [UInt32: any LinuxFrameSource]
    /// Ends the grant from the host's side. The restore token stays good.
    public let close: @Sendable () async -> Void

    public init(
        grant: PortalGrant,
        input: any PortalInputSink,
        frameSources: [UInt32: any LinuxFrameSource],
        close: @escaping @Sendable () async -> Void
    ) {
        self.grant = grant
        self.input = input
        self.frameSources = frameSources
        self.close = close
    }
}

/// Opens the host's one screen-sharing grant.
public protocol LinuxScreenGrantOpening: Sendable {
    /// Opens a grant. `interactive` is false at launch, where a stored token
    /// should restore the grant silently and the attempt gives up rather than
    /// leave a dialog waiting for someone who is not there. It is true when
    /// the person at the host asked to allow screen sharing, and the dialog
    /// is theirs to answer.
    ///
    /// `onClosed` runs once if the grant ends from the desktop's side.
    func open(interactive: Bool, onClosed: @escaping @Sendable () -> Void) async throws -> LinuxScreenGrant
}

/// The RemoteDesktop portal, with ScreenCast on the same session.
public final class PortalScreenGrantOpener: LinuxScreenGrantOpening, @unchecked Sendable {
    private let bus: any DBusConnecting
    private let tokenStore: RestoreTokenStore

    public init(bus: any DBusConnecting, tokenStore: RestoreTokenStore) {
        self.bus = bus
        self.tokenStore = tokenStore
    }

    public func open(interactive: Bool, onClosed: @escaping @Sendable () -> Void) async throws -> LinuxScreenGrant {
        guard interactive || tokenStore.load() != nil else { throw PortalError.grantNeeded }
        // The person asked for this dialog, so it waits for their answer.
        let timeouts = interactive ? PortalTimeouts(start: nil) : PortalTimeouts()
        let client = PortalSessionClient(bus: bus, tokenStore: tokenStore, timeouts: timeouts)
        let session = try await client.openSession(restore: !interactive)
        let subscription = bus.subscribe(path: session.grant.sessionHandle, interface: PortalNames.session, member: "Closed")
        Task {
            for await _ in subscription.signals {
                subscription.cancel()
                session.desktopDidClose()
                onClosed()
                return
            }
        }
        return LinuxScreenGrant(
            grant: session.grant,
            input: session,
            frameSources: Dictionary(uniqueKeysWithValues: session.grant.streams.map {
                ($0.nodeID, PipeWireFrameSource(session: session, stream: $0))
            }),
            close: {
                subscription.cancel()
                await session.close()
            }
        )
    }
}
#endif

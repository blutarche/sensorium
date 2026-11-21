#if os(Linux)
import Foundation

/// One open screen-sharing grant: the monitor the person at the host chose,
/// where its input goes, and where its pictures come from.
public struct LinuxScreenGrant: Sendable {
    public let grant: PortalGrant
    public let input: any PortalInputSink
    public let frameSource: any LinuxFrameSource
    /// Ends the grant from the host's side. The restore token stays good.
    public let close: @Sendable () async -> Void

    public init(
        grant: PortalGrant,
        input: any PortalInputSink,
        frameSource: any LinuxFrameSource,
        close: @escaping @Sendable () async -> Void
    ) {
        self.grant = grant
        self.input = input
        self.frameSource = frameSource
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
    /// How long a person may take to answer the dialog they asked for.
    public static let interactiveStartTimeout: TimeInterval = 180

    private let bus: any DBusConnecting
    private let tokenStore: RestoreTokenStore

    public init(bus: any DBusConnecting, tokenStore: RestoreTokenStore) {
        self.bus = bus
        self.tokenStore = tokenStore
    }

    public func open(interactive: Bool, onClosed: @escaping @Sendable () -> Void) async throws -> LinuxScreenGrant {
        let timeouts = interactive ? PortalTimeouts(start: Self.interactiveStartTimeout) : PortalTimeouts()
        let client = PortalSessionClient(bus: bus, tokenStore: tokenStore, timeouts: timeouts)
        let session = try await client.openSession()
        guard let stream = session.grant.streams.first else {
            await session.close()
            throw PortalError.malformedResponse("the grant names no monitor")
        }
        let subscription = bus.subscribe(path: session.grant.sessionHandle, interface: PortalNames.session, member: "Closed")
        Task {
            for await _ in subscription.signals {
                subscription.cancel()
                onClosed()
                return
            }
        }
        return LinuxScreenGrant(
            grant: session.grant,
            input: session,
            frameSource: PipeWireFrameSource(session: session, stream: stream),
            close: {
                subscription.cancel()
                await session.close()
            }
        )
    }
}
#endif

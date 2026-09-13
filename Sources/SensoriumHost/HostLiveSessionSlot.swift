import Foundation

/// A slot holding one live connection's `HostNetworkSession`.
///
/// `sensoriumd` keeps one of these for the whole process, so the host window's
/// and the menu bar's Stop controls can end the session without either of them
/// owning the connection it belongs to, and one per connection, so a connection
/// that ends can say which session it was.
///
/// `weak`: a session this slot outlives -- the connection closed on its own --
/// must read back as no session to stop, not a dangling one.
public final class HostLiveSessionSlot: @unchecked Sendable {
    public weak var session: HostNetworkSession?

    public init() {}

    /// A run serves several connections and every ending reaches this one
    /// slot. Emptying it for a connection a newer one already replaced is
    /// what leaves the host window's and the menu bar's Stop controls doing
    /// nothing while a session streams.
    public func release(_ ended: HostNetworkSession?) {
        guard let ended, ended === session else {
            return
        }
        session = nil
    }
}

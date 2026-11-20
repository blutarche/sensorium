import Foundation

/// Locks this machine's screen, the way a person at the keyboard would.
public protocol HostScreenRelocking: Sendable {
    /// Posts the relock shortcut. Returns whether both of its events were
    /// actually built and posted, not whether the OS went on to lock the
    /// screen, which nothing here can observe.
    @discardableResult
    func relock() -> Bool
}

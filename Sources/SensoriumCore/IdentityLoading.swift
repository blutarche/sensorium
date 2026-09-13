import Foundation

public protocol DeviceIdentityProviding: Sendable {
    func loadOrCreate() throws -> DeviceIdentity
}

/// Mints a fresh device key and stores it in place of whatever was there.
/// A separate protocol from `DeviceIdentityProviding` rather than a second
/// method requirement on it: a caller holding only a `DeviceIdentityProviding`
/// cannot accidentally invoke a replace path a fake built for ordinary
/// loading tests never expected.
///
/// Minting and storing are separate so a caller replacing this machine's two
/// identities can mint both before either file is touched.
public protocol DeviceIdentityReplacing: Sendable {
    func makeReplacementIdentity() throws -> DeviceIdentity
    func store(_ identity: DeviceIdentity) throws
}

extension DeviceIdentityReplacing {
    /// Mint and store in one step, for a caller with one identity to replace.
    public func replaceWithFreshIdentity() throws -> DeviceIdentity {
        let identity = try makeReplacementIdentity()
        try store(identity)
        return identity
    }
}

/// `DeviceIdentityProviding`'s counterpart for the host's second identity.
public protocol HostTLSIdentityProviding: Sendable {
    func loadOrCreate() throws -> HostTLSIdentity
}

/// `DeviceIdentityReplacing`'s counterpart for the host's second identity --
/// the TLS certificate and key. Its own protocol for the same reason
/// `DeviceIdentityReplacing` is.
public protocol HostTLSIdentityReplacing: Sendable {
    func makeReplacementIdentity() throws -> HostTLSIdentity
    func store(_ identity: HostTLSIdentity) throws
}

extension HostTLSIdentityReplacing {
    public func replaceWithFreshIdentity() throws -> HostTLSIdentity {
        let identity = try makeReplacementIdentity()
        try store(identity)
        return identity
    }
}

public enum IdentityLoadOutcome: Sendable {
    case loaded(DeviceIdentity)
    case failed(String)
}

extension IdentityLoadOutcome: Equatable {
    public static func == (lhs: IdentityLoadOutcome, rhs: IdentityLoadOutcome) -> Bool {
        switch (lhs, rhs) {
        case let (.loaded(left), .loaded(right)):
            left.publicKey == right.publicKey
        case let (.failed(left), .failed(right)):
            left == right
        default:
            false
        }
    }
}

/// `IdentityLoadOutcome`'s counterpart over the host's second identity.
public enum HostTLSIdentityLoadOutcome: Sendable {
    case loaded(HostTLSIdentity)
    case failed(String)
}

/// What a person reads when an identity could not be read or written. An
/// error this project raised itself says its own sentence; anything else
/// falls back to what the system says about it, rather than to a raw case
/// name.
public enum IdentityFailureReason {
    public static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

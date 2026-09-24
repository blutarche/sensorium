import Foundation
import ServiceManagement

/// What macOS reports about this app's login-item registration.
public enum HostAutoLoginStatus: Equatable, Sendable {
    /// Not registered to launch at login.
    case notRegistered
    /// Registered and will launch at login.
    case enabled
    /// Registered, but the person needs to approve it in System Settings
    /// before it will actually launch.
    case requiresApproval
    /// The platform reports this app as not found -- an unexpected state
    /// this type surfaces rather than mapping onto one of the above.
    case notFound
}

/// Registers or unregisters this app to launch at login, and reports the
/// platform's current answer. Behind a protocol so a test can use a fake
/// instead of `SMAppService.mainApp`: CLAUDE.md's safety boundary forbids
/// this repository from installing a real login item on a development
/// machine, in tests or otherwise.
public protocol HostAutoLoginRegistering: Sendable {
    func status() -> HostAutoLoginStatus
    func register() throws
    func unregister() throws
}

/// The real registration, through `SMAppService.mainApp`. Called only from
/// `sensoriumd`'s GUI launch path: once at first launch to apply the
/// open-at-login default, and from the host window's switch when the owner
/// turns it on or off by hand. Never called from a test.
public struct SMAppServiceAutoLoginRegistration: HostAutoLoginRegistering {
    public init() {}

    public func status() -> HostAutoLoginStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    public func register() throws {
        try SMAppService.mainApp.register()
    }

    public func unregister() throws {
        try SMAppService.mainApp.unregister()
    }
}

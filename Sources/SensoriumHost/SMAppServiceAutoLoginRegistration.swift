#if os(macOS)
import Foundation
import ServiceManagement

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
#endif

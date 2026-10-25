import Foundation

@MainActor
package enum HostHostingStartup {
    /// A failed private-desktop probe cannot block hosting the machine's own
    /// screens. Its reason also suppresses probing on later starts in this process.
    package static func begin(
        offersPrivateDesktop: Bool,
        status: HostOperatorStatusStore,
        probe: () -> HostVirtualDisplayCapability.Verdict,
        log: (String) -> Void,
        beginHosting: () -> Void
    ) {
        if offersPrivateDesktop, status.status.privateDesktopUnavailableReason == nil,
           case let .unsupported(reason) = probe() {
            log("Sensorium host: \(reason)")
            status.recordPrivateDesktopUnavailable(reason)
        }
        beginHosting()
    }
}

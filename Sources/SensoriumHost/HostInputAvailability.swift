public enum HostInputCapability: Equatable, Sendable {
    case available
    case unavailableAccessibilityNotGranted
}

/// Whether this host may inject input, decided without ever asking macOS to
/// present its approval UI.
///
/// Approval is the user's to give, in System Settings, on their own initiative.
/// A host that cannot inject input is still useful — video and control need no
/// Accessibility — so this reports a capability rather than refusing to serve.
public enum HostInputAvailability {
    public static func resolve(gate: AccessibilityPermissionGate) -> HostInputCapability {
        switch gate.currentStatus {
        case .granted:
            .available
        case .approvalRequired:
            .unavailableAccessibilityNotGranted
        }
    }
}

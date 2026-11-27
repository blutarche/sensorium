#if os(Linux)
import Foundation

/// Everything the host window shows, as plain values. The window layer holds
/// no state of its own: whoever owns the host builds one of these, the model
/// in `HostWindowPresentation` decides what it means, and the GTK layer draws
/// the result. Nothing here names a type from the host's own modules, so this
/// layer builds and is tested with none of them.
public struct HostWindowState: Equatable, Sendable {
    /// Whether this desktop can show the host screen at all.
    public enum Desktop: Equatable, Sendable {
        case supported
        /// The desktop cannot put the live-session indicator above other
        /// windows, so the host offers no screen here.
        case unsupported
    }

    /// What the host is doing, as the person standing at the machine reads it.
    public enum Status: Equatable, Sendable {
        /// No listener is running.
        case notHosting
        /// A listener is up and nobody is connected.
        case waiting
        /// A device's pairing code was accepted and it has not finished
        /// connecting.
        case pairing(deviceName: String)
        /// A host-screen session is live: `deviceName` sees and controls
        /// `displayName`.
        case sharing(deviceName: String, displayName: String)
        /// The host stopped being able to capture anything, for the rest of
        /// this run.
        case captureStopped
        /// Hosting could not start, in the words that explain why.
        case couldNotStart(headline: String, detail: String)
    }

    /// Whether the desktop's screen sharing permission is in place. The
    /// portal can withdraw it, and the person has to allow it again.
    public enum ScreenSharingGrant: Equatable, Sendable {
        case allowed
        case needed
    }

    public enum Pairing: Equatable, Sendable {
        case idle
        /// This code, until this instant. `requestingDeviceName` is the
        /// machine that asked to use it, once one has.
        case showing(code: String, expiresAt: Date, requestingDeviceName: String?)
    }

    /// The Open at login switch.
    public enum OpenAtLogin: Equatable, Sendable {
        case on
        case off
        /// This machine cannot register the host to start at login. The
        /// switch is shown dimmed with a line saying so.
        case notAvailable
    }

    public var desktop: Desktop
    public var status: Status
    public var grant: ScreenSharingGrant
    public var pairing: Pairing
    public var machines: [HostWindowMachine]
    /// The one line about the last host-screen session, or `nil` when none
    /// has run on this machine.
    public var lastSessionLine: String?
    public var openAtLogin: OpenAtLogin
    public var supportsLocalNetwork: Bool
    public var allowsLocalNetwork: Bool
    /// What the host's updater has to say, or `nil` when it says nothing.
    public var updateLine: HostWindowUpdateLine?

    public init(
        desktop: Desktop = .supported,
        status: Status,
        grant: ScreenSharingGrant = .allowed,
        pairing: Pairing = .idle,
        machines: [HostWindowMachine] = [],
        lastSessionLine: String? = nil,
        openAtLogin: OpenAtLogin = .on,
        supportsLocalNetwork: Bool = true,
        allowsLocalNetwork: Bool = false,
        updateLine: HostWindowUpdateLine? = nil
    ) {
        self.desktop = desktop
        self.status = status
        self.grant = grant
        self.pairing = pairing
        self.machines = machines
        self.lastSessionLine = lastSessionLine
        self.openAtLogin = openAtLogin
        self.supportsLocalNetwork = supportsLocalNetwork
        self.allowsLocalNetwork = allowsLocalNetwork
        self.updateLine = updateLine
    }
}

/// The one line about updates, under the switches.
public struct HostWindowUpdateLine: Equatable, Sendable {
    public var text: String
    /// An update that failed, drawn in the warning colour.
    public var isFailure: Bool

    public init(text: String, isFailure: Bool) {
        self.text = text
        self.isFailure = isFailure
    }
}

/// One machine that has paired with this host.
public struct HostWindowMachine: Equatable, Sendable {
    /// What the window hands back to say which machine a change is for. Opaque
    /// to this layer.
    public var id: String
    /// The name to show: the one chosen here, else the one the machine
    /// reported, else `HostWindowCopy.unnamedMachine`.
    public var name: String
    /// Whether this machine may see the host screen. Pairing arms it; the
    /// person at the host can switch it off and on.
    public var isArmed: Bool
    /// What an armed machine may share, such as "May share Built-in Display."
    public var sharedDisplaysLine: String?
    /// Why an armed machine has no `sharedDisplaysLine` although the machine
    /// has displays.
    public var notOfferedReason: String?
    /// A short key line, such as "Key 5DB742A2", that tells apart two
    /// machines that share a name.
    public var keyFingerprintLine: String?
    /// Whether a session from this machine asks the person at the host first
    /// when someone used the machine in the last few minutes.
    public var asksFirst: Bool

    public init(
        id: String,
        name: String,
        isArmed: Bool,
        sharedDisplaysLine: String? = nil,
        notOfferedReason: String? = nil,
        keyFingerprintLine: String? = nil,
        asksFirst: Bool = false
    ) {
        self.id = id
        self.name = name
        self.isArmed = isArmed
        self.sharedDisplaysLine = sharedDisplaysLine
        self.notOfferedReason = notOfferedReason
        self.keyFingerprintLine = keyFingerprintLine
        self.asksFirst = asksFirst
    }
}
#endif

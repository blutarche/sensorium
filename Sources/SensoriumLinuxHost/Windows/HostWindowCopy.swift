#if os(Linux)
import Foundation

/// Every sentence the host's windows show. Where the macOS host says the same
/// thing, the words are the macOS host's, character for character; the
/// sentences that name a macOS facility (Screen Recording, System Settings,
/// Login Items) have a Linux counterpart here instead.
public enum HostWindowCopy {
    public static let windowTitle = "Sensorium Host"

    // MARK: Status card

    public static let notHostingEyebrow = "STATUS"
    public static let notHostingHeadline = "This machine is not hosting."
    public static let notHostingDetail = "No machine is connected."

    public static let waitingEyebrow = "READY"
    public static let waitingHeadline = "Waiting for a machine to connect."

    public static let pairingEyebrow = "WAITING"
    public static func pairingHeadline(_ deviceName: String) -> String {
        "Waiting for \(deviceName) to finish pairing."
    }
    public static func pairingDetail(_ deviceName: String) -> String {
        "Code accepted. \(deviceName) is connecting."
    }

    public static let sharingEyebrow = "SHARING HOST SCREEN"
    public static func sharingHeadline(_ deviceName: String) -> String {
        "Connected to \(deviceName)"
    }
    public static func sharingDetail(displayName: String) -> String {
        "It sees and controls \(displayName) \u{2014} this machine\u{2019}s own screen."
    }

    public static func askingToPairDetail(_ deviceName: String) -> String {
        "\(deviceName) is asking to pair."
    }

    public static let captureStoppedEyebrow = "CAPTURE STOPPED"
    public static let captureStoppedHeadline = "Quit Sensorium Host and open it again."
    public static let captureStoppedDetail = "This machine has stopped handing Sensorium Host any picture to send. "
        + "Opening it again is the only thing that restores it."

    public static let couldNotStartEyebrow = "COULD NOT START"

    // MARK: Screen sharing grant

    public static let grantEyebrow = "SCREEN SHARING NEEDED"
    public static let grantHeadline = "Screen sharing needs to be allowed again."
    public static let grantDetail = "No machine can see a screen until you allow screen sharing for Sensorium Host."
        + " A paired machine can choose among the screens your desktop shares."
    public static let grantButton = "Allow Screen Sharing"
    public static let updateScreenSharingButton = "Update Screen Sharing…"
    public static let updateScreenSharingHelp = "Approve sharing all screens connected to this desktop."

    // MARK: Desktop that cannot offer the host screen

    public static let unsupportedEyebrow = "NOT SUPPORTED HERE"
    public static let unsupportedHeadline = "This desktop cannot share its screen."
    public static let unsupportedDetail = "While a machine is connected, Sensorium Host must show a badge above every other window. "
        + "This desktop does not allow that, so no machine can see this screen."

    // MARK: Controls

    public static let stopButton = "Stop"
    public static let showPairingCodeButton = "Show Pairing Code"
    public static let hidePairingCodeButton = "Hide Code"
    public static let pairingCodeHint = "Type it on the machine you are pairing."

    // MARK: Paired machines

    public static let pairedMachinesEyebrow = "Paired machines"
    public static let noMachinePaired = "No machine is paired."
    public static let emptyWithCodeShowing = "The machine appears here once the code is typed on it."
    public static let emptyCanShowCode = "Show a pairing code, then type it on the machine you are pairing."
    public static let emptyCannotPairYet = "Machines appear here once they pair."
    public static let lastSessionEyebrow = "Last host screen session"
    public static let unnamedMachine = "Unnamed machine"
    public static let sharingOffLine = "Host screen sharing off"
    public static let shareSwitchTitle = "Share host screen"
    public static let renameMenuItem = "Rename\u{2026}"
    public static let askFirstMenuItem = "Ask me first if this machine is in use"
    public static let removeMenuItem = "Remove"

    public static func shareSwitchLabel(for machine: String) -> String {
        "Share host screen with \(machine)"
    }
    public static func moreActionsLabel(for machine: String) -> String {
        "More actions for \(machine)"
    }

    // MARK: Switches

    public static let openAtLogin = "Open at login"
    public static let openAtLoginUnavailable = "Not available on this machine."
    public static let localNetwork = "Allow connections from this network"
    public static let localNetworkExplanation =
        "Lets a viewer on the same Wi-Fi or wired network connect by name, such as mini.local, "
        + "without Tailscale. Anyone on this network can then ask to pair. Leave it off on shared networks."

    // MARK: Rename

    public static let renameCancel = "Cancel"
    public static let renameConfirm = "Rename"
    public static let renameHint =
        "Only this machine sees this name. Leave it empty to use the name the other machine reports."
    public static let renameUnnamedHeading = "Rename the unnamed machine"
    public static func renameHeading(currentName: String) -> String {
        currentName.isEmpty ? renameUnnamedHeading : "Rename \(currentName)"
    }
}
#endif

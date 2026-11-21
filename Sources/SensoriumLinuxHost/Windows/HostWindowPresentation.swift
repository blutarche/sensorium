#if os(Linux)
import Foundation

/// What the host window draws for one `HostWindowState`: which rows show, the
/// words in them, and which controls can be used. The same decisions the macOS
/// host window makes, kept free of any toolkit so they can be checked as
/// values.
public struct HostWindowPresentation: Equatable, Sendable {
    /// The status card at the top of the window.
    public struct Card: Equatable, Sendable {
        public var eyebrow: String
        public var headline: String
        public var detail: String
        public var eyebrowIsWarning: Bool
    }

    /// The pairing code and the buttons that show and hide it.
    public struct Pairing: Equatable, Sendable {
        /// The code in two groups of three, or `nil` when none is on screen.
        public var code: String?
        public var countdown: String?
        /// True in the last half minute of a code's life, so the countdown
        /// can change tone while the person reads the code out.
        public var countdownIsUrgent: Bool
        /// Shown under the code and its countdown.
        public var hint: String?
        public var showsRevealButton: Bool
        /// Whether the Show button is the accent fill. It drops to an outline
        /// beside another filled button so two never compete.
        public var revealIsFilled: Bool
        public var showsHideButton: Bool
        public var revealButtonTitle: String { HostWindowCopy.showPairingCodeButton }
        public var hideButtonTitle: String { HostWindowCopy.hidePairingCodeButton }
    }

    /// One entry in a machine row's "more" menu.
    public enum MenuItem: Equatable, Sendable {
        case rename(title: String)
        case askFirst(title: String, isChecked: Bool, isEnabled: Bool)
        /// Plain text, never an action.
        case keyLine(String)
        case separator
        /// Drawn in the warning-red `bad` colour.
        case remove(title: String)
    }

    /// One paired machine's row: a name over a muted line, its Share host
    /// screen switch, and a menu of the rarer actions.
    public struct MachineRow: Equatable, Sendable {
        public var id: String
        public var name: String
        /// What the machine may share, or why it shares nothing; `nil` when
        /// the row is a single line.
        public var subtitle: String?
        public var switchIsOn: Bool
        public var switchLabel: String
        public var moreLabel: String
        public var menu: [MenuItem]
        /// What the rename step starts from: empty for a machine that has no
        /// name of its own.
        public var renameCurrentName: String
    }

    public struct LastSession: Equatable, Sendable {
        public var eyebrow: String
        public var line: String
    }

    /// The Paired machines section.
    public struct Machines: Equatable, Sendable {
        public var eyebrow: String
        public var showsEyebrow: Bool
        /// The two-line empty state: what is empty, then what to do. Both
        /// `nil` while machines are listed or while a pairing finishes.
        public var emptyHeading: String?
        public var emptySubtext: String?
        public var rows: [MachineRow]
        public var lastSession: LastSession?
        /// A section with nothing to show takes no room, so the window's gap
        /// around it is not paid twice.
        public var isHidden: Bool
    }

    /// A checkbox and the line, if any, under it.
    public struct Switch: Equatable, Sendable {
        public var title: String
        public var isOn: Bool
        public var isEnabled: Bool
        public var note: String?
    }

    public struct LocalNetwork: Equatable, Sendable {
        public var title: String
        public var isOn: Bool
        public var explanation: String
    }

    public let card: Card
    public let pairing: Pairing
    public let machines: Machines
    public let openAtLogin: Switch
    public let localNetwork: LocalNetwork
    /// Whether the Open at login and local network switches show. A desktop
    /// that cannot offer the screen hosts nothing, so neither means anything.
    public let showsSwitches: Bool
    /// Whether the Stop button shows: a host-screen session is live.
    public let showsStop: Bool
    /// The title of the button that starts the screen sharing grant, or `nil`
    /// when the grant is in place.
    public let grantButtonTitle: String?

    public init(_ state: HostWindowState, now: Date) {
        let isConnected: Bool
        if case .sharing = state.status { isConnected = true } else { isConnected = false }
        showsStop = isConnected && state.desktop == .supported
        grantButtonTitle = state.grant == .needed && state.desktop == .supported ? HostWindowCopy.grantButton : nil
        card = Self.card(for: state, isConnected: isConnected, now: now)
        pairing = Self.pairing(
            for: state, canReveal: Self.canShowCode(state), filled: !showsStop && grantButtonTitle == nil, now: now
        )
        machines = Self.machines(for: state, pairing: pairing)
        showsSwitches = state.desktop == .supported
        openAtLogin = Self.openAtLogin(state.openAtLogin)
        localNetwork = LocalNetwork(
            title: HostWindowCopy.localNetwork,
            isOn: state.allowsLocalNetwork,
            explanation: HostWindowCopy.localNetworkExplanation
        )
    }

    private static func openAtLogin(_ setting: HostWindowState.OpenAtLogin) -> Switch {
        switch setting {
        case .on:
            return Switch(title: HostWindowCopy.openAtLogin, isOn: true, isEnabled: true, note: nil)
        case .off:
            return Switch(title: HostWindowCopy.openAtLogin, isOn: false, isEnabled: true, note: nil)
        case .notAvailable:
            // Nothing here can turn it on, so the switch is dimmed rather than
            // doing nothing when pressed.
            return Switch(
                title: HostWindowCopy.openAtLogin, isOn: false, isEnabled: false,
                note: HostWindowCopy.openAtLoginUnavailable
            )
        }
    }

    private static func machines(for state: HostWindowState, pairing: Pairing) -> Machines {
        let rows = state.machines.map(row(for:))
        let showsEmptyLines: Bool
        let emptySubtext: String
        if pairing.code != nil {
            showsEmptyLines = true
            emptySubtext = HostWindowCopy.emptyWithCodeShowing
        } else if case .pairing = state.status, state.desktop == .supported {
            // The status card already says what is happening.
            showsEmptyLines = false
            emptySubtext = ""
        } else if pairing.showsRevealButton {
            showsEmptyLines = true
            emptySubtext = HostWindowCopy.emptyCanShowCode
        } else {
            showsEmptyLines = true
            emptySubtext = HostWindowCopy.emptyCannotPairYet
        }
        let showsLines = rows.isEmpty && showsEmptyLines
        let lastSession = state.lastSessionLine.map {
            LastSession(eyebrow: HostWindowCopy.lastSessionEyebrow, line: $0)
        }
        let showsEyebrow = !rows.isEmpty || showsEmptyLines
        return Machines(
            eyebrow: HostWindowCopy.pairedMachinesEyebrow,
            showsEyebrow: showsEyebrow,
            emptyHeading: showsLines ? HostWindowCopy.noMachinePaired : nil,
            emptySubtext: showsLines ? emptySubtext : nil,
            rows: rows,
            lastSession: lastSession,
            isHidden: !showsEyebrow && lastSession == nil
        )
    }

    private static func row(for machine: HostWindowMachine) -> MachineRow {
        var menu: [MenuItem] = [
            .rename(title: HostWindowCopy.renameMenuItem),
            // Only means anything for a machine allowed to share.
            .askFirst(title: HostWindowCopy.askFirstMenuItem, isChecked: machine.asksFirst, isEnabled: machine.isArmed)
        ]
        if let key = machine.keyFingerprintLine {
            menu.append(.keyLine(key))
        }
        menu.append(.separator)
        menu.append(.remove(title: HostWindowCopy.removeMenuItem))
        return MachineRow(
            id: machine.id,
            name: machine.name,
            subtitle: subtitle(for: machine),
            switchIsOn: machine.isArmed,
            switchLabel: HostWindowCopy.shareSwitchLabel(for: machine.name),
            moreLabel: HostWindowCopy.moreActionsLabel(for: machine.name),
            menu: menu,
            // The placeholder title is not a name to start from.
            renameCurrentName: machine.name == HostWindowCopy.unnamedMachine ? "" : machine.name
        )
    }

    /// What this machine may share, or why it shares nothing.
    private static func subtitle(for machine: HostWindowMachine) -> String? {
        guard machine.isArmed else { return HostWindowCopy.sharingOffLine }
        if let line = machine.sharedDisplaysLine {
            // A status line under a name, not a sentence of its own.
            return line.hasSuffix(".") ? String(line.dropLast()) : line
        }
        return machine.notOfferedReason
    }

    /// A code can be made while a listener is up. A pairing already approved
    /// is a machine already confirming the code it was given, and a desktop
    /// that cannot offer the screen has nothing to pair for.
    private static func canShowCode(_ state: HostWindowState) -> Bool {
        guard state.desktop == .supported else { return false }
        switch state.status {
        case .waiting, .sharing: return true
        case .notHosting, .pairing, .captureStopped, .couldNotStart: return false
        }
    }

    /// Half a minute of the code's life, as on the macOS host.
    private static let urgentRemainingSeconds: TimeInterval = 30

    private static func pairing(for state: HostWindowState, canReveal: Bool, filled: Bool, now: Date) -> Pairing {
        var code: String?
        var countdown: String?
        var urgent = false
        if case let .showing(digits, expiresAt, _) = state.pairing, state.desktop == .supported {
            let remaining = expiresAt.timeIntervalSince(now)
            // An expired code is withdrawn rather than left on screen for
            // someone to read aloud.
            if remaining > 0 {
                code = grouped(digits)
                // Rounded up, so a code with a fraction of a second left never
                // reads 0:00 while it still works.
                let whole = Int(remaining.rounded(.up))
                countdown = "Expires in \(whole / 60):\(String(format: "%02d", whole % 60))"
                urgent = remaining <= urgentRemainingSeconds
            }
        }
        return Pairing(
            code: code,
            countdown: countdown,
            countdownIsUrgent: urgent,
            hint: countdown == nil ? nil : HostWindowCopy.pairingCodeHint,
            showsRevealButton: canReveal && code == nil,
            revealIsFilled: filled,
            showsHideButton: code != nil
        )
    }

    /// Six digits are read aloud in threes, and the grouping stops a digit
    /// being typed into the wrong column. A code that is not six digits is
    /// shown as it came rather than split somewhere arbitrary.
    private static func grouped(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let split = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<split]) \(code[split...])"
    }

    private static func card(for state: HostWindowState, isConnected: Bool, now: Date) -> Card {
        if state.desktop == .unsupported {
            return Card(
                eyebrow: HostWindowCopy.unsupportedEyebrow,
                headline: HostWindowCopy.unsupportedHeadline,
                detail: HostWindowCopy.unsupportedDetail,
                eyebrowIsWarning: true
            )
        }
        var card: Card
        switch state.status {
        case .notHosting:
            card = Card(
                eyebrow: HostWindowCopy.notHostingEyebrow, headline: HostWindowCopy.notHostingHeadline,
                detail: HostWindowCopy.notHostingDetail, eyebrowIsWarning: false
            )
        case .waiting:
            card = Card(
                eyebrow: HostWindowCopy.waitingEyebrow, headline: HostWindowCopy.waitingHeadline,
                detail: "", eyebrowIsWarning: false
            )
        case let .pairing(deviceName):
            card = Card(
                eyebrow: HostWindowCopy.pairingEyebrow, headline: HostWindowCopy.pairingHeadline(deviceName),
                detail: HostWindowCopy.pairingDetail(deviceName), eyebrowIsWarning: false
            )
        case let .sharing(deviceName, displayName):
            card = Card(
                eyebrow: HostWindowCopy.sharingEyebrow, headline: HostWindowCopy.sharingHeadline(deviceName),
                detail: HostWindowCopy.sharingDetail(displayName: displayName), eyebrowIsWarning: false
            )
        case .captureStopped:
            card = Card(
                eyebrow: HostWindowCopy.captureStoppedEyebrow, headline: HostWindowCopy.captureStoppedHeadline,
                detail: HostWindowCopy.captureStoppedDetail, eyebrowIsWarning: true
            )
        case let .couldNotStart(headline, detail):
            card = Card(
                eyebrow: HostWindowCopy.couldNotStartEyebrow, headline: headline,
                detail: detail, eyebrowIsWarning: true
            )
        }
        // Naming who asks is the point of showing the code unprompted, but it
        // only fills the ready state's empty detail: every other state's
        // detail is a claim that stays true.
        if case .waiting = state.status,
           case let .showing(_, _, requestingDeviceName?) = state.pairing {
            card.detail = HostWindowCopy.askingToPairDetail(requestingDeviceName)
        }
        // A withdrawn grant outranks the ready and pairing states, but only
        // before anyone is connected: mid-session, who is connected matters
        // more, and the grant button beneath the card says what to do. A stopped
        // capture outranks the grant, since nothing restores it but a restart.
        if state.grant == .needed, !isConnected, state.status != .captureStopped {
            card = Card(
                eyebrow: HostWindowCopy.grantEyebrow, headline: HostWindowCopy.grantHeadline,
                detail: HostWindowCopy.grantDetail, eyebrowIsWarning: true
            )
        }
        return card
    }
}
#endif

import Foundation

/// The copy `sensoriumd` reports through `HostOperatorStatusStore.reportProblem`
/// when hosting could not start because address auto-detection could not pick
/// one address to bind. Kept here, not inlined at each call site, so it stays
/// the single source of truth for the words each case shows.
public enum HostStartupProblemCopy {
    /// `HostSetupWindowController` reads this one back to decide whether to
    /// offer its "Open Tailscale" button -- only this exact problem is fixed
    /// by opening the app. `HostOperatorStatus` itself has no way to know
    /// whether Tailscale is installed, only that no tailnet address was
    /// found -- `HostSetupWindowController.refresh()` is what actually
    /// chooses between this wording and `tailscaleNotInstalled`, from its
    /// own `tailscaleAppURLLookup` result.
    public static let noTailnetAddress =
        "Open Tailscale and let it connect; this machine then becomes reachable."
    /// The same no-address problem, worded for the case `tailscaleAppURLLookup`
    /// finds no app to open at all -- `noTailnetAddress`'s "Open Tailscale"
    /// would contradict a button that only offers to download it. Each
    /// detail starts with its button's own title, so the two read as one
    /// instruction.
    public static let tailscaleNotInstalled =
        "Download Tailscale and sign in; this machine then becomes reachable."
}

/// Whether a machine is connected to this one, as the person standing at it
/// needs to read it. `sensoriumd` draws its workspace onto the session canvas,
/// which by definition only the remote viewer ever sees, so this is the one
/// description of the host that reaches the machine's own operator.
///
/// Says nothing about pairing on purpose. A code on screen is not a fact about
/// who is connected, so `HostPairingState` carries that separately and showing
/// a code can never take a live session, or the Stop control that ends it, off
/// the screen.
public enum HostConnectionState: Equatable, Sendable {
    /// No listener is running. The state before the operator has ever
    /// started hosting, and after they choose Stop Hosting.
    case notHosting
    /// A listener is bound to this address; nobody is connected.
    case hosting(address: String)
    /// A device's `pairRequest` was just approved and its key is now
    /// trusted, but its authenticated hello has not arrived yet. Ends the
    /// same way `.serving` does: the connection either completes
    /// (`.serving`) or closes (back to `.hosting`/`.notHosting`).
    case pairingApproved(deviceName: String)
    case serving(peerName: String)
    /// A host-screen session is live: `peerName` is driving this machine's own
    /// screen, not a virtual display -- the badge and menu-bar wording
    /// exist because `.serving`'s quiet, title-less presentation is
    /// deliberately too quiet for a mode nobody re-approves per session.
    case servingHostScreen(peerName: String, displayLabel: String)
}

/// Whether a pairing code is on screen, and until when.
public enum HostPairingState: Equatable, Sendable {
    /// Nothing is on screen; the pairing section offers to show a code.
    case idle
    /// This exact code, until this exact instant.
    ///
    /// `requestingDeviceName` names the machine that has asked to use it, once
    /// one has, and is `nil` when a person at this machine revealed the code
    /// themselves and nothing has asked for it yet. Never a queue: a later
    /// `pairRequest` replaces this field with its own name, one at a time,
    /// exactly like the code itself -- see
    /// `HostOperatorStatusStore.recordPairingRequest`.
    case showing(code: String, expiresAt: Date, requestingDeviceName: String? = nil)
}

/// What the transport can tell an observer about who is on the other end.
/// `identified` is reported only once the connecting machine's authenticated
/// hello has actually been accepted, so a rejected machine never reaches the
/// menu bar.
public enum HostPeerPresence: Equatable, Sendable {
    case identified(deviceName: String)
    /// `reason` is what ended the connection, in a person's terms, or `nil`
    /// when nothing was learned -- a deliberate stop, or a failure that said
    /// nothing about itself. Never a Swift value: see `HostOperatorLog`.
    case closed(reason: String?)
}

/// A host serves several connections in a run, sometimes overlapping, and
/// every one ends the same way. Without an identity to compare against, a
/// replaced connection's close would take the live session, and its Stop
/// control, off the screen.
public final class HostConnectionToken: Sendable {
    public init() {}
}

/// Everything the menu-bar item shows, as plain values.
///
/// Deliberately AppKit-free: the status item above it draws these strings and
/// nothing else, so the words the operator reads — and which of them appear
/// when — are testable without a window server.
public struct HostOperatorStatus: Equatable {
    public var connection: HostConnectionState
    /// Independent of `connection` in both directions: a code shown while a
    /// machine is connected leaves that machine on screen, and a machine
    /// connecting or disconnecting leaves the code where it is.
    public var pairing: HostPairingState
    public var permissions: HostPermissionRequestResult
    /// Why hosting is not running, when `connection` is `.notHosting` because
    /// something failed rather than because nothing has been tried yet -- a
    /// bind failure, or address auto-detection finding none or more than
    /// one. Kept apart from `connection` for the same reason permissions are:
    /// the words explaining a failure must not depend on every place that
    /// sets `.notHosting` remembering to carry them too.
    public var problem: String?
    /// Why hosting is not running, when the cause is specifically the key
    /// that identifies this machine -- kept apart from `problem` (a plain
    /// string) so the window can offer the two actions that fix it, "Try
    /// again" and "Make a new key," without matching the string a bind
    /// failure or a missing Tailscale connection also happens to set.
    /// Mutually exclusive with `problem` in practice: `reportProblem` and
    /// `reportIdentityProblem` each clear the other.
    public var identityProblem: HostIdentityFailureCopy?
    /// Whether this host process has stopped being able to capture anything
    /// on this machine. True for the rest of the run once it is true: the
    /// state it describes is not one this process can recover from, so the
    /// window must go on saying so rather than returning to a status that
    /// implies a machine ready to serve.
    public var captureUnavailable: Bool = false

    public init(
        connection: HostConnectionState,
        pairing: HostPairingState = .idle,
        permissions: HostPermissionRequestResult,
        problem: String? = nil,
        identityProblem: HostIdentityFailureCopy? = nil
    ) {
        self.connection = connection
        self.pairing = pairing
        self.permissions = permissions
        self.problem = problem
        self.identityProblem = identityProblem
    }
}

/// The shape of the menu-bar icon: what the operator can tell without opening
/// anything.
public enum HostOperatorIndicator: Equatable, Sendable {
    case idle
    case waiting
    case serving
    /// A distinct icon and a menu-bar title: the quiet serving
    /// presentation is too little for a mode nobody re-approves per
    /// session.
    case servingHostScreen
    /// A permission the host needs is missing. Outranks every other case: a
    /// revoked approval is the one thing that makes a live session useless.
    case attention
}

/// One missing permission, with the words for it and the pane that grants it.
public struct HostOperatorPermissionAlert: Equatable, Sendable {
    public let kind: HostPermissionKind
    /// The status-item menu's own title — Title Case, like every other menu
    /// item there.
    public let title: String
    /// The host window's button label for the same alert — sentence case,
    /// like every other button in that window.
    public let windowButtonTitle: String
    /// What stops working until it is granted.
    public let detail: String
    public let settingsURL: String
}

public struct HostOperatorPresentation: Equatable, Sendable {
    public let indicator: HostOperatorIndicator
    /// Text beside the icon in the menu bar, or `nil` for the icon alone.
    public let menuBarTitle: String?
    /// The system's `h6`: uppercase, mono, drawn as the eyebrow.
    public let eyebrow: String
    public let headline: String
    public let detail: String
    /// Present only while a code can still be used. An expired code is
    /// withdrawn rather than left on screen for someone to read aloud.
    public let pairingCode: String?
    public let pairingCountdown: String?
    /// True in the last seconds of a code's life, so the countdown can change
    /// tone. A grey line leaves the panel quietest exactly when the code is
    /// about to die under the operator reading it out.
    public let countdownIsUrgent: Bool
    public let alerts: [HostOperatorPermissionAlert]
    /// True when `eyebrow`/`headline`/`detail` already say Screen Recording
    /// is missing, connected or not. A caller that also lists `alerts`
    /// beneath the status card reads this to skip repeating the same alert
    /// a second time.
    public let screenRecordingReplacesStatusCard: Bool
    /// True when `detail` itself is a warning -- Screen Recording missing
    /// while a machine is connected -- rather than the panel's usual muted
    /// status line.
    public let detailIsWarning: Bool
    /// Set only while `eyebrow`/`headline`/`detail` are this machine's own
    /// identity failure -- the one case `HostSetupWindowController` offers
    /// its "Make a new key" button for.
    public let identityProblem: HostIdentityFailureCopy?

    /// Gold for an eyebrow that says something needs action or failed --
    /// "COULD NOT START", "SCREEN RECORDING NEEDED" -- grey for a neutral
    /// status like "READY". Every surface that draws `eyebrow` reads this
    /// rather than choosing a colour of its own, so the two stay in step.
    public var eyebrowColor: DesignColor {
        switch eyebrow {
        case "COULD NOT START", "SCREEN RECORDING NEEDED":
            return CanvasDesign.warn
        default:
            return CanvasDesign.muted2
        }
    }

    /// Shown under the code and its countdown, in both the host window's
    /// own card and the menu bar's own panel -- whoever reads six digits
    /// aloud needs to say which machine types them.
    public static let pairingCodeHint = "Type it on the machine you are pairing."
}

extension HostOperatorStatus {
    public func presentation(now: Date) -> HostOperatorPresentation {
        var alerts = Self.alerts(for: permissions)
        var eyebrow: String
        var headline: String
        var detail: String
        var code: String?
        var countdown: String?
        var isUrgent = false
        var indicator: HostOperatorIndicator
        // `nil` everywhere but `.servingHostScreen`: every other case either
        // shows no menu-bar title (`.serving`'s deliberately quiet one) or
        // shows the pairing code itself, already carried by `code` below.
        // Kept separate from `code` rather than reusing it, since `code`
        // also feeds `pairingCode` -- a host-screen machine's name is not a
        // pairing code and must never appear where one is read from.
        var menuBarTitle: String?

        switch connection {
        case .notHosting where identityProblem != nil:
            eyebrow = "COULD NOT START"
            headline = identityProblem?.headline ?? ""
            detail = identityProblem?.detail ?? ""
            indicator = .attention
        case .notHosting where problem != nil:
            eyebrow = "COULD NOT START"
            // The two Tailscale problems name their cause, since their
            // details go straight to the remedy; any other problem is
            // its own detail, under a generic headline.
            switch problem {
            case HostStartupProblemCopy.noTailnetAddress:
                headline = "Tailscale is not running"
            case HostStartupProblemCopy.tailscaleNotInstalled:
                headline = "Tailscale is not installed"
            default:
                headline = "Could not start hosting"
            }
            detail = problem ?? ""
            indicator = .attention
        case .notHosting:
            // The GUI starts hosting itself at launch, synchronously, before
            // this status is ever observed on screen -- see `runGUI` in
            // `sensoriumd/main.swift` -- so this line is never actually
            // seen there. It still must not instruct the operator to use a
            // Start Hosting control this app has never offered.
            eyebrow = "STATUS"
            headline = "This machine is not hosting"
            detail = "No machine is connected."
            indicator = .idle
        case .hosting:
            eyebrow = "READY"
            headline = "Waiting for a machine to connect"
            // No detail: the headline already says this, and a pairing
            // request below fills the line in when there is one.
            detail = ""
            indicator = .idle
        case let .pairingApproved(deviceName):
            eyebrow = "WAITING"
            headline = "Waiting for \(deviceName) to finish pairing"
            detail = "Code accepted. \(deviceName) is connecting."
            indicator = .waiting
        case let .serving(peerName):
            eyebrow = "CONNECTED"
            headline = "Connected to \(peerName)"
            detail = "It sees and controls a virtual display, not this machine’s own screen."
            indicator = .serving
        case let .servingHostScreen(peerName, displayName):
            eyebrow = "SHARING HOST SCREEN"
            headline = "Connected to \(peerName)"
            // Deliberately the opposite claim from `.serving`'s: this mode
            // exists precisely because the virtual-display sentence would
            // be false here. Every privacy claim is mode-specific.
            detail = "It sees and controls \(displayName) \u{2014} this machine’s own screen, not a virtual display."
            menuBarTitle = peerName
            indicator = .servingHostScreen
        }

        // The pairing section, read after the connection above and never
        // instead of it: a code is something the operator is doing alongside
        // whatever this machine is already serving.
        if case let .showing(pairingCode, expiresAt, requestingDeviceName) = pairing {
            let remaining = expiresAt.timeIntervalSince(now)
            if remaining > 0 {
                code = Self.grouped(pairingCode)
                countdown = "Expires in \(Self.countdown(seconds: remaining))"
                isUrgent = remaining <= Self.urgentRemainingSeconds
            }
            // An expired code leaves `code` `nil`, the same as never having
            // shown one -- the pairing-code section falls back to its own
            // "Show pairing code" button rather than a second wording here.
            //
            // Naming who is asking is the whole point of showing the code
            // automatically instead of waiting for the operator to reveal it,
            // but it only replaces the ready state's own empty detail: every
            // other state's detail is a claim about what the connected
            // machine can see, which stays true and must not be overwritten.
            if let requestingDeviceName, case .hosting = connection {
                detail = "\(requestingDeviceName) is asking to pair."
            }
        }

        // Outranks every state above, connected or not: a host that cannot
        // capture is not serving whoever is connected, is not waiting usefully
        // for anyone who is not, and has exactly one thing worth saying.
        if captureUnavailable {
            eyebrow = "CAPTURE STOPPED"
            headline = "Quit Sensorium Host and open it again"
            detail = "This machine has stopped handing Sensorium Host any picture to send. "
                + "Opening it again is the only thing that restores it."
            indicator = .attention
        }

        // Screen Recording missing outranks whatever the status card would
        // otherwise say, but only before anyone is connected: mid-session,
        // who is connected matters more, and the permission alert below
        // already says what to do about it.
        let isConnected: Bool
        switch connection {
        case .serving, .servingHostScreen:
            isConnected = true
        case .notHosting, .hosting, .pairingApproved:
            isConnected = false
        }
        var screenRecordingReplacesStatusCard = false
        var detailIsWarning = false
        if !isConnected, let screenRecordingAlert = alerts.first(where: { $0.kind == .screenRecording }) {
            eyebrow = "SCREEN RECORDING NEEDED"
            headline = "Screen Recording is not allowed"
            detail = screenRecordingAlert.detail
            screenRecordingReplacesStatusCard = true
        }
        // Screen Recording missing makes `.serving`'s virtual-display sentence
        // false: there is nothing to see at all, so the status card carries
        // the warning itself rather than a second card repeating it.
        if isConnected, case let .serving(peerName) = connection,
           let screenRecordingIndex = alerts.firstIndex(where: { $0.kind == .screenRecording }) {
            let sentence = "\(peerName) sees nothing until you allow Screen Recording for Sensorium Host in System Settings."
            eyebrow = "SCREEN RECORDING NEEDED"
            detail = sentence
            detailIsWarning = true
            screenRecordingReplacesStatusCard = true
            let alert = alerts[screenRecordingIndex]
            alerts[screenRecordingIndex] = HostOperatorPermissionAlert(
                kind: alert.kind,
                title: alert.title,
                windowButtonTitle: alert.windowButtonTitle,
                detail: sentence,
                settingsURL: alert.settingsURL
            )
        }

        return HostOperatorPresentation(
            indicator: alerts.isEmpty ? indicator : .attention,
            menuBarTitle: menuBarTitle ?? code,
            eyebrow: eyebrow,
            headline: headline,
            detail: detail,
            pairingCode: code,
            pairingCountdown: countdown,
            countdownIsUrgent: isUrgent,
            alerts: alerts,
            screenRecordingReplacesStatusCard: screenRecordingReplacesStatusCard,
            detailIsWarning: detailIsWarning,
            identityProblem: identityProblem
        )
    }

    /// Screen Recording first: without it the other machine sees nothing at all,
    /// which outranks not being able to type into what it cannot see.
    private static func alerts(for permissions: HostPermissionRequestResult) -> [HostOperatorPermissionAlert] {
        var alerts: [HostOperatorPermissionAlert] = []
        if permissions.screenCapture != .granted {
            alerts.append(HostOperatorPermissionAlert(
                kind: .screenRecording,
                title: "Open Screen Recording Settings",
                windowButtonTitle: "Open Screen Recording settings",
                // Names the consequence and where the permission lives, so
                // the sentence stands alone on surfaces without the button.
                detail: "No machine can see a screen until you allow Screen Recording for Sensorium Host in System Settings.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            ))
        }
        if permissions.accessibility != .granted {
            alerts.append(HostOperatorPermissionAlert(
                kind: .accessibility,
                title: "Open Accessibility Settings",
                windowButtonTitle: "Open Accessibility settings",
                detail: "Until you allow Accessibility, your other machine cannot type or click.",
                settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ))
        }
        return alerts
    }

    /// Six digits are read aloud in threes whatever the panel does, and the
    /// grouping is what stops a digit being transcribed into the wrong column
    /// across a room. The viewer's pairing form ignores the separator, so
    /// typing exactly what is shown here succeeds. A code that is not the six
    /// digits `PairingAuthority` issues is shown as it came rather than split
    /// somewhere arbitrary.
    private static func grouped(_ code: String) -> String {
        guard code.count == 6 else {
            return code
        }
        let split = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex..<split]) \(code[split...])"
    }

    /// Long enough to still be worth typing, short enough that saying it
    /// again is the better move. Half a minute of the code's five.
    private static let urgentRemainingSeconds: TimeInterval = 30

    /// Rounded up, so a code with a fraction of a second left never reads
    /// `0:00` while it still works.
    private static func countdown(seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// The one place the host's operator-visible state is assembled, so the menu
/// bar never has to ask three different objects what is happening.
///
/// Activity and permissions are kept apart on purpose: a permission revoked
/// mid-session must not erase who is connected, and a viewer connecting must
/// not erase a warning the operator has not acted on yet.
@MainActor
public final class HostOperatorStatusStore {
    public private(set) var status: HostOperatorStatus
    public var onChange: ((HostOperatorStatus) -> Void)?
    /// A second subscriber slot, so the setup window can watch the same
    /// status the menu bar already owns `onChange` for, without either
    /// silently replacing the other's callback.
    private var observers: [(HostOperatorStatus) -> Void] = []
    /// What the listener is bound to, independent of what is currently shown:
    /// pairing and serving both return here once they end.
    private var hostedAddress: String?
    /// The connection whose session is on screen right now, when one claimed
    /// it. `weak`: this is an identity to compare a later close against, never
    /// something to keep alive.
    private weak var servingConnection: HostConnectionToken?

    public init(permissions: HostPermissionRequestResult) {
        status = HostOperatorStatus(
            connection: .notHosting,
            permissions: permissions
        )
    }

    public func addObserver(_ handler: @escaping (HostOperatorStatus) -> Void) {
        observers.append(handler)
    }

    public func setConnection(_ connection: HostConnectionState) {
        status.connection = connection
        notify()
    }

    /// The listener bound this address. Recorded on its own from
    /// `setConnection` because a connection that ends must show the address
    /// again rather than read as a machine that stopped hosting.
    public func recordHostedAddress(_ address: String) {
        hostedAddress = address
    }

    /// A listener bound with no pairing ceremony to run first -- an
    /// already-paired device just needs to find the host waiting.
    public func beginHosting(address: String) {
        recordHostedAddress(address)
        status.problem = nil
        status.identityProblem = nil
        status.pairing = .idle
        servingConnection = nil
        setConnection(.hosting(address: address))
    }

    /// A `pairRequest` arrived, right code or not. A code still valid is
    /// never rotated here: nothing on the wire may invalidate a code
    /// someone is mid-typing. `requestingDeviceName` holds only the newest
    /// request, one at a time, no queue.
    public func recordPairingRequest(
        deviceName: String,
        now: Date = Date(),
        issueCode: () -> (code: String, expiresAt: Date)
    ) {
        if case let .showing(code, expiresAt, _) = status.pairing, now < expiresAt {
            status.pairing = .showing(code: code, expiresAt: expiresAt, requestingDeviceName: deviceName)
        } else {
            let issued = issueCode()
            status.pairing = .showing(
                code: issued.code,
                expiresAt: issued.expiresAt,
                requestingDeviceName: deviceName
            )
        }
        notify()
    }

    /// A person at this machine asked to read a code out. Says nothing about
    /// who is connected, and so changes nothing about it.
    public func showPairingCode(_ code: String, expiresAt: Date) {
        status.pairing = .showing(code: code, expiresAt: expiresAt)
        notify()
    }

    /// A person at this machine is done reading the code out. Leaves the
    /// connection exactly where it was.
    public func hidePairingCode() {
        status.pairing = .idle
        notify()
    }

    /// A device typed the right code and its key is now trusted. The code is
    /// spent, so it comes off the screen with the same call that reports the
    /// approval -- nobody should still be reading it aloud.
    public func recordPairingApproved(deviceName: String) {
        status.pairing = .idle
        setConnection(.pairingApproved(deviceName: deviceName))
    }

    /// This process can no longer capture anything on this machine. Recorded
    /// rather than shown-and-cleared: nothing that happens next makes it
    /// untrue while this process runs.
    public func recordCaptureUnavailable() {
        status.captureUnavailable = true
        notify()
    }

    /// Stop Hosting: the listener is gone, so nothing is left to fall back to.
    public func stopHosting() {
        hostedAddress = nil
        status.problem = nil
        status.identityProblem = nil
        status.pairing = .idle
        servingConnection = nil
        setConnection(.notHosting)
    }

    /// Hosting could not start -- a bind failure, or address auto-detection
    /// finding none or more than one usable address. Leaves `connection` at
    /// `.notHosting`, since nothing is listening either way.
    public func reportProblem(_ message: String) {
        hostedAddress = nil
        status.problem = message
        status.identityProblem = nil
        status.pairing = .idle
        servingConnection = nil
        setConnection(.notHosting)
    }

    /// Hosting could not start because the file holding the key that
    /// identifies this machine could not be read. A typed value, not a
    /// string a caller has to phrase and this store has to pattern-match
    /// back apart from every other reason hosting can fail.
    public func reportIdentityProblem(_ copy: HostIdentityFailureCopy) {
        hostedAddress = nil
        status.problem = nil
        status.identityProblem = copy
        status.pairing = .idle
        servingConnection = nil
        setConnection(.notHosting)
    }

    /// Clears an identity problem without otherwise touching `connection` --
    /// called just before a fresh attempt to start hosting, so a retry that
    /// is still in flight never reads as "already fixed."
    public func clearIdentityProblem() {
        status.identityProblem = nil
        notify()
    }

    private func notify() {
        onChange?(status)
        for observer in observers {
            observer(status)
        }
    }

    /// Folds a transition the running host detected into the status, without
    /// re-reading either gate: the monitor has already done that read.
    public func apply(_ transition: HostPermissionTransition) {
        switch transition {
        case .lost(.screenRecording):
            status.permissions = HostPermissionRequestResult(
                screenCapture: .approvalRequired,
                accessibility: status.permissions.accessibility
            )
        case .recovered(.screenRecording):
            status.permissions = HostPermissionRequestResult(
                screenCapture: .granted,
                accessibility: status.permissions.accessibility
            )
        case .lost(.accessibility):
            status.permissions = HostPermissionRequestResult(
                screenCapture: status.permissions.screenCapture,
                accessibility: .approvalRequired
            )
        case .recovered(.accessibility):
            status.permissions = HostPermissionRequestResult(
                screenCapture: status.permissions.screenCapture,
                accessibility: .granted
            )
        }
        notify()
    }

    /// A connection ending returns the host to hosting-on-its-address, or, if
    /// the listener has since stopped, to not hosting. Only the connection is
    /// touched: a pairing code on screen outlives any number of connections
    /// attempting it, and wiping it would leave the operator reading a menu
    /// with nothing in it.
    public func apply(_ peer: HostPeerPresence, from connection: HostConnectionToken) {
        switch peer {
        case let .identified(deviceName):
            servingConnection = connection
            setConnection(.serving(peerName: deviceName))
        case .closed:
            switch status.connection {
            case .serving, .servingHostScreen:
                // Only the connection whose session is on screen can take it
                // off again. A connection that has already been replaced ends
                // too, and its ending says nothing about the one that
                // replaced it. Nothing to compare against means nobody
                // claimed this state -- it was set directly rather than by a
                // connection identifying itself -- and any close ends it.
                if let servingConnection, servingConnection !== connection {
                    return
                }
                servingConnection = nil
                setConnection(hostedAddress.map { .hosting(address: $0) } ?? .notHosting)
            case .pairingApproved:
                // Claimed by no connection: an approval comes from the
                // pairing ceremony rather than from a session, so a
                // connection ending here is the approved device giving up.
                setConnection(hostedAddress.map { .hosting(address: $0) } ?? .notHosting)
            case .notHosting, .hosting:
                break
            }
        }
    }
}

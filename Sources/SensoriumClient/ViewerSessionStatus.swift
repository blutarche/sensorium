import Foundation

/// What the viewer window is doing, as the person looking at it would describe
/// it. Deliberately AppKit-free: which words and which status colour belong to
/// each phase is a decision the runners verify without a window.
public enum ViewerSessionPhase: Equatable, Sendable {
    /// A dial is out. Reached only after a session has already been live at
    /// least once in this window's life -- before the first picture the launch
    /// window is the one reporting attempts, on the row of the machine it is
    /// dialling.
    case connecting
    case live
    case reconnecting
    case lost
    /// A host-screen connect that never became a session, refused or
    /// failed -- distinct from `.lost`, since nothing auto-redials here:
    /// nothing is automatic after a failed presence check. The only
    /// way out is the one button this phase's own status carries.
    case ended
}

/// The status palette's four entries, named by meaning rather than by colour so
/// the pure type never has to know a hex value. See `docs/design-system.md`.
public enum ViewerStatusTone: Equatable, Sendable {
    case ok
    case info
    case warn
    case bad
}

/// Everything the window needs to draw one session state.
public struct ViewerSessionStatus: Equatable, Sendable {
    public let phase: ViewerSessionPhase
    public let tone: ViewerStatusTone
    /// The system's `h6`: uppercase mono over the headline.
    public let eyebrow: String
    public let headline: String
    public let detail: String
    /// What the user can do from here, in the order they are shown. Empty
    /// while there is nothing to decide.
    public let buttons: [ViewerSessionButton]

    /// A live session shows nothing over the canvas; every other phase does.
    public var isOverlayVisible: Bool { phase != .live }

    /// Whether the eyebrow's tone dot should pulse -- true only while an
    /// attempt is actually under way, so a person waiting sees it working and
    /// a person on a settled state (live, lost, ended) sees a still dot.
    public var indicatorPulses: Bool { phase == .connecting || phase == .reconnecting }

    /// Whether the picture underneath is stale. A dropped session keeps the
    /// last decoded frame on screen, and an undimmed one is indistinguishable
    /// from a live picture.
    public var dimsCanvas: Bool { phase == .reconnecting || phase == .lost || phase == .ended }
}

/// Something the user can do from the overlay. Every one of these already has
/// a path in the viewer -- none of them is a second implementation of a thing
/// the app can already do.
public enum ViewerSessionAction: Equatable, Sendable {
    case tryAgain
    case stopTrying
    case quit
    /// The `.ended` phase's own single action -- never resumes the target
    /// that just ended, always switches to a session canvas, and only ever
    /// fires on the person's own press: nothing here is automatic.
    case connectAsVirtualDisplay
    /// Offered only when the host's own refusal reason says this machine's
    /// presence credential is missing or unrecognised -- the one `.ended`
    /// case a virtual display alone cannot fix, since re-arming needs the
    /// pairing ceremony.
    case pairAgain
    /// Back to the launch window's list of saved machines -- offered beside Try
    /// again on every state where this machine cannot be reached, so a machine that
    /// will not wake tonight does not strand the person in front of a dead
    /// end. The canvas window closes and that list comes back, exactly as it
    /// was at launch.
    case yourMachines
}

public struct ViewerSessionButton: Equatable, Sendable {
    public let action: ViewerSessionAction
    public let title: String
    /// At most one per state. The accent is for the action that restores the
    /// session, never for the one that ends the wait or the app.
    public let isPrimary: Bool
}

public enum ViewerSessionEvent: Equatable, Sendable {
    case connectStarted
    case canvasReady
    case sessionEnded
    /// The user chose to stop waiting for a host that is not answering.
    case stopRequested
    /// The user asked for another go after stopping, or after the policy gave
    /// up.
    case retryRequested
    case gaveUp
    /// A host-screen connect that never became a session -- refused or
    /// failed -- with its own reason, already turned into words by
    /// `ViewerSessionFailureCopy`/`HostScreenRefusalCopy` before this call:
    /// this state machine holds no wire vocabulary of its own, the same way
    /// `ClientReconnectEvent.attemptFailed`'s text lives outside this type.
    /// `offersPairAgain` is likewise decided by the caller, from the same
    /// raw reason, never by matching `reasonLine`'s translated text here.
    case hostScreenConnectEnded(reasonLine: String, offersPairAgain: Bool)
    /// One dial attempt ended without a session and the reconnect policy is
    /// about to try again -- the already-translated sentence, same
    /// discipline as `hostScreenConnectEnded`: this state machine holds no
    /// wire vocabulary of its own. Shown only while the phase is
    /// `.connecting` or `.reconnecting`, since that is the only time a
    /// person is watching an identical panel with no sign anything was
    /// tried; every other phase ignores it.
    case attemptFailed(reasonLine: String)
    /// A dial ended because the host did not prove it is the machine this one
    /// paired with -- a certificate pin or host key mismatch, already turned
    /// into words by `ViewerSessionFailureCopy`. Terminal like
    /// `hostScreenConnectEnded`: trying again would just repeat the same
    /// failure, since the host that answered is the one that is wrong, not
    /// the attempt. Unlike that event, this offers no virtual-display
    /// fallback -- the canvas was never in question, the host's identity was
    /// -- so re-pinning the key at `.pairAgain` is the only way out.
    case unverifiedHostConnectEnded(reasonLine: String)
    /// A person at the host ended the live session from that machine, with
    /// the already-translated sentence -- same discipline as
    /// `hostScreenConnectEnded`: this state machine holds no wire vocabulary
    /// of its own. Distinct from `sessionEnded`, which describes a link that
    /// dropped: nothing here was lost, and saying so would be wrong about the
    /// one ending somebody chose on purpose.
    case stoppedByHost(reasonLine: String)
    /// The host ended the live session and named a cause, with the
    /// already-translated sentence -- same discipline as `stoppedByHost`:
    /// this state machine holds no wire vocabulary of its own. Distinct from
    /// `sessionEnded` for the same reason that one is: the link did not
    /// drop, and a person who can read the cause can often fix it.
    case hostEnded(reasonLine: String)
}

/// Turns the session lifecycle into the states the window can show, and the
/// buttons each of them offers. Holds no window and no socket, so the whole
/// sequence — first connect, live, drop, redial, stop, try again, give up — is
/// verifiable as a pure event stream.
public struct ViewerSessionStateMachine: Equatable, Sendable {
    /// The host name as it is written on screen, verbatim from the caller.
    private let hostName: String
    /// Dial attempts since the last live canvas, or since the user asked for
    /// another go. Zero while live, so the next outage does not inherit the
    /// previous one's count.
    private var attempt = 0
    private var hasBeenLive = false
    /// The most recent attempt's already-translated failure sentence, or
    /// `nil` before any attempt has failed. Cleared whenever the wait it
    /// describes is over: a canvas came up, the person asked to try again,
    /// or they stopped trying.
    private var lastFailureLine: String?
    public private(set) var status: ViewerSessionStatus

    public init(hostName: String) {
        self.hostName = hostName
        status = Self.connecting(hostName: self.hostName, attempt: 0, lastFailureLine: nil)
    }

    @discardableResult
    public mutating func handle(_ event: ViewerSessionEvent) -> ViewerSessionStatus {
        switch event {
        case .connectStarted:
            attempt += 1
            status = hasBeenLive
                ? reconnecting()
                : Self.connecting(hostName: hostName, attempt: attempt, lastFailureLine: lastFailureLine)
        case let .attemptFailed(reasonLine):
            lastFailureLine = reasonLine
            switch status.phase {
            case .connecting:
                status = ViewerSessionStatus(
                    phase: .connecting,
                    tone: .info,
                    eyebrow: "CONNECTING",
                    headline: "Connecting to \(hostName)…",
                    detail: "Attempt \(attempt) did not connect. \(reasonLine)",
                    buttons: Self.connectingButtons
                )
            case .reconnecting:
                status = reconnecting()
            case .live, .lost, .ended:
                break
            }
        case .canvasReady:
            attempt = 0
            hasBeenLive = true
            lastFailureLine = nil
            status = ViewerSessionStatus(
                phase: .live,
                tone: .ok,
                eyebrow: "SESSION",
                headline: "Connected to \(hostName)",
                detail: "",
                buttons: []
            )
        case .sessionEnded:
            status = ViewerSessionStatus(
                phase: .lost,
                tone: .bad,
                eyebrow: "SESSION LOST",
                headline: "Connection to \(hostName) lost.",
                detail: "The picture behind this is frozen from before the drop.",
                buttons: Self.recoveryButtons
            )
        case let .stoppedByHost(reasonLine):
            // Cleared like `.stopRequested`'s: the last dial did not fail, so
            // there is nothing about an attempt for a later panel to repeat.
            lastFailureLine = nil
            status = ViewerSessionStatus(
                phase: .lost,
                tone: .bad,
                eyebrow: "SESSION ENDED",
                headline: "Stopped at \(hostName).",
                detail: reasonLine,
                // The same way out an ordinary ending offers. Try again is a
                // person pressing it, which is the only thing that may start
                // another session after this one -- `docs/host-screen-design.md`
                // §6.5's "nothing automatic".
                buttons: Self.recoveryButtons
            )
        case let .hostEnded(reasonLine):
            lastFailureLine = nil
            status = ViewerSessionStatus(
                phase: .lost,
                tone: .bad,
                eyebrow: "SESSION ENDED",
                headline: "\(hostName) ended this session.",
                detail: reasonLine,
                buttons: Self.recoveryButtons
            )
        case .stopRequested:
            lastFailureLine = nil
            status = ViewerSessionStatus(
                phase: .lost,
                tone: .bad,
                eyebrow: "STOPPED",
                headline: "Stopped trying to reach \(hostName).",
                detail: "Nothing is being retried now. Choose Try again when that machine is awake, or quit.",
                buttons: Self.recoveryButtons
            )
        case .retryRequested:
            attempt = 0
            lastFailureLine = nil
            status = hasBeenLive
                ? reconnecting()
                : Self.connecting(hostName: hostName, attempt: attempt, lastFailureLine: lastFailureLine)
        case .gaveUp:
            status = ViewerSessionStatus(
                phase: .lost,
                tone: .bad,
                eyebrow: "SESSION LOST",
                headline: "Cannot reach \(hostName).",
                detail: "Sensorium has stopped retrying. Check that it is awake and that Tailscale "
                    + "is connected on both machines, then choose Try again.",
                buttons: Self.recoveryButtons
            )
        case let .hostScreenConnectEnded(reasonLine, offersPairAgain):
            status = ViewerSessionStatus(
                phase: .ended,
                tone: .bad,
                eyebrow: hasBeenLive ? "SESSION ENDED" : "NOT STARTED",
                headline: hasBeenLive
                    ? "The host-screen session with \(hostName) ended."
                    : "Could not show a host screen from \(hostName).",
                detail: reasonLine,
                buttons: offersPairAgain ? Self.endedOfferingPairAgainButtons : Self.endedButtons
            )
        case let .unverifiedHostConnectEnded(reasonLine):
            lastFailureLine = nil
            status = ViewerSessionStatus(
                phase: .ended,
                tone: .bad,
                eyebrow: "NOT CONNECTED",
                headline: "Could not connect to \(hostName).",
                detail: reasonLine,
                buttons: Self.unverifiedHostButtons
            )
        }
        return status
    }

    /// The way out, the list, and the way back. The accent goes on the one
    /// that restores the session, which sits rightmost as the row's filled
    /// default -- the way macOS itself places one in a horizontal row.
    /// Quitting is the same latch the menu bar's Quit fires, not a second way
    /// to leave.
    private static let recoveryButtons = [
        ViewerSessionButton(action: .quit, title: "Quit Sensorium", isPrimary: false),
        ViewerSessionButton(action: .yourMachines, title: "Your machines", isPrimary: false),
        ViewerSessionButton(action: .tryAgain, title: "Try again", isPrimary: true)
    ]

    private static let connectingButtons = [
        ViewerSessionButton(action: .quit, title: "Quit Sensorium", isPrimary: false),
        ViewerSessionButton(action: .yourMachines, title: "Your machines", isPrimary: false)
    ]

    /// `Stop trying` is what makes a reconnect wait finite -- the retry
    /// policy itself has no attempt limit.
    private static let reconnectingButtons = [
        ViewerSessionButton(action: .quit, title: "Quit Sensorium", isPrimary: false),
        ViewerSessionButton(action: .stopTrying, title: "Stop trying", isPrimary: false)
    ]

    /// A refusal is a dead end without the list beside it: the machine that
    /// refused may stay that way all night. The filled default sits
    /// rightmost, the way macOS itself places a default button in a
    /// horizontal row.
    private static let endedButtons = [
        ViewerSessionButton(action: .yourMachines, title: "Your machines", isPrimary: false),
        ViewerSessionButton(
            action: .connectAsVirtualDisplay, title: "Connect with a virtual display", isPrimary: true
        )
    ]

    private static let endedOfferingPairAgainButtons = [
        ViewerSessionButton(action: .yourMachines, title: "Your machines", isPrimary: false),
        ViewerSessionButton(
            action: .connectAsVirtualDisplay, title: "Connect with a virtual display", isPrimary: false
        ),
        ViewerSessionButton(action: .pairAgain, title: "Pair again", isPrimary: true)
    ]

    /// A certificate pin or host key mismatch is security-relevant and
    /// terminal: re-pinning the key is the only fix, so it leads, and it is
    /// the accent -- the accent is for the action that restores the session,
    /// and pairing again is the only one here that can.
    private static let unverifiedHostButtons = [
        ViewerSessionButton(action: .quit, title: "Quit Sensorium", isPrimary: false),
        ViewerSessionButton(action: .yourMachines, title: "Your machines", isPrimary: false),
        ViewerSessionButton(action: .pairAgain, title: "Pair again", isPrimary: true)
    ]

    /// Every button row a status can carry, by title. The status panel is
    /// sized once, for the whole session, to the widest of these, so its
    /// width does not jump between states; a new row belongs here too, and
    /// the runner checks that every state's row is listed.
    public static let buttonRows: [[String]] = [
        connectingButtons,
        reconnectingButtons,
        recoveryButtons,
        endedButtons,
        endedOfferingPairAgainButtons,
        unverifiedHostButtons
    ].map { $0.map(\.title) }

    /// The first attempt has nothing yet to report. Once an earlier attempt
    /// has failed, every later
    /// `.connectStarted` -- the moment a fresh attempt begins -- names the
    /// attempt and repeats why the last one did not connect, so the panel
    /// keeps changing instead of sitting on an identical wait; see
    /// `.attemptFailed`'s own render for what the panel says while that
    /// attempt is still outstanding.
    private static func connecting(hostName: String, attempt: Int, lastFailureLine: String?) -> ViewerSessionStatus {
        ViewerSessionStatus(
            phase: .connecting,
            tone: .info,
            eyebrow: "CONNECTING",
            headline: "Connecting to \(hostName)…",
            detail: lastFailureLine.map { "Attempt \(attempt) is under way. Last attempt: \($0)" }
                ?? "The picture appears here as soon as the connection is up.",
            buttons: connectingButtons
        )
    }

    /// Always numbered: an unnumbered "trying again" is indistinguishable from
    /// a wait that is going nowhere. A repeat also says what to go check,
    /// because by then the answer is on the other machine and not in this
    /// window. The headline names the host; the detail says "it". Once an
    /// attempt has failed, its already-translated sentence is appended after
    /// the usual detail rather than replacing it, so the numbering and the
    /// standing advice both stay put.
    private func reconnecting() -> ViewerSessionStatus {
        let shown = max(attempt, 1)
        var detail = shown <= 1
            ? "Attempt 1 to reach it. The picture behind this is frozen from before the drop."
            : "Attempt \(shown) to reach it. If it does not come back, check that it is awake and on the same network."
        if let lastFailureLine {
            detail += " \(lastFailureLine)"
        }
        return ViewerSessionStatus(
            phase: .reconnecting,
            tone: .warn,
            eyebrow: "RECONNECTING",
            headline: "Reconnecting to \(hostName)…",
            detail: detail,
            buttons: Self.reconnectingButtons
        )
    }
}

/// Where the keyboard should land while a status row is up: the primary
/// action if there is one, otherwise the first action that is not Quit,
/// otherwise nothing -- so a stray Return never quits Sensorium while it is
/// still trying, and a row of only Quit leaves the canvas holding focus.
public enum ViewerFocusPolicy {
    public static func chosenIndex(
        among buttons: [(action: ViewerSessionAction, isPrimary: Bool)]
    ) -> Int? {
        if let primary = buttons.firstIndex(where: \.isPrimary) {
            return primary
        }
        return buttons.firstIndex { $0.action != .quit }
    }
}

/// Which `show()` may take the user's focus. The first one must — otherwise the
/// window opens behind whatever they were doing — and no later one may, because
/// a reconnect that steals focus rips them out of the local work they moved on
/// to during the outage.
public struct ViewerActivationPolicy: Equatable, Sendable {
    private var hasActivated = false

    public init() {}

    public mutating func shouldActivate() -> Bool {
        defer { hasActivated = true }
        return !hasActivated
    }
}

import Foundation
import SensoriumCore

/// Everything the viewer's application controller asks of the machine it is
/// running on. One protocol per surface, so a platform supplies the windows,
/// the loop and the file locations it actually has, and the controller
/// itself -- every decision about when to dial, what to show and what to
/// persist -- is written once.

/// The launch window, as the controller drives it: docs/ux-spec.md's *Your
/// Machines*. Nothing here draws; the whole list, its row states and its two
/// pairing steps are decided by `YourMachinesWindowModel`, which the runners
/// verify without a window.
@MainActor
public protocol ViewerLaunchWindow: AnyObject {
    func show()
    func hide()
    /// Back to the list, whichever of the two pairing steps was on screen.
    func showList()
    /// Names a row without dialling it -- the `sensorium://enter/<host>` path.
    func select(hostPublicKey: Data)
    func connectRequested(hostPublicKey: Data)
    func connectStarted(hostPublicKey: Data)
    func attemptFailed(reason: String, offersConnectAsVirtualDisplayFallback: Bool)
    func stoppedConnecting(hostPublicKey: Data)
    func stoppedTrying()
    /// Opens this machine's own code step, the way the session panel's
    /// "Pair again" button asks for it.
    func beginPairAgain(with host: SavedHost)

    var loadTailnet: (() async -> TailnetDevicePickerState)? { get set }
    var sendPairIntent: ((ViewerPairingDevice) async -> ViewerPairIntentAttempt)? { get set }
    var pair: ((ViewerPairingDevice?, ViewerPairingSubmission) async -> ViewerPairingResult)? { get set }
    var onConnect: ((SavedHost) -> Void)? { get set }
    var onCancelConnecting: (() -> Void)? { get set }
    var onConnectAsVirtualDisplayFallback: ((Data) -> Void)? { get set }
    var onCloseRequested: (() -> Void)? { get set }
    var onCodeStepAbandoned: (() -> Void)? { get set }
}

/// A session window, as the controller drives it, beyond the media path
/// `SessionCanvasWindow` already covers: the status overlay, the four menus
/// and the transient notices.
///
/// Every word and every enablement decision behind these calls is made by a
/// portable model -- `ViewerSessionStateMachine`, `ScreenMenuPlan`,
/// `DisplayCountMenuPlan` -- so a conformer renders what it is handed and
/// decides nothing.
@MainActor
public protocol SessionWindowChrome: ShortcutForwardingTarget {
    /// Points this window at a freshly connected session, reusing the surface
    /// the person is already looking at rather than opening a new one.
    func attach(session: ClientSessionController) async
    /// Puts the window on screen. Called at the first decoded frame and
    /// nowhere else -- a dial with nothing to look at yet shows no window.
    func show() async
    func close()
    /// Offsets a second canvas from the first, so it does not open exactly on
    /// top of it. Does nothing once this window has a remembered place.
    func cascadeIfUnplaced(from other: any SessionWindowChrome)
    func updateTitle(_ title: String)
    func apply(status: ViewerSessionStatus)
    func updateDisplayCount(_ count: Int)
    func updateIsHostScreenSession(_ isHostScreenSession: Bool)
    func updateScreenMenu(displays: [HostScreenListEntry], selectedToken: Data?)
    func updateHostScreenModes(_ modes: [HostScreenModeEntry], currentModeID: String?)
    func updateStartTargetPreference(_ preference: StartTarget)
    func updateClipboardSharingEnabled(_ enabled: Bool)
    func showDisplayCountRefusal(reason: String)
    func showHostScreenModeRefusal(_ line: String)
    /// A clipboard that was not shared, from either machine. The session is
    /// otherwise fine.
    func showClipboardRefusal(_ line: String)

    var onCloseRequested: (() -> Void)? { get set }
    var onSessionAction: ((ViewerSessionAction) -> Void)? { get set }
    var onSelectDisplayCount: ((Int) -> Void)? { get set }
    var onSelectRealScreen: ((Data?) -> Void)? { get set }
    var onSelectHostScreenMode: ((String) -> Void)? { get set }
    var onSelectClipboardSharing: ((Bool) -> Void)? { get set }
    var onSelectStartTarget: ((StartTarget) -> Void)? { get set }
}

/// One session window, whole: the media path and the chrome around it.
public typealias ViewerSessionWindow = SessionCanvasWindow & SessionWindowChrome

/// Builds the session windows a run needs. A session opens at most two, and
/// this is the only place either one comes from.
@MainActor
public protocol SessionWindowFactory: AnyObject {
    /// `hostName` is the machine being worked on, as the shortcut strip names
    /// it in every tooltip -- not the name of the machine this viewer runs on.
    func makeSessionWindow(
        title: String,
        session: ClientSessionController,
        surfaceID: UInt32,
        hostName: String,
        shortcutMode: SystemShortcutMode,
        initialStreamScalePreference: StreamScalePreference,
        savedHostStore: any SavedHostStoring,
        savedHostPublicKey: Data
    ) throws -> any ViewerSessionWindow
}

/// Whatever else on this platform has to know which session windows exist --
/// on macOS, the menu bar, so a View-menu toggle acts on whichever window has
/// focus.
@MainActor
public protocol ViewerWindowRegistry: AnyObject {
    func register(_ window: any ViewerSessionWindow)
    func unregister(_ window: any ViewerSessionWindow)
}

/// The platform's own event loop. The session runs on a task while this takes
/// over the thread it was started on, and hands control back when the task
/// asks it to.
@MainActor
public protocol ViewerEventLoop: AnyObject {
    func run()
    func stop()
}

/// What the person chose on the screen shown when this machine's key cannot
/// be read.
public enum ViewerStartupFailureChoice: Equatable, Sendable {
    case quit
    /// Read the key again.
    case tryAgain
    /// Replace it, which is one-way and makes every pairing worthless.
    case replaceIdentity
}

/// The two things the controller has to ask a person outside a window of its
/// own.
@MainActor
public protocol ViewerPrompts: AnyObject, Sendable {
    /// Shows why the viewer cannot start and returns what the person chose.
    func showStartupFailure(_ prompt: ViewerStartupFailurePrompt) async -> ViewerStartupFailureChoice
    /// Takes that screen away, so quitting while it is up is not blocked
    /// behind it. Does nothing when it is not up.
    func dismissStartupFailure()
    /// Replacing this machine's key is one-way, so the tap that does it is
    /// confirmed once more first.
    func confirmNewKey() async -> Bool
    /// Shows one thing the person should know before they start, with a
    /// single button that takes it away. Never a question: whatever it
    /// describes, the viewer behind it already works, so a platform that
    /// shows nothing returns at once and loses nothing.
    func showNotice(_ notice: ViewerNotice) async
}

/// Where this platform keeps the viewer's files, what it calls this machine,
/// and the handful of local facilities a session needs that are not a window.
@MainActor
public protocol ViewerPlatformEnvironment: AnyObject {
    /// The directory the four viewer files live in, created if it is missing
    /// by whoever writes into it.
    func applicationSupportDirectory() -> URL
    /// What this machine calls itself, as the host will list it.
    func deviceName() -> String
    /// The system clipboard this platform offers, behind the engine that
    /// decides what may cross.
    func makePasteboard() -> any ClipboardPasteboard
    /// The shortcut forwarder for this run, already holding whatever
    /// permission probe and interceptor this platform has -- or none, on a
    /// platform with neither.
    func makeShortcutForwarder(mode: SystemShortcutMode) -> SystemShortcutForwarder
    /// Whether this platform has already been allowed to see the shortcuts
    /// the window server would otherwise take first. Always `true` where no
    /// such permission exists.
    var isShortcutInterceptionGranted: Bool { get }
    /// Where the Tailscale app is installed, or `nil` where it is not
    /// installed or the platform has no app to find.
    func tailscaleAppURL() -> URL?
    /// Opens it. Does nothing where `tailscaleAppURL()` is always `nil`.
    func openTailscaleApp(_ url: URL)
}

/// Dials one machine. The viewer's QUIC stack differs per platform; which
/// host and which pinned certificate it dials with does not.
public protocol ViewerTransportFactory: Sendable {
    func makeConnection(
        host: String,
        port: UInt16,
        tlsCertificateHash: Data?,
        transport: ClientTransportKind
    ) -> any ClientControlConnection
}

/// The platform's own windows and loop, handed over together so the
/// controller builds none of them and the parse that precedes them can still
/// refuse before any window exists.
@MainActor
public struct ViewerGUI {
    public let launch: any ViewerLaunchWindow
    public let prompts: any ViewerPrompts
    public let eventLoop: any ViewerEventLoop
    public let windowFactory: any SessionWindowFactory
    public let windowRegistry: any ViewerWindowRegistry

    public init(
        launch: any ViewerLaunchWindow,
        prompts: any ViewerPrompts,
        eventLoop: any ViewerEventLoop,
        windowFactory: any SessionWindowFactory,
        windowRegistry: any ViewerWindowRegistry
    ) {
        self.launch = launch
        self.prompts = prompts
        self.eventLoop = eventLoop
        self.windowFactory = windowFactory
        self.windowRegistry = windowRegistry
    }
}

/// The screen shown when this machine's key cannot be read, in words. Kept
/// here rather than in a window so both platforms say the same thing.
public struct ViewerStartupFailurePrompt: Equatable, Sendable {
    public let eyebrow: String
    public let headline: String
    public let detail: String
    public let tryAgainTitle: String
    public let replaceTitle: String
    public let quitTitle: String

    public static func make(for copy: ViewerStartupFailureCopy) -> ViewerStartupFailurePrompt {
        ViewerStartupFailurePrompt(
            eyebrow: "CANNOT START",
            headline: copy.headline,
            detail: copy.detail + "\n\n" + copy.replaceConsequence,
            tryAgainTitle: copy.retryButtonTitle,
            replaceTitle: copy.replaceButtonTitle,
            quitTitle: "Quit Sensorium"
        )
    }
}

/// Replacing this machine's key is one-way, and the screen that offers it has
/// already said so, but a tap that landed before that sank in gets one more
/// chance to back out.
public enum ViewerNewKeyConfirmation {
    public static let question = "Make a new key?"
    public static let detail = "The host will ask for a pairing code again."
    public static let confirmTitle = "Make a new key"
    public static let cancelTitle = "Cancel"
}

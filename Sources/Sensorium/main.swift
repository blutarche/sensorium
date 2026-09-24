#if canImport(AppKit)
import AppKit
import Foundation
import Network
import SensoriumClient
import SensoriumCore

/// macOS's own answers to `ViewerPlatformEnvironment`: where the four viewer
/// files live, what this machine calls itself, and the two local facilities a
/// session needs that are not a window.
@MainActor
final class AppKitViewerEnvironment: ViewerPlatformEnvironment {
    func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sensorium", isDirectory: true)
    }

    func deviceName() -> String {
        Host.current().localizedName ?? "This machine"
    }

    func makePasteboard() -> any ClipboardPasteboard {
        SystemPasteboard()
    }

    func makeShortcutForwarder(mode: SystemShortcutMode) -> SystemShortcutForwarder {
        SystemShortcutForwarder(
            mode: mode,
            accessibility: SystemAccessibilityAuthorization(),
            interceptor: CoreGraphicsShortcutInterceptor()
        )
    }

    var isShortcutInterceptionGranted: Bool {
        SystemAccessibilityAuthorization().isAccessibilityGranted
    }

    /// Tailscale's own bundle identifiers, macsys (the system-extension build)
    /// checked first: whichever one is actually installed is the one this
    /// machine has. The same pair the host's own setup window uses.
    func tailscaleAppURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys")
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos")
    }

    func openTailscaleApp(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}

/// The Network framework's QUIC stack, behind the dial the controller names.
struct NetworkViewerTransportFactory: ViewerTransportFactory {
    func makeConnection(
        host: String,
        port: UInt16,
        tlsCertificateHash: Data?,
        transport: ClientTransportKind
    ) -> any ClientControlConnection {
        // A zero port never reaches here: every caller refuses it in words
        // the person can act on first.
        NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? .any,
            tlsCertificateHash: tlsCertificateHash,
            transport: transport
        )
    }
}

/// `NSApplication` as the controller's event loop.
@MainActor
final class AppKitViewerEventLoop: ViewerEventLoop {
    private let application: NSApplication

    init(application: NSApplication) {
        self.application = application
    }

    func run() {
        application.run()
    }

    /// `NSApplication.stop(_:)` only takes effect the next time the run loop
    /// dequeues an event, so a real one must follow it or `run()` would keep
    /// waiting for input that will never arrive.
    func stop() {
        application.stop(nil)
        if let event = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            application.postEvent(event, atStart: true)
        }
    }
}

/// Builds the AppKit canvas windows.
///
/// Owns the one focus reporter the whole run shares: which canvas the user is
/// looking at is a property of the session, so both windows must deduplicate
/// their focus reports against the same state.
@MainActor
final class AppKitSessionWindowFactory: SessionWindowFactory {
    private let focusReporter = ViewerFocusReporter()

    func makeSessionWindow(
        title: String,
        session: ClientSessionController,
        surfaceID: UInt32,
        hostName: String,
        shortcutMode: SystemShortcutMode,
        initialStreamScalePreference: StreamScalePreference,
        savedHostStore: any SavedHostStoring,
        savedHostPublicKey: Data
    ) throws -> any ViewerSessionWindow {
        try ClientCanvasWindowController(
            title: title,
            session: session,
            surfaceID: surfaceID,
            macName: hostName,
            focusReporter: focusReporter,
            shortcutMode: shortcutMode,
            initialStreamScalePreference: initialStreamScalePreference,
            savedHostStore: savedHostStore,
            savedHostPublicKey: savedHostPublicKey
        )
    }
}

/// The menu bar is what has to know which windows exist: a View-menu toggle
/// acts on whichever one has focus.
@MainActor
final class AppKitViewerWindowRegistry: ViewerWindowRegistry {
    private let menu: ViewerMainMenuController

    init(menu: ViewerMainMenuController) {
        self.menu = menu
    }

    func register(_ window: any ViewerSessionWindow) {
        guard let target = window as? any ViewerMenuCommandTarget else { return }
        menu.register(target)
    }

    func unregister(_ window: any ViewerSessionWindow) {
        guard let target = window as? any ViewerMenuCommandTarget else { return }
        menu.unregister(target)
    }
}

/// The two things the controller has to ask outside a window of its own.
@MainActor
final class AppKitViewerPrompts: ViewerPrompts {
    private var startupFailure: ViewerMessageWindowController?

    func showStartupFailure(_ prompt: ViewerStartupFailurePrompt) async -> ViewerStartupFailureChoice {
        let message = ViewerMessageWindowController(
            eyebrow: prompt.eyebrow,
            headline: prompt.headline,
            detail: prompt.detail,
            actionTitle: prompt.tryAgainTitle,
            // Trying again is never destructive, so Return activates it; only
            // replacing this machine's identity is, and Return must not fire
            // that by accident.
            actionIsDefault: true,
            secondaryActionTitle: prompt.replaceTitle,
            dismissTitle: prompt.quitTitle
        )
        startupFailure = message
        defer { startupFailure = nil }
        switch await message.run() {
        case .dismissed: return .quit
        case .actionTapped: return .tryAgain
        case .secondaryActionTapped: return .replaceIdentity
        }
    }

    func dismissStartupFailure() {
        startupFailure?.dismiss()
    }

    func confirmNewKey() async -> Bool {
        let confirm = NSAlert()
        confirm.messageText = ViewerNewKeyConfirmation.question
        confirm.informativeText = ViewerNewKeyConfirmation.detail
        confirm.addButton(withTitle: ViewerNewKeyConfirmation.confirmTitle)
        confirm.addButton(withTitle: ViewerNewKeyConfirmation.cancelTitle)
        return confirm.runModal() == .alertFirstButtonReturn
    }

    /// Nothing on this platform raises one: the launch notices belong to the
    /// Linux viewer, whose hardware question macOS answers for itself.
    func showNotice(_ notice: ViewerNotice) async {}
}

@main
@MainActor
struct Sensorium {
    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let environment = AppKitViewerEnvironment()
        let quit = QuitSignal()
        let application = NSApplication.shared
        let viewer = ViewerApplication(
            environment: environment,
            transports: NetworkViewerTransportFactory(),
            quit: quit
        ) {
            let launch = YourMachinesWindowController(
                store: FileSavedHostStore(
                    url: environment.applicationSupportDirectory().appendingPathComponent("saved-host.json")
                ),
                tailscaleAppURLLookup: { environment.tailscaleAppURL() },
                onOpenTailscaleApp: { environment.openTailscaleApp($0) }
            )
            launch.loadTailnet = {
                await TailnetDevicePickerLoader(provider: LocalTailscaleStatusProvider()).load()
            }
            // Installed before the first window is on screen: the menu bar is
            // how a person quits, and a viewer that has no machine yet, or
            // cannot reach the one it has, must still be quittable.
            let menu = ViewerMainMenuController(
                onQuit: { quit.fire() },
                onShowYourMachines: {
                    launch.showList()
                    launch.show()
                }
            )
            menu.install(into: application)
            return ViewerGUI(
                launch: launch,
                prompts: AppKitViewerPrompts(),
                eventLoop: AppKitViewerEventLoop(application: application),
                windowFactory: AppKitSessionWindowFactory(),
                windowRegistry: AppKitViewerWindowRegistry(menu: menu)
            )
        }
        await viewer.run(arguments: Array(CommandLine.arguments.dropFirst()))
    }
}
#else
import Foundation
import SensoriumClient
import SensoriumCore

/// The QUIC stack a Linux viewer dials with. There is one: this platform has
/// no local-verification transport, so `--transport tcp-local-verification`
/// finds nothing here to drop TLS with.
struct OpenSSLViewerTransportFactory: ViewerTransportFactory {
    func makeConnection(
        host: String,
        port: UInt16,
        tlsCertificateHash: Data?,
        transport: ClientTransportKind
    ) -> any ClientControlConnection {
        OpenSSLQUICConnection(host: host, port: port, tlsCertificateHash: tlsCertificateHash)
    }
}

@main
@MainActor
struct Sensorium {
    static func main() async {
        // Before this actor has ever suspended, and before any window: the
        // event loop can only take over the process's main queue while the
        // queue is still bound to the thread it started on -- see
        // `GLibMainLoop`. Nothing about it needs a display, so the `pair` verb
        // and a usage error reach their answer through it untouched.
        GLibMainLoop.attachMainQueue()
        let environment = LinuxViewerEnvironment()
        let quit = QuitSignal()
        let savedHosts = FileSavedHostStore(
            url: environment.applicationSupportDirectory().appendingPathComponent("saved-host.json")
        )
        let viewer = ViewerApplication(
            environment: environment,
            transports: OpenSSLViewerTransportFactory(),
            quit: quit
        ) {
            let launch = GtkYourMachinesWindow(store: savedHosts)
            launch.loadTailnet = {
                await TailnetDevicePickerLoader(
                    provider: LocalTailscaleStatusProvider(),
                    // Tailscale is a daemon here, with no application to
                    // open and no download this app can point at.
                    installHint: TailnetDevicePickerFetchError.linuxInstallHint
                ).load()
            }
            let prompts = GtkViewerPrompts(launchWindow: launch)
            // What this machine cannot do, said once, before any machine has
            // been reached. None of it stops pairing or a session: each
            // notice is a sentence and a button that takes it away.
            for notice in ViewerFirstRunNotices.notices(
                arguments: Array(CommandLine.arguments.dropFirst()),
                capabilities: LinuxDecoderCapabilityProbe()
            ) {
                Task { @MainActor in await prompts.showNotice(notice) }
            }
            return ViewerGUI(
                launch: launch,
                prompts: prompts,
                eventLoop: GLibViewerEventLoop(),
                windowFactory: LinuxSessionWindowFactory(
                    tracesPresentation: CommandLine.arguments.contains("--trace")
                ),
                windowRegistry: LinuxViewerWindowRegistry(environment: environment)
            )
        }
        await viewer.run(arguments: Array(CommandLine.arguments.dropFirst()))
    }
}

#endif

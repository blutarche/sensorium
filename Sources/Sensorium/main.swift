#if canImport(AppKit)
import AppKit
import Foundation
import Network
import SensoriumClient
import SensoriumCore
import SensoriumUpdate

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
        ViewerNewKeyAlert.isConfirmed(ViewerNewKeyAlert.make().runModal())
    }

    /// Nothing on this platform raises one: the launch notices belong to the
    /// Linux viewer, whose hardware question macOS answers for itself.
    func showNotice(_ notice: ViewerNotice) async {}
}

@main
@MainActor
struct Sensorium {
    // `NSApplication.delegate` does not retain its delegate, and nothing
    // else in this run holds one either.
    private static var applicationDelegate: ViewerApplicationDelegate?
    /// Nil in a build with no release version, and for the `pair` verb.
    private static var updater: ViewerUpdater?

    static func main() async {
        setvbuf(stdout, nil, _IOLBF, 0)
        let environment = AppKitViewerEnvironment()
        guard case let .viewer(arguments, replacing) = ViewerLaunchRoute.route(Array(CommandLine.arguments.dropFirst())) else {
            UpdateLaunchCommand.runSelfTest {
                ViewerUpdateSelfTest.run(applicationSupportDirectory: environment.applicationSupportDirectory())
            }
        }
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
            let updater = ViewerUpdater.make(
                bundle: .main,
                applicationSupportDirectory: environment.applicationSupportDirectory(),
                replacing: replacing,
                onTerminate: { quit.fire() }
            )
            Self.updater = updater
            if let updater {
                launch.setUpdateLine(updater.line)
                updater.onLineChange = { launch.setUpdateLine($0) }
                launch.onDidShow = { updater.windowDidShow() }
                launch.onRestartNow = { Task { await updater.restartNow() } }
            }
            // Installed before the first window is on screen: the menu bar is
            // how a person quits, and a viewer that has no machine yet, or
            // cannot reach the one it has, must still be quittable.
            let menu = ViewerMainMenuController(
                onQuit: { quit.fire() },
                onShowYourMachines: {
                    launch.showList()
                    launch.show()
                },
                updates: updater.map { updater in
                    ViewerUpdateMenuActions(
                        checksAutomatically: { updater.checksAutomatically },
                        // Your Machines is where the answer is shown.
                        checkForUpdates: {
                            launch.show()
                            Task { await updater.checkForUpdates() }
                        },
                        setChecksAutomatically: { updater.setChecksAutomatically($0) }
                    )
                }
            )
            menu.install(into: application)
            let delegate = ViewerApplicationDelegate(onReopenWithNoWindows: {
                launch.showList()
                launch.show()
            })
            if let updater {
                delegate.beforeTerminate = { updater.prepareToTerminate(then: $0) }
            }
            applicationDelegate = delegate
            application.delegate = delegate
            updater?.start()
            return ViewerGUI(
                launch: launch,
                prompts: AppKitViewerPrompts(),
                eventLoop: AppKitViewerEventLoop(application: application),
                windowFactory: AppKitSessionWindowFactory(),
                windowRegistry: AppKitViewerWindowRegistry(menu: menu)
            )
        }
        viewer.onSessionRunChange = { Self.updater?.sessionRunChanged($0) }
        await viewer.run(arguments: arguments)
        // The event loop has ended. A quit from the Dock, a logout or an
        // Apple Event never reaches this line; the delegate's
        // `beforeTerminate` covers those.
        await Self.updater?.finishBeforeQuit()
    }
}
#else
import Foundation
import FoundationNetworking
import SensoriumClient
import SensoriumCore
import SensoriumLinuxUpdate

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

/// The Linux viewer's real update transport: an ephemeral session that keeps
/// no cookies, cache or credentials, names itself with
/// `LinuxUpdateReleaseLocation.userAgent`, gives up on a request after
/// `LinuxUpdateReleaseLocation.timeout` and on a whole transfer at its
/// deadline, follows only https redirects, and cancels a response the moment
/// it passes the caller's cap. GitHub answers every release address with a
/// redirect to its file host; integrity rests on the manifest's signature
/// and the archive's SHA-256, not on which server answered.
struct URLSessionLinuxUpdateTransport: LinuxUpdateTransport {
    static func makeConfiguration(deadline: TimeInterval) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = LinuxUpdateReleaseLocation.timeout
        configuration.timeoutIntervalForResource = deadline
        configuration.httpAdditionalHeaders = ["User-Agent": LinuxUpdateReleaseLocation.userAgent]
        return configuration
    }

    func fetch(_ url: URL, maximumBytes: Int) async throws -> Data {
        let sink = LinuxMemorySink()
        try await transfer(url, maximumBytes: Int64(maximumBytes), deadline: LinuxUpdateReleaseLocation.smallFileDeadline, into: sink)
        return sink.data
    }

    func download(_ url: URL, to destination: URL, maximumBytes: Int64) async throws {
        let descriptor = open(destination.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard descriptor >= 0 else {
            throw LinuxUpdateTransportError.failed("could not create \(destination.lastPathComponent)")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try await transfer(url, maximumBytes: maximumBytes, deadline: LinuxUpdateReleaseLocation.archiveDeadline, into: LinuxFileSink(handle: handle))
        try handle.synchronize()
    }

    private func transfer(_ url: URL, maximumBytes: Int64, deadline: TimeInterval, into sink: any LinuxTransferSink) async throws {
        guard url.scheme == "https" else {
            throw LinuxUpdateTransportError.failed("only https addresses are fetched")
        }
        var request = URLRequest(url: url)
        request.setValue(LinuxUpdateReleaseLocation.userAgent, forHTTPHeaderField: "User-Agent")
        let delegate = LinuxCappedTransferDelegate(maximumBytes: maximumBytes, sink: sink)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: Self.makeConfiguration(deadline: deadline), delegate: delegate, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        // The task is also cancelled at the deadline, so the deadline holds
        // whatever the session makes of its resource timeout.
        let expiry = DispatchWorkItem { task.cancel() }
        defer { expiry.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            delegate.continuation = continuation
            task.resume()
            DispatchQueue.global().asyncAfter(deadline: .now() + deadline, execute: expiry)
        }
    }
}

private protocol LinuxTransferSink: AnyObject, Sendable {
    func write(_ data: Data) throws
}

private final class LinuxMemorySink: LinuxTransferSink, @unchecked Sendable {
    private(set) var data = Data()
    func write(_ chunk: Data) { data.append(chunk) }
}

private final class LinuxFileSink: LinuxTransferSink, @unchecked Sendable {
    let handle: FileHandle
    init(handle: FileHandle) { self.handle = handle }
    func write(_ chunk: Data) throws { try handle.write(contentsOf: chunk) }
}

/// Counts bytes as they arrive and cancels the task past the cap, so an
/// oversized or endless response never lands in memory or on disk. Every
/// callback runs on the session's one serial delegate queue.
private final class LinuxCappedTransferDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let maximumBytes: Int64
    let sink: any LinuxTransferSink
    var continuation: CheckedContinuation<Void, any Error>?
    private var received: Int64 = 0
    private var failure: LinuxUpdateTransportError?

    init(maximumBytes: Int64, sink: any LinuxTransferSink) {
        self.maximumBytes = maximumBytes
        self.sink = sink
    }

    /// A redirect to anything but https is not followed, which leaves the
    /// redirect itself as the response, refused below by its status.
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(request.url?.scheme == "https" ? request : nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            failure = .badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
            return completionHandler(.cancel)
        }
        if response.expectedContentLength > maximumBytes {
            failure = .tooLarge
            return completionHandler(.cancel)
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard failure == nil else { return }
        received += Int64(data.count)
        guard received <= maximumBytes else {
            failure = .tooLarge
            return dataTask.cancel()
        }
        do {
            try sink.write(data)
        } catch {
            failure = .failed("could not write the download")
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = continuation
        self.continuation = nil
        if let failure {
            continuation?.resume(throwing: failure)
        } else if let error {
            continuation?.resume(throwing: LinuxUpdateTransportError.failed(error.localizedDescription))
        } else {
            continuation?.resume()
        }
    }
}

@main
@MainActor
struct Sensorium {
    /// Nil in a build with no release version.
    private static var updater: LinuxViewerUpdater?

    static func main() async {
        // The self-test a staged update is run with, answered before
        // anything else: it reads the saved machines and this machine's key
        // without changing them, and needs no display.
        guard case let .viewer(arguments, replacing) = ViewerLaunchRoute.route(Array(CommandLine.arguments.dropFirst())) else {
            let directory = LinuxViewerLocations.applicationSupportDirectory(
                environment: ProcessInfo.processInfo.environment,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
            exit(ViewerUpdateSelfTest.run(applicationSupportDirectory: directory, versionLine: "Sensorium \(ViewerRelease.version)"))
        }
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
                await TailnetDevicePickerLoader(provider: LocalTailscaleStatusProvider()).load()
            }
            let prompts = GtkViewerPrompts(launchWindow: launch)
            let registry = LinuxViewerWindowRegistry(environment: environment)
            let updater = LinuxViewerUpdater.make(
                releaseVersion: ViewerRelease.version,
                dataRoot: environment.applicationSupportDirectory(),
                replacing: replacing,
                transport: URLSessionLinuxUpdateTransport(),
                launcherFolders: LinuxViewerLocations.launcherFolders(
                    environment: ProcessInfo.processInfo.environment,
                    homeDirectory: FileManager.default.homeDirectoryForCurrentUser
                ),
                onTerminate: { quit.fire() }
            )
            Self.updater = updater
            if let updater {
                // Before the first window, as section 11.4 of the update
                // design requires.
                updater.rollBackUnconfirmedSwitch()
                launch.setUpdateLine(updater.line)
                updater.onLineChange = { launch.setUpdateLine($0) }
                launch.onDidShow = { updater.windowDidShow() }
                launch.onRestartNow = { Task { await updater.restartNow() } }
                launch.checksForUpdatesAutomatically = updater.checksAutomatically
                // Your Machines is where the answer is shown.
                launch.onCheckForUpdates = {
                    launch.show()
                    Task { await updater.checkForUpdates() }
                }
                launch.onSetChecksAutomatically = { on in
                    updater.setChecksAutomatically(on)
                    launch.checksForUpdatesAutomatically = on
                }
                registry.checksForUpdatesAutomatically = { updater.checksAutomatically }
            }
            let hide = {
                launch.minimize()
                registry.minimizeSessionWindows()
            }
            launch.onHide = hide
            registry.onApplicationCommand = { command in
                switch command {
                case .about: launch.showAbout()
                case .quit: quit.fire()
                case .showYourMachines:
                    launch.showList()
                    launch.show()
                case .hide: hide()
                case .checkForUpdates: launch.onCheckForUpdates?()
                case .toggleAutomaticUpdates:
                    if let updater { launch.onSetChecksAutomatically?(!updater.checksAutomatically) }
                default: break
                }
            }
            // What this machine cannot do, said once, before any machine has
            // been reached. None of it stops pairing or a session: each
            // notice is a sentence and a button that takes it away.
            let noticeStore = ViewerFirstRunNoticeStore(
                url: environment.applicationSupportDirectory().appendingPathComponent("first-run-notices.json")
            )
            Task { @MainActor in
                await ViewerFirstRunNotices.showNotices(
                    arguments: Array(CommandLine.arguments.dropFirst()),
                    capabilities: LinuxDecoderCapabilityProbe(), acknowledgements: noticeStore
                ) { notice in
                    await prompts.showNotice(notice)
                }
            }
            updater?.start()
            return ViewerGUI(
                launch: launch,
                prompts: prompts,
                eventLoop: GLibViewerEventLoop(),
                windowFactory: LinuxSessionWindowFactory(
                    tracesPresentation: CommandLine.arguments.contains("--trace"),
                    pinMemoryStore: FileShortcutStripPinMemoryStore(
                        url: environment.applicationSupportDirectory().appendingPathComponent("shortcut-strip-pin.json")
                    )
                ),
                windowRegistry: registry
            )
        }
        viewer.onSessionRunChange = { Self.updater?.sessionRunChanged($0) }
        await viewer.run(arguments: arguments)
    }
}

#endif

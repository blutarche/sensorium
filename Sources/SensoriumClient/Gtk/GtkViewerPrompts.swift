#if canImport(CGtk4)
import CGtk4
import Foundation

/// The two things the viewer's controller has to ask outside a window of its
/// own: why it cannot start, and one more confirmation before this machine's
/// key is replaced. Both say exactly what `ViewerPlatform.swift` holds the
/// words for, so a Linux viewer and a macOS one ask the same questions.
@MainActor
public final class GtkViewerPrompts: ViewerPrompts {
    /// The screen currently up, and the answer it is waiting to hand back.
    /// Held together: dismissing it has to resume whoever is waiting, or a
    /// quit fired while it is on screen would wait forever.
    private final class StartupFailureScreen {
        let window: GtkRef
        var continuation: CheckedContinuation<ViewerStartupFailureChoice, Never>?
        var callbacks: [AnyObject] = []

        init(window: GtkRef) {
            self.window = window
        }
    }

    private var startupFailure: StartupFailureScreen?

    /// A notice on screen, and whoever is waiting for it to be read. Held
    /// for the same reason the screen above is: the toolkit keeps the
    /// addresses of these callbacks and retains no Swift reference to them.
    private final class NoticeScreen {
        let window: GtkRef
        var continuation: CheckedContinuation<Void, Never>?
        var callbacks: [AnyObject] = []

        init(window: GtkRef) {
            self.window = window
        }
    }

    /// Every notice currently up. More than one can be, and each answers for
    /// itself.
    private var notices: [NoticeScreen] = []

    /// The window a modal ask belongs to. Weak because the launch window
    /// outlives these prompts and owns nothing here.
    private weak var launchWindow: GtkYourMachinesWindow?

    /// `launchWindow` is what a modal ask is centred on and holds while it is
    /// up. A viewer with no launch window yet asks on its own.
    public init(launchWindow: GtkYourMachinesWindow? = nil) {
        self.launchWindow = launchWindow
        GtkToolkit.start()
    }

    public func showStartupFailure(_ prompt: ViewerStartupFailurePrompt) async -> ViewerStartupFailureChoice {
        dismissStartupFailure()
        let window = gtkRef(gtk_window_new())
        gtk_window_set_title(sensorium_gtk_window(window), prompt.headline)
        gtk_window_set_default_size(sensorium_gtk_window(window), 460, -1)
        gtk_window_set_resizable(sensorium_gtk_window(window), 0)
        gtk_widget_add_css_class(sensorium_gtk_widget(window), "sensorium")

        let screen = StartupFailureScreen(window: window)
        startupFailure = screen

        let body = GtkWidgets.box(vertical: true, spacing: 16)
        gtk_widget_set_margin_start(sensorium_gtk_widget(body), 24)
        gtk_widget_set_margin_end(sensorium_gtk_widget(body), 24)
        gtk_widget_set_margin_top(sensorium_gtk_widget(body), 24)
        gtk_widget_set_margin_bottom(sensorium_gtk_widget(body), 24)
        GtkWidgets.append(
            GtkWidgets.label(prompt.eyebrow, cssClass: GtkViewerStyle.Class.eyebrow), to: body
        )
        GtkWidgets.append(
            GtkWidgets.label(prompt.headline, cssClass: GtkViewerStyle.Class.heading), to: body
        )
        GtkWidgets.append(
            GtkWidgets.label(prompt.detail, cssClass: GtkViewerStyle.Class.muted), to: body
        )

        let buttons = GtkWidgets.box(vertical: false, spacing: 16)
        // Trying again is never destructive, so it takes the accent and the
        // default; only replacing this machine's identity is, and Return must
        // not fire that by accident.
        appendChoice(prompt.tryAgainTitle, .tryAgain, to: buttons, on: screen, isPrimary: true)
        appendChoice(prompt.replaceTitle, .replaceIdentity, to: buttons, on: screen, isPrimary: false)
        appendChoice(prompt.quitTitle, .quit, to: buttons, on: screen, isPrimary: false)
        GtkWidgets.append(buttons, to: body)

        gtk_window_set_child(sensorium_gtk_window(window), sensorium_gtk_widget(body))

        let closeCallback = GtkCallback { [weak self] in self?.finishStartupFailure(with: .quit) }
        screen.callbacks.append(closeCallback)
        let closeRequest: @convention(c) (GtkRef?, GtkRef?) -> gboolean = { _, data in
            gtkRunCallback(data)
            return 1
        }
        gtkConnect(window, "close-request", closeRequest, Unmanaged.passUnretained(closeCallback).toOpaque())

        gtk_window_present(sensorium_gtk_window(window))
        return await withCheckedContinuation { continuation in
            screen.continuation = continuation
        }
    }

    private func appendChoice(
        _ title: String,
        _ choice: ViewerStartupFailureChoice,
        to row: GtkRef,
        on screen: StartupFailureScreen,
        isPrimary: Bool
    ) {
        let button = GtkWidgets.button(title, cssClass: isPrimary ? GtkViewerStyle.Class.primary : nil)
        let callback = GtkCallback { [weak self] in self?.finishStartupFailure(with: choice) }
        screen.callbacks.append(callback)
        gtkConnect(button, "clicked", gtkClickedHandler, Unmanaged.passUnretained(callback).toOpaque())
        if isPrimary {
            gtk_widget_set_receives_default(sensorium_gtk_widget(button), 1)
            gtk_window_set_default_widget(
                sensorium_gtk_window(screen.window), sensorium_gtk_widget(button)
            )
        }
        GtkWidgets.append(button, to: row)
    }

    /// Quitting while this screen is up must not be blocked behind it, so a
    /// dismissal answers on the waiting call's behalf.
    public func dismissStartupFailure() {
        finishStartupFailure(with: .quit)
    }

    private func finishStartupFailure(with choice: ViewerStartupFailureChoice) {
        guard let screen = startupFailure else { return }
        startupFailure = nil
        gtk_window_destroy(sensorium_gtk_window(screen.window))
        screen.continuation?.resume(returning: choice)
        screen.continuation = nil
    }

    /// One thing the person should know, with a single button that takes it
    /// away. Built the same way the startup-failure screen is, so the two
    /// read as the same app; unlike that screen it decides nothing, and the
    /// window behind it is already usable while it is up.
    public func showNotice(_ notice: ViewerNotice) async {
        let window = gtkRef(gtk_window_new())
        gtk_window_set_title(sensorium_gtk_window(window), notice.headline)
        gtk_window_set_default_size(sensorium_gtk_window(window), 460, -1)
        gtk_window_set_resizable(sensorium_gtk_window(window), 0)
        gtk_widget_add_css_class(sensorium_gtk_widget(window), "sensorium")

        let body = GtkWidgets.box(vertical: true, spacing: 16)
        gtk_widget_set_margin_start(sensorium_gtk_widget(body), 24)
        gtk_widget_set_margin_end(sensorium_gtk_widget(body), 24)
        gtk_widget_set_margin_top(sensorium_gtk_widget(body), 24)
        gtk_widget_set_margin_bottom(sensorium_gtk_widget(body), 24)
        GtkWidgets.append(
            GtkWidgets.label(notice.headline, cssClass: GtkViewerStyle.Class.heading), to: body
        )
        GtkWidgets.append(
            GtkWidgets.label(notice.detail, cssClass: GtkViewerStyle.Class.muted), to: body
        )

        let screen = NoticeScreen(window: window)
        let button = GtkWidgets.button(notice.continueTitle, cssClass: GtkViewerStyle.Class.primary)
        let clicked = GtkCallback { [weak self] in self?.finishNotice(screen) }
        screen.callbacks.append(clicked)
        gtkConnect(button, "clicked", gtkClickedHandler, Unmanaged.passUnretained(clicked).toOpaque())
        gtk_widget_set_receives_default(sensorium_gtk_widget(button), 1)
        gtk_window_set_default_widget(sensorium_gtk_window(window), sensorium_gtk_widget(button))
        GtkWidgets.append(button, to: body)

        gtk_window_set_child(sensorium_gtk_window(window), sensorium_gtk_widget(body))

        // Closing the window is the same choice as pressing the button: the
        // notice has been read either way, and nothing waits on which.
        let closeCallback = GtkCallback { [weak self] in self?.finishNotice(screen) }
        screen.callbacks.append(closeCallback)
        let closeRequest: @convention(c) (GtkRef?, GtkRef?) -> gboolean = { _, data in
            gtkRunCallback(data)
            return 1
        }
        gtkConnect(window, "close-request", closeRequest, Unmanaged.passUnretained(closeCallback).toOpaque())

        notices.append(screen)
        gtk_window_present(sensorium_gtk_window(window))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            screen.continuation = continuation
        }
    }

    private func finishNotice(_ screen: NoticeScreen) {
        guard let index = notices.firstIndex(where: { $0 === screen }) else { return }
        notices.remove(at: index)
        gtk_window_destroy(sensorium_gtk_window(screen.window))
        screen.continuation?.resume()
        screen.continuation = nil
    }

    /// Replacing this machine's key is one-way, so the tap that does it is
    /// confirmed once more first.
    public func confirmNewKey() async -> Bool {
        let dialog = gtkRef(sensorium_alert_dialog_new(ViewerNewKeyConfirmation.question))
        gtk_alert_dialog_set_detail(sensorium_gtk_alert_dialog(dialog), ViewerNewKeyConfirmation.detail)
        gtk_alert_dialog_set_modal(sensorium_gtk_alert_dialog(dialog), 1)
        sensorium_alert_dialog_set_two_buttons(
            sensorium_gtk_alert_dialog(dialog),
            ViewerNewKeyConfirmation.confirmTitle,
            ViewerNewKeyConfirmation.cancelTitle
        )
        // Cancel is both the default and what a dismissed dialog reports: the
        // destructive answer is never the one a stray Return or Escape gives.
        gtk_alert_dialog_set_default_button(sensorium_gtk_alert_dialog(dialog), 1)
        gtk_alert_dialog_set_cancel_button(sensorium_gtk_alert_dialog(dialog), 1)

        let answer = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            let box = GtkAlertAnswer(continuation)
            alertAnswers.append(box)
            let chosen: @convention(c) (GtkRef?, GtkRef?, GtkRef?) -> Void = { source, result, data in
                guard let source, let result, let data else { return }
                let index = sensorium_alert_dialog_choose_finish(source, result)
                let box = Unmanaged<GtkAlertAnswer>.fromOpaque(data).takeUnretainedValue()
                MainActor.assumeIsolated { box.answer(index) }
            }
            sensorium_alert_dialog_choose(
                sensorium_gtk_alert_dialog(dialog),
                launchWindow.map { sensorium_gtk_window($0.toplevel) },
                unsafeBitCast(chosen, to: (@convention(c) () -> Void).self),
                Unmanaged.passUnretained(box).toOpaque()
            )
        }
        alertAnswers.removeAll { $0.hasAnswered }
        g_object_unref(dialog)
        return answer == 0
    }

    /// Kept alive while the toolkit holds their addresses; dropped once each
    /// has answered.
    private var alertAnswers: [GtkAlertAnswer] = []
}

/// One pending alert answer, so the continuation outlives the call that made
/// it without the toolkit holding a Swift reference it cannot retain.
private final class GtkAlertAnswer {
    private var continuation: CheckedContinuation<Int32, Never>?
    private(set) var hasAnswered = false

    init(_ continuation: CheckedContinuation<Int32, Never>) {
        self.continuation = continuation
    }

    @MainActor
    func answer(_ index: Int32) {
        guard let continuation else { return }
        self.continuation = nil
        hasAnswered = true
        continuation.resume(returning: index)
    }
}
#endif

#if os(Linux)
import CGLib
import CGtk4
import Foundation

/// The ask-first prompt: a window naming the device and the display, with
/// Allow and Don't Allow, shown to the person at the machine when someone used
/// it in the last few minutes. It counts down on its own and answers Don't
/// Allow when the time is up. One window answers one question.
///
/// The words and the wait are `AskFirstPromptModel`'s. Don't Allow is the
/// filled button and the window's default, as in the macOS prompt: a failed,
/// closed or unanswered prompt refuses.
@MainActor
public final class AskFirstPromptWindow {
    private let model: AskFirstPromptModel
    private let window: HostGtkRef
    private let countdownLabel: HostGtkRef
    private var retained: [AnyObject] = []
    private var ticker: guint = 0

    /// `onOutcome` is told once how the prompt ended; the window then closes
    /// itself.
    public init(
        content: AskFirstPromptContent,
        appearance: IndicatorAppearance,
        now: @escaping () -> Date = { Date() },
        onOutcome: @escaping @MainActor (AskFirstOutcome) -> Void
    ) {
        HostWindowTheme.install(appearance)
        typealias Space = HostWindowMetrics.Space
        typealias Class = HostWindowStyle.Class
        let window = hostGtkRef(gtk_window_new())
        self.window = window
        var closeWindow: @MainActor () -> Void = {}
        var stopTicking: @MainActor () -> Void = {}
        let model = AskFirstPromptModel(content: content, now: now) { outcome in
            MainActor.assumeIsolated {
                stopTicking()
                closeWindow()
                onOutcome(outcome)
            }
        }
        self.model = model

        gtk_window_set_title(sensorium_gtk_window(window), model.windowTitle)
        gtk_window_set_default_size(sensorium_gtk_window(window), Int32(HostWindowMetrics.promptWidth), -1)
        gtk_window_set_resizable(sensorium_gtk_window(window), 0)
        HostWidgets.addClass(Class.window, to: window)

        let eyebrow = HostWidgets.label(model.eyebrow.uppercased(), classes: [Class.eyebrow])
        let headline = HostWidgets.label(model.headline, classes: [Class.promptHeadline])
        let subtitle = HostWidgets.label(model.subtitle, classes: [Class.detail])
        countdownLabel = HostWidgets.label(model.countdownLine, classes: [Class.countdown])
        let texts = HostWidgets.box(vertical: true, spacing: Int32(Space.xs))
        for view in [eyebrow, headline, subtitle, countdownLabel] { HostWidgets.append(view, to: texts) }

        let allow = HostGtkCallback { model.allow() }
        let deny = HostGtkCallback { model.deny() }
        retained.append(contentsOf: [allow, deny])
        let allowButton = HostWidgets.titledButton(
            model.allowTitle, classes: [Class.promptButton], onClick: allow
        )
        let denyButton = HostWidgets.titledButton(
            model.denyTitle, classes: [Class.promptButton, Class.promptFilled], onClick: deny
        )
        for button in [allowButton, denyButton] {
            gtk_widget_set_hexpand(HostWidgets.widget(button), 0)
            gtk_widget_set_halign(HostWidgets.widget(button), GTK_ALIGN_END)
        }
        // Allow left, Don't Allow at the row's right edge, as in the macOS
        // prompt.
        let buttons = HostWidgets.box(vertical: false, spacing: Int32(Space.xs))
        gtk_widget_set_halign(HostWidgets.widget(buttons), GTK_ALIGN_END)
        HostWidgets.append(allowButton, to: buttons)
        HostWidgets.append(denyButton, to: buttons)
        gtk_window_set_default_widget(sensorium_gtk_window(window), HostWidgets.widget(denyButton))

        let outer = HostWidgets.box(vertical: true, spacing: Int32(Space.lg))
        gtk_widget_set_size_request(HostWidgets.widget(outer), Int32(HostWindowMetrics.promptWidth - Space.lg * 2), -1)
        HostWidgets.setMargins(outer, top: Space.lg, bottom: Space.lg, start: Space.lg, end: Space.lg)
        HostWidgets.append(texts, to: outer)
        HostWidgets.append(buttons, to: outer)
        gtk_window_set_child(sensorium_gtk_window(window), HostWidgets.widget(outer))

        // Closing the window without choosing is a refusal.
        let closeRequest: @convention(c) (HostGtkRef?, HostGtkRef?) -> gboolean = { _, data in
            hostGtkRun(data)
            return 1
        }
        let closed = HostGtkCallback { model.deny() }
        retained.append(closed)
        hostGtkConnect(window, "close-request", closeRequest, Unmanaged.passUnretained(closed).toOpaque())

        closeWindow = { [weak self] in self?.close() }
        stopTicking = { [weak self] in self?.stopTicker() }
    }

    /// The toplevel, for a probe that draws it.
    public var toplevel: UnsafeMutableRawPointer { window }

    public func show() {
        gtk_window_present(sensorium_gtk_window(window))
        startTicker()
    }

    /// Takes the window away without answering.
    public func dismiss() {
        close()
    }

    private func close() {
        stopTicker()
        gtk_window_destroy(sensorium_gtk_window(window))
    }

    /// Redraws the countdown once a second and lets the model time the prompt
    /// out.
    private func startTicker() {
        guard ticker == 0 else { return }
        let tick: @convention(c) (gpointer?) -> gboolean = { data in
            guard let data else { return 0 }
            let prompt = Unmanaged<AskFirstPromptWindow>.fromOpaque(data).takeUnretainedValue()
            return MainActor.assumeIsolated { prompt.tick() } ? 1 : 0
        }
        ticker = g_timeout_add_seconds(1, tick, Unmanaged.passUnretained(self).toOpaque())
    }

    private func tick() -> Bool {
        gtk_label_set_text(sensorium_gtk_label(countdownLabel), model.countdownLine)
        model.tick()
        return ticker != 0 && model.outcome == nil
    }

    private func stopTicker() {
        guard ticker != 0 else { return }
        g_source_remove(ticker)
        ticker = 0
    }
}
#endif

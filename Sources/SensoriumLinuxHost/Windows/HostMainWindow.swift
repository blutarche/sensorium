#if os(Linux)
import CGLib
import CGtk4
import Foundation

/// What the person at the host can ask of the main window. Each closure is
/// called with the machine's id where it concerns one. The window changes
/// nothing itself: whoever owns the host applies the request and hands the
/// window a new `HostWindowState`.
public struct HostMainWindowActions {
    public var stop: @MainActor () -> Void = {}
    /// Starts the screen sharing grant.
    public var allowScreenSharing: @MainActor () -> Void = {}
    public var showPairingCode: @MainActor () -> Void = {}
    public var hidePairingCode: @MainActor () -> Void = {}
    public var setSharing: @MainActor (_ machineID: String, _ isOn: Bool) -> Void = { _, _ in }
    public var setAsksFirst: @MainActor (_ machineID: String, _ isOn: Bool) -> Void = { _, _ in }
    /// The id and the name the rename step starts from.
    public var rename: @MainActor (_ machineID: String, _ currentName: String) -> Void = { _, _ in }
    public var remove: @MainActor (_ machineID: String) -> Void = { _ in }
    public var setOpenAtLogin: @MainActor (_ isOn: Bool) -> Void = { _ in }
    public var setAllowsLocalNetwork: @MainActor (_ isOn: Bool) -> Void = { _ in }
    public var quit: (@MainActor () -> Void)?

    public init() {}
}

/// The host's one window: the status, the pairing code, every paired machine
/// and the few switches. It mirrors the macOS host window's content, copy,
/// order and spacing, drawn in the design system's tokens with the system
/// font.
///
/// The window keeps no state of its own. `update` takes a whole
/// `HostWindowState` and rebuilds the content from it, the way the macOS
/// window rebuilds on every refresh.
@MainActor
public final class HostMainWindow {
    private let appearance: IndicatorAppearance
    private let actions: HostMainWindowActions
    private let now: () -> Date
    private let window: HostGtkRef
    private let column: HostGtkRef
    private var state: HostWindowState
    /// The boxes every signal handler of the current content points into.
    private var retained: [AnyObject] = []
    private var ticker: guint = 0

    /// The window shows no more than this tall before its content scrolls.
    private static let maximumContentHeight: Int32 = 900

    public init(
        state: HostWindowState,
        appearance: IndicatorAppearance,
        actions: HostMainWindowActions = HostMainWindowActions(),
        now: @escaping () -> Date = { Date() }
    ) {
        self.state = state
        self.appearance = appearance
        self.actions = actions
        self.now = now
        HostWindowTheme.install(appearance)
        window = hostGtkRef(gtk_window_new())
        gtk_window_set_title(sensorium_gtk_window(window), HostWindowCopy.windowTitle)
        gtk_window_set_default_size(sensorium_gtk_window(window), Int32(HostWindowMetrics.windowWidth), -1)
        gtk_window_set_resizable(sensorium_gtk_window(window), 0)
        HostWidgets.addClass(HostWindowStyle.Class.window, to: window)

        column = HostWidgets.box(vertical: true)
        gtk_widget_set_size_request(HostWidgets.widget(column), Int32(HostWindowMetrics.contentWidth), -1)
        HostWidgets.setMargins(
            column, top: HostWindowMetrics.Space.xl, bottom: HostWindowMetrics.Space.xl,
            start: HostWindowMetrics.Space.xl, end: HostWindowMetrics.Space.xl
        )
        let scroll = hostGtkRef(gtk_scrolled_window_new())
        gtk_scrolled_window_set_policy(sensorium_gtk_scrolled_window(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(sensorium_gtk_scrolled_window(scroll), 1)
        gtk_scrolled_window_set_max_content_height(sensorium_gtk_scrolled_window(scroll), Self.maximumContentHeight)
        gtk_scrolled_window_set_child(sensorium_gtk_scrolled_window(scroll), HostWidgets.widget(column))
        gtk_window_set_child(sensorium_gtk_window(window), HostWidgets.widget(scroll))

        // Closing hides the window; the host keeps running.
        let hide: @convention(c) (HostGtkRef?, HostGtkRef?) -> gboolean = { window, _ in
            if let window { gtk_widget_set_visible(sensorium_gtk_widget(window), 0) }
            return 1
        }
        hostGtkConnect(window, "close-request", hide, nil)
        rebuild()
    }

    deinit {
        MainActor.assumeIsolated { stopTicker() }
    }

    /// The toplevel, for a probe that draws it.
    public var toplevel: UnsafeMutableRawPointer { window }

    public func show() {
        gtk_window_present(sensorium_gtk_window(window))
    }

    public func hide() {
        stopTicker()
        gtk_window_destroy(sensorium_gtk_window(window))
    }

    public func update(_ state: HostWindowState) {
        self.state = state
        rebuild()
    }

    // MARK: - Content

    private func rebuild() {
        retained.removeAll()
        while let child = gtk_widget_get_first_child(HostWidgets.widget(column)) {
            gtk_box_remove(sensorium_gtk_box(column), child)
        }
        let presentation = HostWindowPresentation(state, now: now())
        var items: [(view: HostGtkRef, gapAfter: Int)] = []
        typealias Space = HostWindowMetrics.Space
        let lg = Space.lg

        items.append((card(presentation.card), lg))
        if presentation.showsStop {
            items.append((filledButton(HostWindowCopy.stopButton, [HostWindowStyle.Class.stop], actions.stop), lg))
        }
        if let title = presentation.grantButtonTitle {
            items.append((filledButton(title, [HostWindowStyle.Class.grant], actions.allowScreenSharing), lg))
        }
        let pairing = presentation.pairing
        if pairing.showsRevealButton {
            let title = pairing.revealButtonTitle
            let view = pairing.revealIsFilled
                ? filledButton(title, [], actions.showPairingCode)
                : outlinedButton(title, actions.showPairingCode)
            items.append((view, lg))
        }
        if let code = pairing.code {
            items.append((codeCard(pairing, code: code), Space.sm))
            items.append((outlinedButton(pairing.hideButtonTitle, actions.hidePairingCode), lg))
        }
        if presentation.showsUpdateScreenSharing {
            let button = outlinedButton(HostWindowCopy.updateScreenSharingButton, actions.allowScreenSharing)
            gtk_widget_set_tooltip_text(sensorium_gtk_widget(button), HostWindowCopy.updateScreenSharingHelp)
            items.append((button, lg))
        }
        if !presentation.machines.isHidden {
            items.append((machinesSection(presentation.machines), lg))
        }
        if presentation.showsSwitches {
            appendSwitches(presentation, to: &items)
        }
        if let update = presentation.updateLine {
            let classes = update.isFailure
                ? [HostWindowStyle.Class.detail, HostWindowStyle.Class.detailWarn]
                : [HostWindowStyle.Class.detail]
            items.append((HostWidgets.label(update.text, classes: classes), lg))
        }
        if let quit = actions.quit {
            items.append((outlinedButton("Quit Sensorium Host", quit), lg))
        }

        for (index, item) in items.enumerated() {
            HostWidgets.setBottomGap(index == items.count - 1 ? 0 : item.gapAfter, on: item.view)
            HostWidgets.append(item.view, to: column)
        }
        manageTicker(codeIsShowing: pairing.code != nil)
    }

    private func appendSwitches(_ presentation: HostWindowPresentation, to items: inout [(view: HostGtkRef, gapAfter: Int)]) {
        typealias Space = HostWindowMetrics.Space
        let login = presentation.openAtLogin
        let loginSwitch = HostControls.checkbox(
            title: login.title, isOn: login.isOn, isEnabled: login.isEnabled, appearance: appearance,
            onClick: callback { [actions] in actions.setOpenAtLogin(!login.isOn) }
        )
        retained.append(contentsOf: loginSwitch.retained)
        items.append((loginSwitch.widget, Space.xs))
        if let note = login.note {
            items.append((HostWidgets.label(note, classes: [HostWindowStyle.Class.detail]), Space.lg))
        }
        guard state.supportsLocalNetwork else { return }
        let network = presentation.localNetwork
        let networkSwitch = HostControls.checkbox(
            title: network.title, isOn: network.isOn, isEnabled: true, appearance: appearance,
            onClick: callback { [actions] in actions.setAllowsLocalNetwork(!network.isOn) }
        )
        retained.append(contentsOf: networkSwitch.retained)
        items.append((networkSwitch.widget, Space.xs))
        items.append((HostWidgets.label(network.explanation, classes: [HostWindowStyle.Class.detail]), Space.lg))
    }

    private func callback(_ run: @escaping @MainActor () -> Void) -> HostGtkCallback {
        let box = HostGtkCallback(run)
        retained.append(box)
        return box
    }

    // MARK: - Status

    private func card(_ card: HostWindowPresentation.Card) -> HostGtkRef {
        let box = HostWidgets.box(vertical: true)
        HostWidgets.addClass(HostWindowStyle.Class.card, to: box)
        let inset = HostWindowMetrics.Space.md
        HostWidgets.setMargins(box)
        let content = HostWidgets.box(vertical: true)
        HostWidgets.setMargins(content, top: inset, bottom: inset, start: inset, end: inset)
        var eyebrowClasses = [HostWindowStyle.Class.eyebrow]
        if card.eyebrowIsWarning { eyebrowClasses.append(HostWindowStyle.Class.warn) }
        HostWidgets.append(HostWidgets.label(card.eyebrow, classes: eyebrowClasses), to: content)
        let headline = HostWidgets.label(card.headline, classes: [HostWindowStyle.Class.headline])
        HostWidgets.setMargins(headline, top: HostWindowMetrics.Space.xs)
        HostWidgets.append(headline, to: content)
        if !card.detail.isEmpty {
            let detail = HostWidgets.label(card.detail, classes: [HostWindowStyle.Class.detail])
            HostWidgets.setMargins(detail, top: HostWindowMetrics.Space.xxs)
            HostWidgets.append(detail, to: content)
        }
        HostWidgets.append(content, to: box)
        return box
    }

    private func filledButton(_ title: String, _ extra: [String], _ action: @escaping @MainActor () -> Void) -> HostGtkRef {
        HostWidgets.titledButton(
            title, classes: [HostWindowStyle.Class.filled] + extra, onClick: callback(action)
        )
    }

    private func outlinedButton(_ title: String, _ action: @escaping @MainActor () -> Void) -> HostGtkRef {
        HostWidgets.titledButton(title, classes: [HostWindowStyle.Class.outlined], onClick: callback(action))
    }

    private func codeCard(_ pairing: HostWindowPresentation.Pairing, code: String) -> HostGtkRef {
        typealias Space = HostWindowMetrics.Space
        let card = HostWidgets.box(vertical: true)
        HostWidgets.addClass(HostWindowStyle.Class.card, to: card)
        let content = HostWidgets.box(vertical: true)
        HostWidgets.setMargins(content, top: Space.md, bottom: Space.md, start: Space.md, end: Space.md)
        HostWidgets.append(
            HostWidgets.label(code, classes: [HostWindowStyle.Class.digits], wraps: false, centered: true), to: content
        )
        if let countdown = pairing.countdown {
            var classes = [HostWindowStyle.Class.countdown]
            if pairing.countdownIsUrgent { classes.append(HostWindowStyle.Class.countdownUrgent) }
            let line = HostWidgets.label(countdown, classes: classes, centered: true)
            HostWidgets.setMargins(line, top: Space.xs)
            HostWidgets.append(line, to: content)
        }
        if let hint = pairing.hint {
            let line = HostWidgets.label(hint, classes: [HostWindowStyle.Class.detail], centered: true)
            HostWidgets.setMargins(line, top: Space.xs)
            HostWidgets.append(line, to: content)
        }
        HostWidgets.append(content, to: card)
        // The digits sit centred in the card whatever the width of the label.
        if let digits = gtk_widget_get_first_child(HostWidgets.widget(content)) {
            gtk_widget_set_halign(digits, GTK_ALIGN_CENTER)
        }
        return card
    }

    // MARK: - Paired machines

    private func machinesSection(_ section: HostWindowPresentation.Machines) -> HostGtkRef {
        typealias Space = HostWindowMetrics.Space
        var items: [(view: HostGtkRef, gapAfter: Int)] = []
        if section.showsEyebrow {
            items.append((HostWidgets.label(section.eyebrow.uppercased(), classes: [HostWindowStyle.Class.eyebrow]), Space.xs))
        }
        if let heading = section.emptyHeading {
            items.append((HostWidgets.label(heading, classes: [HostWindowStyle.Class.sentenceMedium]), Space.xxs))
        }
        if let subtext = section.emptySubtext {
            items.append((HostWidgets.label(subtext, classes: [HostWindowStyle.Class.muted]), Space.lg))
        }
        if !section.rows.isEmpty {
            items.append((rowsCard(section.rows), Space.lg))
        }
        if let last = section.lastSession {
            items.append((HostWidgets.label(last.eyebrow.uppercased(), classes: [HostWindowStyle.Class.eyebrow]), Space.xs))
            let card = HostWidgets.box(vertical: true)
            HostWidgets.addClass(HostWindowStyle.Class.card, to: card)
            let line = HostWidgets.label(last.line, classes: [HostWindowStyle.Class.muted])
            HostWidgets.setMargins(line, top: Space.md, bottom: Space.md, start: Space.md, end: Space.md)
            HostWidgets.append(line, to: card)
            items.append((card, 0))
        }
        let stack = HostWidgets.box(vertical: true)
        for (index, item) in items.enumerated() {
            HostWidgets.setBottomGap(index == items.count - 1 ? 0 : item.gapAfter, on: item.view)
            HostWidgets.append(item.view, to: stack)
        }
        return stack
    }

    private func rowsCard(_ rows: [HostWindowPresentation.MachineRow]) -> HostGtkRef {
        let card = HostWidgets.box(vertical: true)
        HostWidgets.addClass(HostWindowStyle.Class.card, to: card)
        for (index, row) in rows.enumerated() {
            HostWidgets.append(machineRow(row, isFirst: index == 0), to: card)
        }
        return card
    }

    private func machineRow(_ row: HostWindowPresentation.MachineRow, isFirst: Bool) -> HostGtkRef {
        typealias Space = HostWindowMetrics.Space
        let container = HostWidgets.box(vertical: true)
        if !isFirst {
            // The hairline starts at the text's inset, as in a settings list.
            let line = HostWidgets.hairline()
            HostWidgets.setMargins(line, start: Space.md)
            gtk_widget_set_hexpand(HostWidgets.widget(line), 1)
            HostWidgets.append(line, to: container)
        }
        let content = HostWidgets.box(vertical: false)
        let separatorHeight = isFirst ? 0 : 1
        gtk_widget_set_size_request(HostWidgets.widget(content), -1, Int32(HostWindowMetrics.rowHeight - separatorHeight))

        let texts = HostWidgets.box(vertical: true)
        gtk_widget_set_valign(HostWidgets.widget(texts), GTK_ALIGN_CENTER)
        gtk_widget_set_hexpand(HostWidgets.widget(texts), 1)
        HostWidgets.append(HostWidgets.singleLineLabel(row.name, classes: [HostWindowStyle.Class.rowName]), to: texts)
        if let subtitle = row.subtitle {
            HostWidgets.append(HostWidgets.singleLineLabel(subtitle, classes: [HostWindowStyle.Class.rowDetail]), to: texts)
        }
        HostWidgets.setMargins(texts, start: Space.md, end: Space.sm)
        HostWidgets.append(texts, to: content)

        let toggle = HostControls.toggle(
            isOn: row.switchIsOn, isEnabled: true, appearance: appearance, label: row.switchLabel,
            onClick: callback { [actions] in actions.setSharing(row.id, !row.switchIsOn) }
        )
        retained.append(contentsOf: toggle.retained)
        HostWidgets.append(toggle.widget, to: content)

        let more = moreButton(for: row)
        HostWidgets.setMargins(more, start: Space.xs, end: Space.xs)
        HostWidgets.append(more, to: content)
        HostWidgets.append(content, to: container)
        return container
    }

    /// The row's "more" button and the menu it opens: Rename, Ask first, the
    /// key line and Remove, as the macOS row's menu lists them.
    private func moreButton(for row: HostWindowPresentation.MachineRow) -> HostGtkRef {
        let button = hostGtkRef(gtk_menu_button_new())
        gtk_widget_set_can_focus(HostWidgets.widget(button), 0)
        gtk_widget_set_valign(HostWidgets.widget(button), GTK_ALIGN_CENTER)
        HostWidgets.addClass(HostWindowStyle.Class.iconButton, to: button)
        let dots = HostControls.moreDots(appearance: appearance)
        retained.append(dots.drawing)
        gtk_menu_button_set_child(sensorium_gtk_menu_button(button), HostWidgets.widget(dots.widget))
        gtk_menu_button_set_always_show_arrow(sensorium_gtk_menu_button(button), 0)
        HostWidgets.setAccessibleLabel(row.moreLabel, on: button)

        let popover = hostGtkRef(gtk_popover_new())
        HostWidgets.addClass(HostWindowStyle.Class.menu, to: popover)
        gtk_popover_set_has_arrow(sensorium_gtk_popover(popover), 0)
        gtk_popover_set_position(sensorium_gtk_popover(popover), GTK_POS_BOTTOM)
        let menu = HostWidgets.box(vertical: true)
        let close = callbackClosing(popover)
        for item in row.menu {
            HostWidgets.append(menuItem(item, for: row, closing: close), to: menu)
        }
        gtk_popover_set_child(sensorium_gtk_popover(popover), HostWidgets.widget(menu))
        gtk_menu_button_set_popover(sensorium_gtk_menu_button(button), HostWidgets.widget(popover))
        return button
    }

    /// Dismisses the popover. A menu item runs its action and then this.
    private func callbackClosing(_ popover: HostGtkRef) -> @MainActor () -> Void {
        { gtk_popover_popdown(sensorium_gtk_popover(popover)) }
    }

    private func menuItem(
        _ item: HostWindowPresentation.MenuItem,
        for row: HostWindowPresentation.MachineRow,
        closing close: @escaping @MainActor () -> Void
    ) -> HostGtkRef {
        typealias Class = HostWindowStyle.Class
        func titled(_ title: String, classes: [String], leading: HostGtkRef?, action: @escaping @MainActor () -> Void) -> HostGtkRef {
            let content = HostWidgets.box(vertical: false, spacing: Int32(HostWindowMetrics.Space.xs))
            if let leading { HostWidgets.append(leading, to: content) }
            HostWidgets.append(HostWidgets.label(title, classes: [], wraps: false), to: content)
            return HostWidgets.button(
                child: content, classes: [Class.menuItem] + classes,
                onClick: callback { action(); close() }
            )
        }
        switch item {
        case let .rename(title):
            return titled(title, classes: [], leading: nil) { [actions] in actions.rename(row.id, row.renameCurrentName) }
        case let .askFirst(title, isChecked, isEnabled):
            let check = HostControls.checkmark(isOn: isChecked, isEnabled: isEnabled, appearance: appearance, drawsBox: false)
            retained.append(check.drawing)
            let button = titled(title, classes: [], leading: check.widget) { [actions] in actions.setAsksFirst(row.id, !isChecked) }
            HostWidgets.setEnabled(isEnabled, on: button)
            return button
        case let .keyLine(line):
            return HostWidgets.label(line, classes: [Class.menuKey], wraps: false)
        case .separator:
            let line = HostWidgets.hairline()
            HostWidgets.setMargins(line, top: HostWindowMetrics.Space.xxs, bottom: HostWindowMetrics.Space.xxs)
            return line
        case let .remove(title):
            return titled(title, classes: [Class.menuRemove], leading: nil) { [actions] in actions.remove(row.id) }
        }
    }

    // MARK: - Countdown

    /// A shown code counts down, so the window redraws once a second while
    /// one is on screen and never otherwise.
    private func manageTicker(codeIsShowing: Bool) {
        guard codeIsShowing else {
            stopTicker()
            return
        }
        guard ticker == 0 else { return }
        let tick: @convention(c) (gpointer?) -> gboolean = { data in
            guard let data else { return 0 }
            let window = Unmanaged<HostMainWindow>.fromOpaque(data).takeUnretainedValue()
            return MainActor.assumeIsolated { window.tick() } ? 1 : 0
        }
        ticker = g_timeout_add_seconds(1, tick, Unmanaged.passUnretained(self).toOpaque())
    }

    private func tick() -> Bool {
        rebuild()
        return ticker != 0
    }

    private func stopTicker() {
        guard ticker != 0 else { return }
        g_source_remove(ticker)
        ticker = 0
    }
}
#endif

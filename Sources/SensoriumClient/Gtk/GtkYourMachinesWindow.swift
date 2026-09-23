#if canImport(CGtk4)
import CGtk4
import Foundation
import SensoriumCore

/// The only window at launch where GTK is the toolkit: the machines this one
/// has paired with, and the two steps that add another. The Linux counterpart
/// of `YourMachinesWindowController`, and deliberately just as thin -- which
/// rows appear, what the line under each name says and what a click means are
/// `YourMachinesWindowModel`'s decisions; what may be typed into the code step
/// and what each failure says are `ViewerPairingForm`'s and
/// `ViewerPairingFailureCopy`'s. This holds widgets, and asks.
@MainActor
public final class GtkYourMachinesWindow: ViewerLaunchWindow {
    /// Which of the three screens this one window is showing. Adding a machine
    /// is two steps inside this window rather than windows of its own: a
    /// person who has just chosen to add a machine is still in the same place
    /// they started, and the way back is a link rather than a close button.
    private enum Step: Equatable {
        case list
        case chooseDevice
        /// `device` is `nil` only for an address being typed by hand, the one
        /// path that has no machine picked yet.
        case typeCode(device: ViewerPairingDevice?, isPairingAgain: Bool)
    }

    private static let windowWidth: Int32 = 460

    private static let addressHintText = "Tailscale address, or a name like mini.local."
    private static let codeHintText =
        "Shown by Sensorium Host on that machine under Show pairing code."

    public var loadTailnet: (() async -> TailnetDevicePickerState)?
    public var sendPairIntent: ((ViewerPairingDevice) async -> ViewerPairIntentAttempt)?
    public var pair: ((ViewerPairingDevice?, ViewerPairingSubmission) async -> ViewerPairingResult)?
    public var onConnect: ((SavedHost) -> Void)?
    public var onCancelConnecting: (() -> Void)?
    public var onConnectAsVirtualDisplayFallback: ((Data) -> Void)?
    public var onCloseRequested: (() -> Void)?
    public var onCodeStepAbandoned: (() -> Void)?

    private let store: any SavedHostStoring
    private let window: GtkRef
    private let stack: GtkRef
    private let listPage: GtkRef
    private let pickerPage: GtkRef
    private let codePage: GtkRef

    private var step: Step = .list
    private var model = YourMachinesWindowModel(hosts: [])
    private var reachability: [Data: Bool] = [:]
    private var pickerState: TailnetDevicePickerState = .loading
    private var selectedHostPublicKey: Data?

    /// Boxed closures the widgets currently on screen reach back through.
    /// Dropped whenever a page is rebuilt, along with the widgets that held
    /// them; the window's own keys and its row menu outlive every page and are
    /// kept apart from them.
    private var pageCallbacks: [AnyObject] = []
    private var windowCallbacks: [AnyObject] = []

    // MARK: Code step

    private var form = ViewerPairingForm()
    private var isPairing = false
    /// Guards `sendPairIntent` to exactly one call per visit to the code step;
    /// retyping a wrong code and resubmitting must never fire it again.
    private var pairIntentSent = false
    /// True once a submission has been tried, or the code field has been left,
    /// since the code was last still-typing -- until then a count-down message
    /// reads as progress, not a mistake.
    private var codeErrorsRevealed = false
    /// The saved machine a "Pair again" is for, or `nil` when this is a machine
    /// being added.
    private var pairingAgainHostPublicKey: Data?
    /// Set while the code field is being regrouped as it is typed, so the
    /// change that regrouping causes is not read back as a keystroke.
    private var isRegroupingCode = false

    /// This window itself, for a modal ask that has to be centred on it and
    /// hold it while it is up.
    var toplevel: GtkRef { window }

    private var addressEntry: GtkRef?
    private var codeEntry: GtkRef?
    private var nameEntry: GtkRef?
    private var addressHint: GtkRef?
    private var codeHint: GtkRef?
    private var messageHeadline: GtkRef?
    private var messageDetail: GtkRef?
    private var pairButton: GtkRef?

    public init(store: any SavedHostStoring) {
        GtkToolkit.start()
        self.store = store
        window = gtkRef(gtk_window_new())
        stack = gtkRef(gtk_stack_new())
        listPage = GtkWidgets.box(vertical: true, spacing: 16)
        pickerPage = GtkWidgets.box(vertical: true, spacing: 16)
        codePage = GtkWidgets.box(vertical: true, spacing: 16)

        gtk_window_set_title(sensorium_gtk_window(window), YourMachinesWindowModel.heading)
        gtk_window_set_default_size(sensorium_gtk_window(window), Self.windowWidth, -1)
        gtk_window_set_resizable(sensorium_gtk_window(window), 0)
        gtk_widget_add_css_class(sensorium_gtk_widget(window), "sensorium")

        for page in [listPage, pickerPage, codePage] {
            gtk_widget_set_margin_start(sensorium_gtk_widget(page), 24)
            gtk_widget_set_margin_end(sensorium_gtk_widget(page), 24)
            gtk_widget_set_margin_top(sensorium_gtk_widget(page), 24)
            gtk_widget_set_margin_bottom(sensorium_gtk_widget(page), 24)
        }
        gtk_stack_add_named(sensorium_gtk_stack(stack), sensorium_gtk_widget(listPage), "list")
        gtk_stack_add_named(sensorium_gtk_stack(stack), sensorium_gtk_widget(pickerPage), "picker")
        gtk_stack_add_named(sensorium_gtk_stack(stack), sensorium_gtk_widget(codePage), "code")
        gtk_window_set_child(sensorium_gtk_window(window), sensorium_gtk_widget(stack))

        installRowMenuActions()
        installKeys()
        installCloseRequest()
        reloadFromStore()
    }

    // MARK: - Showing and hiding

    /// Brings the list to the front and re-reads both the saved machines and
    /// the tailnet. Whatever step this window was left on is the step it comes
    /// back on: a "Pair again" that opened the code step must not be undone by
    /// the very call that puts it on screen.
    public func show() {
        if case .list = step {
            reloadFromStore()
        }
        gtk_window_present(sensorium_gtk_window(window))
        reloadTailnet()
    }

    /// Takes the window away without ending anything. The picture is up, so
    /// the list has nothing left to say until it is asked for again.
    public func hide() {
        gtk_widget_set_visible(sensorium_gtk_widget(window), 0)
    }

    public var isVisible: Bool {
        gtk_widget_get_visible(sensorium_gtk_widget(window)) != 0
    }

    // MARK: - What the dialling loop reports

    public func connectRequested(hostPublicKey: Data) {
        model.connectRequested(hostPublicKey: hostPublicKey)
        selectedHostPublicKey = hostPublicKey
        renderIfShowingList()
    }

    public func connectStarted(hostPublicKey: Data) {
        model.connectStarted(hostPublicKey: hostPublicKey)
        selectedHostPublicKey = hostPublicKey
        renderIfShowingList()
    }

    /// Cancelled, and unwinding. The row says so until it is actually free.
    public func stopping() {
        model.stopping()
        renderIfShowingList()
    }

    public func attemptFailed(reason: String, offersConnectAsVirtualDisplayFallback: Bool) {
        model.attemptFailed(
            reason: reason,
            offersConnectAsVirtualDisplayFallback: offersConnectAsVirtualDisplayFallback
        )
        renderIfShowingList()
    }

    public func stoppedConnecting(hostPublicKey: Data) {
        model.stoppedConnecting(hostPublicKey: hostPublicKey)
        renderIfShowingList()
    }

    public func stoppedTrying() {
        model.stoppedTrying()
        renderIfShowingList()
    }

    /// Straight to the code step for one saved machine, from a row's own "Pair
    /// again" or from the session panel's.
    public func beginPairAgain(with host: SavedHost) {
        let address = host.port == ViewerPairingForm.defaultPort
            ? host.host
            : "\(host.host):\(host.port)"
        enterCodeStep(
            device: ViewerPairingDevice(address: address, name: host.displayName),
            isPairingAgain: true
        )
        pairingAgainHostPublicKey = host.hostPublicKey
    }

    public func showList() {
        step = .list
        reloadFromStore()
    }

    /// Preselects the machine a deep link named, so Return connects the one
    /// that was asked for rather than whichever is at the top.
    public func select(hostPublicKey: Data) {
        selectedHostPublicKey = hostPublicKey
        renderIfShowingList()
    }

    // MARK: - Store and tailnet

    private func reloadFromStore() {
        let hosts = store.loadAll()
        model.replaceHosts(hosts, reachability: reachability)
        if selectedHostPublicKey == nil || !hosts.contains(where: { $0.hostPublicKey == selectedHostPublicKey }) {
            selectedHostPublicKey = hosts.first?.hostPublicKey
        }
        render()
    }

    private func reloadTailnet() {
        guard let loadTailnet else { return }
        pickerState = .loading
        if case .chooseDevice = step {
            render()
        }
        Task { @MainActor in
            let state = await loadTailnet()
            self.pickerState = state
            if case let .devices(rows) = state {
                self.reachability = SavedMachineReachability.byHostKey(
                    hosts: self.store.loadAll(), peers: rows.map(\.peer)
                )
                self.model.replaceHosts(self.store.loadAll(), reachability: self.reachability)
            }
            self.render()
        }
    }

    private func renderIfShowingList() {
        if case .list = step {
            render()
        }
    }

    // MARK: - Rendering

    private func render() {
        addressEntry = nil
        codeEntry = nil
        nameEntry = nil
        addressHint = nil
        codeHint = nil
        messageHeadline = nil
        messageDetail = nil
        pairButton = nil
        // Given up before the widget holding it is torn down: the window
        // keeps a pointer to whichever widget Return activates, and a rebuild
        // that destroys that widget first leaves the window pointing at an
        // object that no longer exists.
        gtk_window_set_default_widget(sensorium_gtk_window(window), nil)
        for page in [listPage, pickerPage, codePage] {
            GtkWidgets.removeAllChildren(of: page)
        }
        pageCallbacks = []
        switch step {
        case .list:
            buildListPage()
            gtk_stack_set_visible_child_name(sensorium_gtk_stack(stack), "list")
        case .chooseDevice:
            buildPickerPage()
            gtk_stack_set_visible_child_name(sensorium_gtk_stack(stack), "picker")
        case let .typeCode(device, isPairingAgain):
            buildCodePage(device: device, isPairingAgain: isPairingAgain)
            gtk_stack_set_visible_child_name(sensorium_gtk_stack(stack), "code")
        }
    }

    private func onClick(_ widget: GtkRef, _ body: @escaping @MainActor () -> Void) {
        let callback = GtkCallback(body)
        pageCallbacks.append(callback)
        gtkConnect(widget, "clicked", gtkClickedHandler, Unmanaged.passUnretained(callback).toOpaque())
    }

    private func onChanged(_ entry: GtkRef, _ body: @escaping @MainActor () -> Void) {
        let callback = GtkCallback(body)
        pageCallbacks.append(callback)
        gtkConnect(entry, "changed", gtkClickedHandler, Unmanaged.passUnretained(callback).toOpaque())
    }

    // MARK: - The list

    private func buildListPage() {
        GtkWidgets.append(GtkWidgets.label(YourMachinesWindowModel.heading, cssClass: GtkViewerStyle.Class.heading), to: listPage)

        let addButton = GtkWidgets.button(
            YourMachinesWindowModel.addTitle,
            cssClass: model.addIsPrimary ? GtkViewerStyle.Class.primary : nil
        )
        onClick(addButton) { [weak self] in self?.showAddAMachine() }

        if model.isEmpty {
            GtkWidgets.append(
                GtkWidgets.label(YourMachinesWindowModel.emptySentence, cssClass: GtkViewerStyle.Class.muted),
                to: listPage
            )
            GtkWidgets.append(addButton, to: listPage)
            // With nothing paired, adding a machine is the only thing this
            // window does, so it is also what Return means.
            gtk_widget_set_receives_default(sensorium_gtk_widget(addButton), 1)
            gtk_window_set_default_widget(sensorium_gtk_window(window), sensorium_gtk_widget(addButton))
            return
        }

        let list = GtkWidgets.box(vertical: true, spacing: 8)
        GtkWidgets.append(list, to: listPage)
        var defaultButton: GtkRef?
        for (index, row) in model.rows.enumerated() {
            GtkWidgets.append(buildRow(row, index: index, defaultButton: &defaultButton), to: list)
        }
        GtkWidgets.append(addButton, to: listPage)
        if let defaultButton {
            // Return connects the selected row, and only that one. Said once
            // the row is inside the window: a window takes its default widget
            // only from a widget already under it.
            gtk_window_set_default_widget(sensorium_gtk_window(window), sensorium_gtk_widget(defaultButton))
        }
    }

    private func buildRow(_ row: YourMachinesRow, index: Int, defaultButton: inout GtkRef?) -> GtkRef {
        let rowBox = GtkWidgets.box(vertical: false, spacing: 8)
        gtk_widget_add_css_class(sensorium_gtk_widget(rowBox), GtkViewerStyle.Class.row)

        let content = GtkWidgets.box(vertical: true, spacing: 2)
        GtkWidgets.append(GtkWidgets.label(row.name, cssClass: GtkViewerStyle.Class.rowName), to: content)
        let detailRow = GtkWidgets.box(vertical: false, spacing: 6)
        if let dotClass = Self.cssClass(for: row.dot) {
            GtkWidgets.append(GtkWidgets.label("\u{25CF}", cssClass: dotClass, wraps: false), to: detailRow)
        }
        GtkWidgets.append(GtkWidgets.label(row.detail, cssClass: GtkViewerStyle.Class.rowDetail), to: detailRow)
        GtkWidgets.append(detailRow, to: content)

        let rowButton = gtkRef(gtk_button_new())
        gtk_button_set_child(sensorium_gtk_button(rowButton), sensorium_gtk_widget(content))
        gtk_widget_set_hexpand(sensorium_gtk_widget(rowButton), 1)
        gtk_widget_set_receives_default(sensorium_gtk_widget(rowButton), 1)
        let hostPublicKey = row.hostPublicKey
        onClick(rowButton) { [weak self] in self?.rowClicked(hostPublicKey: hostPublicKey) }
        GtkWidgets.append(rowButton, to: rowBox)

        if row.hostPublicKey == selectedHostPublicKey {
            defaultButton = rowButton
        }

        if row.offersCancel {
            let cancel = GtkWidgets.button("Cancel", cssClass: nil)
            onClick(cancel) { [weak self] in self?.cancelConnecting() }
            GtkWidgets.append(cancel, to: rowBox)
        }

        let menuButton = gtkRef(gtk_menu_button_new())
        gtk_menu_button_set_label(sensorium_gtk_menu_button(menuButton), "\u{2026}")
        let menu = rowMenu(for: row, index: index)
        gtk_menu_button_set_menu_model(sensorium_gtk_menu_button(menuButton), sensorium_g_menu_model(menu))
        g_object_unref(menu)
        GtkWidgets.append(menuButton, to: rowBox)
        attachRightClick(to: rowButton, opening: menuButton)
        return rowBox
    }

    /// The same two actions a right-click offers, and the third only a failed
    /// host-screen attempt this machine's own "Start with" preference started
    /// has any use for. The row is named by number: GTK's own action machinery
    /// carries an integer, and the number indexes the rows this render drew.
    private func rowMenu(for row: YourMachinesRow, index: Int) -> GtkRef {
        let menu = gtkRef(g_menu_new())
        g_menu_append(sensorium_g_menu(menu), "Pair again", "machine.pair-again(\(index))")
        g_menu_append(sensorium_g_menu(menu), "Forget", "machine.forget(\(index))")
        if row.offersConnectAsVirtualDisplayFallback {
            // The same title `ViewerSessionAction.connectAsVirtualDisplay`
            // already carries for the live session panel's own button -- one
            // action, reached from whichever ending is on screen.
            g_menu_append(
                sensorium_g_menu(menu),
                "Connect with a virtual display",
                "machine.connect-virtual-display(\(index))"
            )
        }
        return menu
    }

    private func attachRightClick(to widget: GtkRef, opening menuButton: GtkRef) {
        let gesture = gtkRef(gtk_gesture_click_new())
        gtk_gesture_single_set_button(sensorium_gtk_gesture_single(gesture), 3)
        let callback = GtkCallback { gtk_menu_button_popup(sensorium_gtk_menu_button(menuButton)) }
        pageCallbacks.append(callback)
        let pressed: @convention(c) (GtkRef?, Int32, Double, Double, GtkRef?) -> Void = { _, _, _, _, data in
            gtkRunCallback(data)
        }
        gtkConnect(gesture, "pressed", pressed, Unmanaged.passUnretained(callback).toOpaque())
        gtk_widget_add_controller(sensorium_gtk_widget(widget), sensorium_gtk_event_controller(gesture))
    }

    private static func cssClass(for dot: YourMachinesRow.RowDot?) -> String? {
        switch dot {
        case .none: return nil
        case .online: return GtkViewerStyle.Class.dotOnline
        case .offline: return GtkViewerStyle.Class.dotOffline
        case .activity: return GtkViewerStyle.Class.dotActivity
        }
    }

    private func rowClicked(hostPublicKey: Data) {
        switch model.outcome(ofClickOn: hostPublicKey) {
        case .ignore:
            return
        case let .connect(key):
            connect(hostPublicKey: key)
        case let .cancelThenConnect(_, connecting):
            onCancelConnecting?()
            model.stoppedConnecting()
            connect(hostPublicKey: connecting)
        }
    }

    private func connect(hostPublicKey: Data) {
        guard let host = store.load(hostPublicKey: hostPublicKey) else { return }
        selectedHostPublicKey = hostPublicKey
        onConnect?(host)
    }

    private func cancelConnecting() {
        onCancelConnecting?()
        // Not idle yet: an attempt already out has to finish unwinding, and
        // the viewer says when it has.
        stopping()
    }

    /// The three things a row's own menu can do, installed on the window once
    /// and reached by every row that draws a menu.
    private func installRowMenuActions() {
        let group = gtkRef(g_simple_action_group_new())
        addRowAction("pair-again", to: group) { [weak self] row in
            guard let self, let host = self.store.load(hostPublicKey: row.hostPublicKey) else { return }
            self.beginPairAgain(with: host)
        }
        addRowAction("forget", to: group) { [weak self] row in
            self?.forget(hostPublicKey: row.hostPublicKey)
        }
        addRowAction("connect-virtual-display", to: group) { [weak self] row in
            self?.onConnectAsVirtualDisplayFallback?(row.hostPublicKey)
        }
        gtk_widget_insert_action_group(
            sensorium_gtk_widget(window), "machine", sensorium_g_action_group(group)
        )
        g_object_unref(group)
    }

    private func addRowAction(
        _ name: String,
        to group: GtkRef,
        _ body: @escaping @MainActor (YourMachinesRow) -> Void
    ) {
        let action = gtkRef(g_simple_action_new(name, sensorium_variant_type_int32()))
        let callback = GtkIndexedCallback { [weak self] index in
            guard let self, index >= 0, Int(index) < self.model.rows.count else { return }
            body(self.model.rows[Int(index)])
        }
        windowCallbacks.append(callback)
        gtkConnect(action, "activate", gtkActionActivateHandler, Unmanaged.passUnretained(callback).toOpaque())
        g_action_map_add_action(sensorium_g_action_map(group), sensorium_g_action(action))
        g_object_unref(action)
    }

    /// Forgetting asks nothing. It removes one entry from this machine's own
    /// list and changes nothing on the machine being forgotten; pairing again
    /// is the whole way back.
    private func forget(hostPublicKey: Data) {
        if model.connectingHostPublicKey == hostPublicKey {
            onCancelConnecting?()
            model.stoppedConnecting()
        }
        store.remove(hostPublicKey: hostPublicKey)
        if selectedHostPublicKey == hostPublicKey {
            selectedHostPublicKey = nil
        }
        reloadFromStore()
    }

    // MARK: - Add a machine, step one: which machine

    public func showAddAMachine() {
        step = .chooseDevice
        render()
        reloadTailnet()
    }

    /// Draws one device-list state directly, without a fetch.
    public func apply(deviceList state: TailnetDevicePickerState) {
        pickerState = state
        step = .chooseDevice
        render()
    }

    /// The second add step for a device already chosen, or -- with `nil` -- for
    /// an address about to be typed by hand.
    public func showCodeStep(for device: ViewerPairingDevice?, isPairingAgain: Bool = false) {
        enterCodeStep(device: device, isPairingAgain: isPairingAgain)
    }

    private func buildPickerPage() {
        // Every device on the tailnet is listed, not only ones running
        // Sensorium Host -- there is no way to tell those apart without a port
        // probe this app does not do, and an implied filter it cannot back up
        // is worse than an honest, unfiltered list.
        GtkWidgets.append(GtkWidgets.label("Add a Machine", cssClass: GtkViewerStyle.Class.heading), to: pickerPage)
        GtkWidgets.append(
            GtkWidgets.label(
                "Every other machine on your tailnet appears here, whether or not Sensorium Host is running on it.",
                cssClass: GtkViewerStyle.Class.muted
            ),
            to: pickerPage
        )

        switch pickerState {
        case .loading:
            GtkWidgets.append(
                GtkWidgets.label("Looking for machines on your tailnet\u{2026}", cssClass: GtkViewerStyle.Class.muted),
                to: pickerPage
            )
        case let .unreachable(reason):
            // No "Open Tailscale" here: this platform has no app to open, and
            // a button that cannot do anything is worse than none.
            GtkWidgets.append(GtkWidgets.label(reason, cssClass: GtkViewerStyle.Class.bad), to: pickerPage)
            appendLookAgain(to: pickerPage)
        case .noOtherDevices:
            GtkWidgets.append(
                GtkWidgets.label(
                    "Nothing else is on your tailnet yet. Sign in to Tailscale on the machine you want to work "
                        + "on, then choose Look again.",
                    cssClass: GtkViewerStyle.Class.muted
                ),
                to: pickerPage
            )
            appendLookAgain(to: pickerPage)
        case let .devices(rows):
            let list = GtkWidgets.box(vertical: true, spacing: 8)
            for row in rows {
                GtkWidgets.append(buildDeviceRow(row), to: list)
            }
            GtkWidgets.append(list, to: pickerPage)
            appendLookAgain(to: pickerPage)
        }

        let manual = GtkWidgets.button("Enter address manually\u{2026}", cssClass: GtkViewerStyle.Class.link)
        onClick(manual) { [weak self] in self?.enterCodeStep(device: nil, isPairingAgain: false) }
        GtkWidgets.append(manual, to: pickerPage)

        let back = GtkWidgets.button("Back", cssClass: GtkViewerStyle.Class.link)
        onClick(back) { [weak self] in self?.showList() }
        GtkWidgets.append(back, to: pickerPage)
    }

    private func appendLookAgain(to page: GtkRef) {
        let button = GtkWidgets.button("Look again", cssClass: GtkViewerStyle.Class.link)
        onClick(button) { [weak self] in self?.reloadTailnet() }
        GtkWidgets.append(button, to: page)
    }

    private func buildDeviceRow(_ row: TailnetDevicePickerRow) -> GtkRef {
        let content = GtkWidgets.box(vertical: true, spacing: 2)
        GtkWidgets.append(GtkWidgets.label(row.title, cssClass: GtkViewerStyle.Class.rowName), to: content)
        GtkWidgets.append(GtkWidgets.label(row.subtitle, cssClass: GtkViewerStyle.Class.rowDetail), to: content)
        let button = gtkRef(gtk_button_new())
        gtk_button_set_child(sensorium_gtk_button(button), sensorium_gtk_widget(content))
        gtk_widget_add_css_class(sensorium_gtk_widget(button), GtkViewerStyle.Class.row)
        let device = ViewerPairingDevice(address: row.peer.dialAddress, name: row.peer.displayName)
        onClick(button) { [weak self] in self?.enterCodeStep(device: device, isPairingAgain: false) }
        return button
    }

    // MARK: - Add a machine, step two: the code

    private func enterCodeStep(device: ViewerPairingDevice?, isPairingAgain: Bool) {
        step = .typeCode(device: device, isPairingAgain: isPairingAgain)
        form = device.map { ViewerPairingForm(address: $0.address, name: $0.name) } ?? ViewerPairingForm()
        isPairing = false
        codeErrorsRevealed = false
        pairIntentSent = false
        pairingAgainHostPublicKey = nil
        render()
        if let focus = device == nil ? addressEntry : codeEntry {
            gtk_widget_grab_focus(sensorium_gtk_widget(focus))
        }
        announceThisMachine(to: device)
    }

    private func buildCodePage(device: ViewerPairingDevice?, isPairingAgain: Bool) {
        GtkWidgets.append(
            GtkWidgets.label(
                device.map { "Type the Code Shown on \($0.label)" } ?? "Type the Code Shown on That Machine",
                cssClass: GtkViewerStyle.Class.heading
            ),
            to: codePage
        )
        if isPairingAgain {
            GtkWidgets.append(
                GtkWidgets.label("Pairing again replaces the saved key.", cssClass: GtkViewerStyle.Class.muted),
                to: codePage
            )
        }
        if device == nil {
            let entry = GtkWidgets.entry(placeholder: "mini.local", cssClass: nil)
            GtkWidgets.setText(form.address, on: entry)
            let hint = GtkWidgets.label(Self.addressHintText, cssClass: GtkViewerStyle.Class.muted)
            addressEntry = entry
            addressHint = hint
            onChanged(entry) { [weak self] in self?.formDidChange() }
            GtkWidgets.append(
                GtkWidgets.label("The address of the machine you want to add", cssClass: GtkViewerStyle.Class.sentence),
                to: codePage
            )
            GtkWidgets.append(entry, to: codePage)
            GtkWidgets.append(hint, to: codePage)
        }

        let code = GtkWidgets.entry(placeholder: "000 000", cssClass: GtkViewerStyle.Class.code)
        GtkWidgets.setText(ViewerPairingForm.groupedCodeDisplay(form.code), on: code)
        let codeHintLabel = GtkWidgets.label(Self.codeHintText, cssClass: GtkViewerStyle.Class.muted)
        codeEntry = code
        codeHint = codeHintLabel
        onChanged(code) { [weak self] in self?.formDidChange() }
        GtkWidgets.append(code, to: codePage)
        GtkWidgets.append(codeHintLabel, to: codePage)

        let headline = GtkWidgets.label("", cssClass: GtkViewerStyle.Class.bad)
        let detail = GtkWidgets.label("", cssClass: GtkViewerStyle.Class.muted)
        messageHeadline = headline
        messageDetail = detail
        gtk_widget_set_visible(sensorium_gtk_widget(headline), 0)
        gtk_widget_set_visible(sensorium_gtk_widget(detail), 0)
        GtkWidgets.append(headline, to: codePage)
        GtkWidgets.append(detail, to: codePage)

        let name = GtkWidgets.entry(placeholder: "Studio", cssClass: nil)
        GtkWidgets.setText(form.name, on: name)
        nameEntry = name
        onChanged(name) { [weak self] in self?.formDidChange() }
        GtkWidgets.append(
            GtkWidgets.label("Name (optional)", cssClass: GtkViewerStyle.Class.sentence), to: codePage
        )
        GtkWidgets.append(name, to: codePage)

        let buttons = GtkWidgets.box(vertical: false, spacing: 16)
        let pair = GtkWidgets.button("Pair", cssClass: GtkViewerStyle.Class.primary)
        pairButton = pair
        gtk_widget_set_receives_default(sensorium_gtk_widget(pair), 1)
        onClick(pair) { [weak self] in self?.submit() }
        GtkWidgets.append(pair, to: buttons)
        let back = GtkWidgets.button("Back", cssClass: GtkViewerStyle.Class.link)
        onClick(back) { [weak self] in
            self?.onCodeStepAbandoned?()
            self?.showList()
        }
        GtkWidgets.append(back, to: buttons)
        GtkWidgets.append(buttons, to: codePage)
        // Once the button is inside the window: a window takes its default
        // widget only from a widget already under it.
        gtk_window_set_default_widget(sensorium_gtk_window(window), sensorium_gtk_widget(pair))

        refresh()
    }

    /// Only a machine picked from the list, or one being paired again, has an
    /// address known before a code is typed. Typing one by hand has nothing to
    /// announce until a valid address exists, which the submission itself
    /// already covers.
    private func announceThisMachine(to device: ViewerPairingDevice?) {
        guard let device, let sendPairIntent, !pairIntentSent else { return }
        pairIntentSent = true
        Task { @MainActor in
            guard case let .failed(outcome) = await sendPairIntent(device) else { return }
            guard case let .typeCode(current, _) = self.step, current == device else { return }
            let copy = ViewerPairingFailureCopy.copy(for: outcome, hostLabel: device.label)
            self.showMessage(headline: copy.headline, detail: copy.detail)
        }
    }

    // MARK: - Live validation

    private func formDidChange() {
        guard !isRegroupingCode else { return }
        form = ViewerPairingForm(
            address: addressEntry.map(GtkWidgets.text(of:)) ?? form.address,
            code: codeEntry.map(GtkWidgets.text(of:)) ?? "",
            name: nameEntry.map(GtkWidgets.text(of:)) ?? ""
        )
        regroupCodeField()
        refresh()
    }

    /// Reformats the code field to `418 297` as it is typed, the same grouping
    /// the host panel shows -- `form` above already read the digits before this
    /// runs, so regrouping the display never changes what gets submitted.
    private func regroupCodeField() {
        guard let codeEntry else { return }
        let raw = GtkWidgets.text(of: codeEntry)
        let grouped = ViewerPairingForm.groupedCodeDisplay(raw)
        guard grouped != raw else { return }
        isRegroupingCode = true
        GtkWidgets.setText(grouped, on: codeEntry)
        gtk_editable_set_position(sensorium_gtk_editable(codeEntry), -1)
        isRegroupingCode = false
    }

    private func refresh() {
        if let addressHint {
            apply(state: form.addressState, to: addressHint, hint: Self.addressHintText, forceMuted: false)
        }
        if let codeHint {
            apply(
                state: form.codeState,
                to: codeHint,
                hint: Self.codeHintText,
                forceMuted: form.codeIsStillTyping && !codeErrorsRevealed
            )
        }
        if let pairButton {
            gtk_button_set_label(sensorium_gtk_button(pairButton), isPairing ? "Pairing\u{2026}" : "Pair")
            GtkWidgets.setEnabled(form.canSubmit && !isPairing, on: pairButton)
        }
    }

    /// One label per field, never an error line somewhere else: the message
    /// replaces the hint in place. `forceMuted` keeps the code field's
    /// count-down in its ordinary hint colour while it still reads as progress
    /// rather than a mistake.
    private func apply(state: ViewerPairingFieldState, to label: GtkRef, hint: String, forceMuted: Bool) {
        gtk_label_set_text(sensorium_gtk_label(label), state.message ?? hint)
        let isError = state.message != nil && !forceMuted
        gtk_widget_remove_css_class(
            sensorium_gtk_widget(label), isError ? GtkViewerStyle.Class.muted : GtkViewerStyle.Class.bad
        )
        gtk_widget_add_css_class(
            sensorium_gtk_widget(label), isError ? GtkViewerStyle.Class.bad : GtkViewerStyle.Class.muted
        )
    }

    private func showMessage(headline: String, detail: String) {
        if let messageHeadline {
            gtk_label_set_text(sensorium_gtk_label(messageHeadline), headline)
            gtk_widget_set_visible(sensorium_gtk_widget(messageHeadline), headline.isEmpty ? 0 : 1)
        }
        if let messageDetail {
            gtk_label_set_text(sensorium_gtk_label(messageDetail), detail)
            gtk_widget_set_visible(sensorium_gtk_widget(messageDetail), detail.isEmpty ? 0 : 1)
        }
    }

    private func setFieldsEditable(_ editable: Bool) {
        for entry in [addressEntry, codeEntry, nameEntry].compactMap({ $0 }) {
            gtk_editable_set_editable(sensorium_gtk_editable(entry), editable ? 1 : 0)
        }
    }

    // MARK: - Pairing

    private func submit() {
        guard case let .typeCode(device, _) = step else { return }
        guard !isPairing, let submission = form.submission, let pair else { return }
        isPairing = true
        codeErrorsRevealed = true
        setFieldsEditable(false)
        refresh()
        showMessage(
            headline: "Asking \(submission.displayName) to accept this machine\u{2026}",
            detail: "This takes a moment. Leave the code on \(submission.displayName)\u{2019}s screen "
                + "until this finishes."
        )

        Task { @MainActor in
            let result = await pair(device, submission)
            self.isPairing = false
            switch result {
            case let .paired(host):
                if let replaced = self.pairingAgainHostPublicKey, replaced != host.hostPublicKey {
                    self.store.remove(hostPublicKey: replaced)
                }
                self.pairingAgainHostPublicKey = nil
                self.store.save(host)
                self.selectedHostPublicKey = host.hostPublicKey
                self.showList()
                self.onConnect?(host)
            case let .failed(outcome):
                let copy = ViewerPairingFailureCopy.copy(for: outcome, hostLabel: submission.displayName)
                self.setFieldsEditable(true)
                if copy.needsFreshCode, let codeEntry = self.codeEntry {
                    // Retyping a spent code can only fail again, and a field
                    // still holding it invites exactly that.
                    GtkWidgets.setText("", on: codeEntry)
                }
                self.formDidChange()
                self.showMessage(headline: copy.headline, detail: copy.detail)
                if let focus = self.entry(for: copy.focus) {
                    gtk_widget_grab_focus(sensorium_gtk_widget(focus))
                }
            }
        }
    }

    private func entry(for field: ViewerPairingField) -> GtkRef? {
        switch field {
        case .address: return addressEntry
        case .code: return codeEntry
        case .name: return nameEntry
        }
    }

    // MARK: - Window

    /// There is no Quit button in this window, so its own close control is how
    /// a person leaves from here. Refused rather than performed, so the
    /// viewer's own quit path is what actually ends the process.
    private func installCloseRequest() {
        let callback = GtkCallback { [weak self] in
            self?.onCloseRequested?()
        }
        windowCallbacks.append(callback)
        let closeRequest: @convention(c) (GtkRef?, GtkRef?) -> gboolean = { _, data in
            gtkRunCallback(data)
            return 1
        }
        gtkConnect(window, "close-request", closeRequest, Unmanaged.passUnretained(callback).toOpaque())
    }

    /// The two chords the menu bar carries on macOS. There is no menu bar
    /// here, and quitting has to work before any machine has been reached.
    private func installKeys() {
        let callback = GtkIndexedCallback { [weak self] keyval in
            guard let self else { return }
            switch keyval {
            case Int32(GDK_KEY_q), Int32(GDK_KEY_Q):
                self.onCloseRequested?()
            case Int32(GDK_KEY_1):
                self.showList()
                self.show()
            default:
                break
            }
        }
        windowCallbacks.append(callback)
        let controller = gtkRef(gtk_event_controller_key_new())
        let pressed: @convention(c) (GtkRef?, guint, guint, GdkModifierType, GtkRef?) -> gboolean = {
            _, keyval, _, state, data in
            guard sensorium_modifier_has_control(state) != 0, let data else { return 0 }
            let claimed: Set<guint> = [guint(GDK_KEY_q), guint(GDK_KEY_Q), guint(GDK_KEY_1)]
            guard claimed.contains(keyval) else { return 0 }
            gtkRunIndexedCallback(data, Int32(bitPattern: keyval))
            return 1
        }
        gtkConnect(controller, "key-pressed", pressed, Unmanaged.passUnretained(callback).toOpaque())
        gtk_widget_add_controller(sensorium_gtk_widget(window), sensorium_gtk_event_controller(controller))
    }
}
#endif

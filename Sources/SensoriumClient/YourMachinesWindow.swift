#if canImport(AppKit)
import AppKit
import Foundation
import SensoriumCore

/// The only window at launch: the machines this one has paired with, and the two
/// steps that add another. Nothing is dialled until a row is clicked, and the
/// canvas window does not exist until a picture arrives.
///
/// Deliberately thin, like every other window in this viewer. Which rows
/// appear, what the line under each name says and what a click means are
/// `YourMachinesWindowModel`'s decisions; what may be typed into the code step and
/// what each failure says are `ViewerPairingForm`'s and
/// `ViewerPairingFailureCopy`'s. This holds views, and asks.
@MainActor
public final class YourMachinesWindowController: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    /// Which of the three screens this one window is showing. Adding a machine is
    /// two steps inside this window rather than windows of its own: a person
    /// who has just clicked "Add a machine" is still in the same place they
    /// started, and the way back is a link rather than a close button.
    private enum Step: Equatable {
        case list
        case chooseDevice
        /// `device` is `nil` only for an address being typed by hand, the one
        /// path that has no machine picked yet.
        case typeCode(device: ViewerPairingDevice?, isPairingAgain: Bool)
    }

    private let store: any SavedHostStoring
    /// One fetch of this machine's tailnet, used twice: for the device list on the
    /// add step, and for the online/offline note on each saved row.
    public var loadTailnet: (() async -> TailnetDevicePickerState)?
    /// Announces this machine to the one being paired, so it can show a code.
    /// Called exactly once per visit to the code step.
    public var sendPairIntent: ((ViewerPairingDevice) async -> ViewerPairIntentAttempt)?
    /// One pairing attempt. The device is `nil` for a hand-typed address.
    public var pair: ((ViewerPairingDevice?, ViewerPairingSubmission) async -> ViewerPairingResult)?
    /// A machine to connect to: a row the person clicked, or one they just paired.
    public var onConnect: ((SavedHost) -> Void)?
    /// Stop the attempt currently out. Fired by a row's own Cancel, and by
    /// clicking a different machine while one is still dialling.
    public var onCancelConnecting: (() -> Void)?
    /// A row's own "\u{2026}" menu offered "Connect with a virtual display"
    /// -- nothing here is automatic beyond that: the one explicit way a
    /// failed host-screen attempt this machine's own "Start with"
    /// preference started switches to a virtual display and tries again.
    /// Offered only while `YourMachinesRow.offersConnectAsVirtualDisplayFallback`
    /// is true for the clicked row.
    public var onConnectAsVirtualDisplayFallback: ((Data) -> Void)?
    /// What the red button means. There is no Quit button in this window --
    /// Command-Q is how Sensorium is quit -- so closing the only window on
    /// screen is the same choice, and the viewer wires this to the one quit
    /// latch a signal and the menu bar both fire.
    public var onCloseRequested: (() -> Void)?
    /// The code step was left without pairing. Whatever was opened to announce
    /// this machine has nobody left to announce it to.
    public var onCodeStepAbandoned: (() -> Void)?
    /// Answers, in one sentence, whether this machine can be allowed to see a
    /// host screen -- `docs/host-screen-design.md` §6.3 -- before anyone has typed a thing. `nil`
    /// leaves the line out rather than guessing.
    private let credentialProvider: (any PresenceCredentialProviding)?
    /// Looked up fresh whenever the tailscaled-unreachable state is drawn,
    /// never cached: whether Tailscale is installed can change while this
    /// window is open.
    private let tailscaleAppURLLookup: @MainActor () -> URL?
    private let onOpenTailscaleApp: @MainActor (URL) -> Void
    /// The URL a tap on the Open Tailscale button opens right now. `nil` only
    /// when the button itself is absent.
    private var tailscaleActionURL: URL?

    private let window: NSWindow
    private let root = NSStackView()
    private let contentContainer = NSView()
    private var step: Step = .list
    private var model = YourMachinesWindowModel(hosts: [])
    private var reachability: [Data: Bool] = [:]
    private var pickerState: TailnetDevicePickerState = .loading
    /// Which row Return connects. The first row on open, and the newly paired
    /// machine right after a pairing.
    private var selectedHostPublicKey: Data?
    private var rowButtons: [SavedMachineRowButton] = []

    // MARK: Code step

    private let addressField = ViewerFormControls.textField(mono: true, size: 14)
    private let codeField = ViewerFormControls.textField(mono: true, size: 20)
    private let nameField = ViewerFormControls.textField(mono: false, size: 14)
    private let addressHint = ViewerFormControls.hintLabel(width: YourMachinesWindowController.contentWidth)
    private let codeHint = ViewerFormControls.hintLabel(width: YourMachinesWindowController.contentWidth)
    private let nameHint = ViewerFormControls.hintLabel(width: YourMachinesWindowController.contentWidth)
    /// Always active: the address hint/error row stays the height of the
    /// two-line default hint whether that hint or a shorter error is showing,
    /// so the code field, name field and Pair button below it never move as an
    /// error appears or clears.
    private var addressHintReservedHeight: NSLayoutConstraint?
    private let pairButton = ViewerFormControls.actionButton("Pair")
    private let messageHeadline = ViewerFormControls.label(
        "", font: ViewerDesign.font(mono: false, size: 13, weight: .medium),
        color: ViewerDesign.ink, width: YourMachinesWindowController.contentWidth
    )
    private let messageDetail = ViewerFormControls.label(
        "", font: ViewerDesign.font(mono: false, size: 12),
        color: ViewerDesign.muted, width: YourMachinesWindowController.contentWidth
    )
    private let credentialLine = ViewerFormControls.label(
        "", font: ViewerDesign.font(mono: false, size: 12),
        color: ViewerDesign.muted, width: YourMachinesWindowController.contentWidth
    )
    /// The saved machine a "Pair again" is for, or `nil` when this is a machine being
    /// added. A machine that answers with a new key is the same machine to the person
    /// who started this, so its old record is replaced rather than left
    /// listed beside the new one, offering a row that can never connect.
    private var pairingAgainHostPublicKey: Data?
    private var form = ViewerPairingForm()
    private var isPairing = false
    /// Guards `sendPairIntent` to exactly one call per visit to the code step;
    /// retyping a wrong code and resubmitting must never fire it again.
    private var pairIntentSent = false
    /// True once the code field has lost focus, or a submission has been
    /// tried, since the code was last still-typing -- until then a count-down
    /// message reads as progress, not a mistake, and stays muted rather than
    /// red.
    private var codeErrorsRevealed = false
    /// Asked once per launch, not once per visit: the answer is about this
    /// machine, and nothing between two visits to the code step can change it.
    private var credentialLineRequested = false

    private static let windowWidth: CGFloat = 460
    private static let contentWidth = windowWidth - ViewerDesign.Space.xl * 2

    private static let addressHintText = "Tailscale address, or a name like mini.local."
    private static let codeHintText =
        "Shown by Sensorium Host on that machine under Show pairing code."

    public init(
        store: any SavedHostStoring,
        credentialProvider: (any PresenceCredentialProviding)? = nil,
        // Tailscale's own bundle identifiers, macsys (the system-extension
        // build) checked first: whichever one is actually installed is the one
        // this machine has. The same pair the host's own setup window uses.
        tailscaleAppURLLookup: @escaping @MainActor () -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys")
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos")
        },
        onOpenTailscaleApp: @escaping @MainActor (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        }
    ) {
        self.store = store
        self.credentialProvider = credentialProvider
        self.tailscaleAppURLLookup = tailscaleAppURLLookup
        self.onOpenTailscaleApp = onOpenTailscaleApp
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Sensorium"
        // Dark whatever this machine is set to, so the field editor, the caret
        // and the selection match the palette instead of the machine.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = ViewerDesign.chromeBg.nsColor
        window.isReleasedWhenClosed = false
        window.delegate = self

        addressField.placeholderAttributedString = ViewerFormControls.placeholder("mini.local", mono: true, size: 14)
        addressField.delegate = self
        // Grouped exactly as the other machine shows it, because the field takes
        // the code either way and the placeholder is where that is learned.
        codeField.placeholderAttributedString = ViewerFormControls.placeholder("000 000", mono: true, size: 20)
        codeField.delegate = self
        nameField.placeholderAttributedString = ViewerFormControls.placeholder("Studio", mono: false, size: 14)
        nameField.delegate = self
        pairButton.target = self
        pairButton.action = #selector(submit)

        buildFrame()
        reloadFromStore()
    }

    // MARK: - Showing and hiding

    /// Brings the list to the front and re-reads both the saved machines and the
    /// tailnet. Called at launch, from the menu bar's own item, and whenever a
    /// session ends and the person asks for the list again.
    public func show() {
        // A raw SwiftPM binary has no Info.plist to imply this, and without it
        // AppKit has no reason to give this process a menu bar or keyboard
        // focus -- which is exactly what a list of buttons needs.
        NSApplication.shared.setActivationPolicy(.regular)
        // Whatever step this window was left on is the step it comes back on:
        // a "Pair again" that opened the code step must not be undone by the
        // very call that puts it on screen. `showList()` is how a caller asks
        // for the list itself.
        if case .list = step {
            reloadFromStore()
        }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        reloadTailnet()
    }

    /// Orders the window away without ending anything. The picture is up, so
    /// the list has nothing left to say until it is asked for again.
    public func hide() {
        window.orderOut(nil)
    }

    public var isVisible: Bool { window.isVisible }

    // MARK: - What the dialling loop reports

    /// A machine was clicked. The row says so from here, not from whenever a
    /// socket gets around to opening.
    public func connectRequested(hostPublicKey: Data) {
        model.connectRequested(hostPublicKey: hostPublicKey)
        selectedHostPublicKey = hostPublicKey
        if case .list = step {
            renderStep()
        }
    }

    /// One attempt is starting, of however many the retry loop makes.
    public func connectStarted(hostPublicKey: Data) {
        model.connectStarted(hostPublicKey: hostPublicKey)
        selectedHostPublicKey = hostPublicKey
        if case .list = step {
            renderStep()
        }
    }

    /// Cancelled, and unwinding. The row says so until it is actually free.
    public func stopping() {
        model.stopping()
        if case .list = step {
            renderStep()
        }
    }

    /// One attempt ended without a session, in words already chosen by
    /// `ViewerSessionFailureCopy`.
    public func attemptFailed(reason: String, offersConnectAsVirtualDisplayFallback: Bool = false) {
        model.attemptFailed(reason: reason, offersConnectAsVirtualDisplayFallback: offersConnectAsVirtualDisplayFallback)
        if case .list = step {
            renderStep()
        }
    }

    public func stoppedConnecting() {
        model.stoppedConnecting()
        if case .list = step {
            renderStep()
        }
    }

    /// The same, for one named machine: a no-op once another machine's own attempt
    /// has taken the row's place.
    public func stoppedConnecting(hostPublicKey: Data) {
        model.stoppedConnecting(hostPublicKey: hostPublicKey)
        if case .list = step {
            renderStep()
        }
    }

    /// Every attempt is spent. The row keeps the last one's reason and
    /// becomes clickable again, since clicking it is how it is tried again.
    public func stoppedTrying() {
        model.stoppedTrying()
        if case .list = step {
            renderStep()
        }
    }

    /// Straight to the code step for one saved machine, from a row's own "Pair
    /// again" or from the session overlay's.
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

    /// Back to the list, wherever the window was. Used when a session ends and
    /// the person asks for the list again mid-way through adding a machine.
    public func showList() {
        step = .list
        reloadFromStore()
    }

    /// Preselects the machine a deep link named, so Return connects the one that
    /// was asked for rather than whichever is at the top.
    public func select(hostPublicKey: Data) {
        selectedHostPublicKey = hostPublicKey
        if case .list = step {
            renderStep()
        }
    }

    // MARK: - Store and tailnet

    private func reloadFromStore() {
        let hosts = store.loadAll()
        model.replaceHosts(hosts, reachability: reachability)
        if selectedHostPublicKey == nil || !hosts.contains(where: { $0.hostPublicKey == selectedHostPublicKey }) {
            selectedHostPublicKey = hosts.first?.hostPublicKey
        }
        renderStep()
    }

    private func reloadTailnet() {
        guard let loadTailnet else { return }
        pickerState = .loading
        if case .chooseDevice = step {
            renderStep()
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
            self.renderStep()
        }
    }

    // MARK: - Layout

    private func buildFrame() {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = ViewerDesign.chromeBg.cgColor

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = ViewerDesign.Space.xs
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addArrangedSubview(contentContainer)
        contentContainer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true

        let inset = ViewerDesign.Space.xl
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
            root.widthAnchor.constraint(equalToConstant: Self.contentWidth)
        ])

        window.contentView = content
    }

    /// The window has no scroll view and no resize control, so its height is
    /// whatever the content currently needs -- one more line of failure copy
    /// grows it rather than clipping it.
    private func resizeToFit() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = ceil(root.fittingSize.height) + ViewerDesign.Space.xl * 2
        window.setContentSize(NSSize(width: Self.windowWidth, height: height))
    }

    private func renderStep() {
        for view in contentContainer.subviews {
            view.removeFromSuperview()
        }
        rowButtons = []
        let body: NSView
        switch step {
        case .list:
            body = listBody()
        case .chooseDevice:
            body = chooseDeviceBody()
        case let .typeCode(device, isPairingAgain):
            body = codeBody(device: device, isPairingAgain: isPairingAgain)
        }
        body.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(body)
        NSLayoutConstraint.activate([
            body.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            body.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            body.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor)
        ])
        resizeToFit()
    }

    private func column(_ views: [NSView], spacing: CGFloat = ViewerDesign.Space.sm) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func heading(_ text: String) -> NSTextField {
        ViewerFormControls.label(
            text,
            font: ViewerDesign.font(mono: false, size: 20, weight: .medium),
            color: ViewerDesign.ink,
            width: Self.contentWidth
        )
    }

    private func sentence(_ text: String, color: ViewerColor = ViewerDesign.muted) -> NSTextField {
        ViewerFormControls.label(
            text,
            font: ViewerDesign.font(mono: false, size: 13),
            color: color,
            width: Self.contentWidth
        )
    }

    /// The loading line's own dot, beside the words rather than replacing
    /// them -- pulsing while the fetch is actually in flight says the wait is
    /// doing something, without the words changing again to say so.
    private func loadingSentence(_ text: String) -> NSView {
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        dot.layer?.backgroundColor = ViewerDesign.warn.cgColor
        dot.layer?.cornerRadius = 3
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6)
        ])
        ViewerPulse.apply(to: dot.layer)
        let row = NSStackView(views: [dot, sentence(text)])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = ViewerDesign.Space.xxs
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    // MARK: - The list

    private func listBody() -> NSView {
        let addButton = ViewerFormControls.actionButton(YourMachinesWindowModel.addTitle)
        addButton.target = self
        addButton.action = #selector(addAMachine)
        ViewerFormControls.style(
            addButton, title: YourMachinesWindowModel.addTitle, isPrimary: model.addIsPrimary, isEnabled: true
        )

        var views: [NSView] = [heading(YourMachinesWindowModel.heading)]
        if model.isEmpty {
            views.append(sentence(YourMachinesWindowModel.emptySentence))
            // With nothing paired, adding a machine is the only thing this window
            // does, so it is also what Return means.
            addButton.keyEquivalent = "\r"
        } else {
            let list = column([], spacing: ViewerDesign.Space.xs)
            for row in model.rows {
                let button = SavedMachineRowButton(row: row, isSelected: row.hostPublicKey == selectedHostPublicKey)
                button.target = self
                button.action = #selector(rowClicked(_:))
                button.cancelButton.target = self
                button.cancelButton.action = #selector(cancelConnecting)
                button.moreButton.target = self
                button.moreButton.action = #selector(showRowMenu(_:))
                button.rowMenu = rowMenu(for: row)
                // Return connects the selected row, and only that one: a key
                // equivalent is matched before the key view's own key path,
                // so exactly one button on screen may claim it.
                button.keyEquivalent = row.hostPublicKey == selectedHostPublicKey ? "\r" : ""
                list.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                rowButtons.append(button)
            }
            views.append(list)
        }
        let stack = column(views, spacing: ViewerDesign.Space.md)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        // Left unconstrained: a button stretched to the column's full width
        // draws its title centred in the window instead of at the paragraph's
        // left edge.
        stack.addArrangedSubview(addButton)
        return stack
    }

    private func rowMenu(for row: YourMachinesRow) -> NSMenu {
        let menu = NSMenu()
        var actions = [
            ("Pair again", #selector(pairAgainFromRow(_:))),
            ("Forget", #selector(forgetRow(_:)))
        ]
        if row.offersConnectAsVirtualDisplayFallback {
            // The same title `ViewerSessionAction.connectAsVirtualDisplay`
            // already carries for the live session panel's own button --
            // one action, reached from whichever ending is on screen.
            actions.append(("Connect with a virtual display", #selector(connectAsVirtualDisplayFromRow(_:))))
        }
        for (title, action) in actions {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = row.hostPublicKey
            menu.addItem(item)
        }
        return menu
    }

    @objc private func rowClicked(_ sender: SavedMachineRowButton) {
        switch model.outcome(ofClickOn: sender.hostPublicKey) {
        case .ignore:
            return
        case let .connect(hostPublicKey):
            connect(hostPublicKey: hostPublicKey)
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

    @objc private func cancelConnecting() {
        onCancelConnecting?()
        // Not idle yet: an attempt already out has to finish unwinding, and
        // the viewer says when it has.
        stopping()
    }

    @objc private func showRowMenu(_ sender: NSButton) {
        guard let row = sender.superview as? SavedMachineRowButton, let menu = row.rowMenu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func pairAgainFromRow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? Data, let host = store.load(hostPublicKey: key) else { return }
        beginPairAgain(with: host)
    }

    /// The row's own way out of a failed host-screen attempt a saved
    /// preference started -- see `onConnectAsVirtualDisplayFallback`.
    @objc private func connectAsVirtualDisplayFromRow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? Data else { return }
        onConnectAsVirtualDisplayFallback?(key)
    }

    /// Forgetting asks nothing. It removes one entry from this machine's own list
    /// and changes nothing on the machine being forgotten; pairing again is the
    /// whole way back.
    @objc private func forgetRow(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? Data else { return }
        if model.connectingHostPublicKey == key {
            onCancelConnecting?()
            model.stoppedConnecting()
        }
        store.remove(hostPublicKey: key)
        if selectedHostPublicKey == key {
            selectedHostPublicKey = nil
        }
        reloadFromStore()
    }

    // MARK: - Add a machine, step one: which machine

    /// The first of the two add steps. Public so callers -- and the runners,
    /// and the preview renderer -- can reach every step of this window without
    /// a real tailnet or the timing of one.
    public func showAddAMachine() {
        step = .chooseDevice
        renderStep()
        reloadTailnet()
    }

    /// Draws one device-list state directly, without a fetch.
    public func apply(deviceList state: TailnetDevicePickerState) {
        pickerState = state
        step = .chooseDevice
        renderStep()
    }

    /// The second add step for a device already chosen, or -- with `nil` -- for
    /// an address about to be typed by hand.
    public func showCodeStep(for device: ViewerPairingDevice?, isPairingAgain: Bool = false) {
        enterCodeStep(device: device, isPairingAgain: isPairingAgain)
    }

    @objc private func addAMachine() {
        showAddAMachine()
    }

    private func chooseDeviceBody() -> NSView {
        // Every device on the tailnet is listed, not only ones running
        // Sensorium Host -- there is no way to tell those apart without a port
        // probe this app does not do, and an implied filter it cannot back up
        // is worse than an honest, unfiltered list.
        var views: [NSView] = [
            heading("Add a Machine"),
            sentence(
                "Every other machine on your tailnet appears here, whether or not Sensorium Host is running on it."
            )
        ]

        switch pickerState {
        case .loading:
            views.append(loadingSentence("Looking for machines on your tailnet\u{2026}"))
        case let .unreachable(reason):
            views.append(sentence(reason, color: ViewerDesign.bad))
            // An "Open Tailscale" button beside Look again, but only when
            // Tailscale is actually installed and only for a tailscaled that
            // could not be asked: an empty tailnet is answered fine and is not
            // a reason to suggest opening another app.
            if let appURL = tailscaleAppURLLookup() {
                tailscaleActionURL = appURL
                let open = ViewerFormControls.linkButton("Open Tailscale", symbol: "arrow.up.forward.app")
                open.target = self
                open.action = #selector(openTailscale)
                let button = ViewerFormControls.linkButton("Look again", symbol: "arrow.clockwise")
                button.target = self
                button.action = #selector(lookAgain)
                views.append(leadingRow([button, open]))
            } else {
                tailscaleActionURL = nil
                views.append(lookAgainLink())
            }
        case .noOtherDevices:
            views.append(sentence(
                "Nothing else is on your tailnet yet. Sign in to Tailscale on the machine you want to work "
                    + "on, then choose Look again."
            ))
            views.append(lookAgainLink())
        case let .devices(rows):
            let list = column([], spacing: ViewerDesign.Space.xs)
            for row in rows {
                let button = TailnetDeviceRowButton(row: row)
                button.target = self
                button.action = #selector(deviceChosen(_:))
                list.addArrangedSubview(button)
                button.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            views.append(list)
            views.append(lookAgainLink())
        }

        let manual = ViewerFormControls.linkButton("Enter address manually\u{2026}", symbol: "keyboard")
        manual.target = self
        manual.action = #selector(enterAddressManually)
        let back = ViewerFormControls.linkButton("Back", symbol: "chevron.left")
        back.target = self
        back.action = #selector(backToList)

        let stack = column(views, spacing: ViewerDesign.Space.md)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        stack.addArrangedSubview(manual)
        stack.addArrangedSubview(back)
        return stack
    }

    /// Wrapped in a row of its own: an arranged view here is stretched to the
    /// step's full width, and a button that wide draws its title centred. The
    /// row takes the width; the link keeps its own and stays at the left edge,
    /// where every other link on this step starts.
    private func lookAgainLink() -> NSView {
        let button = ViewerFormControls.linkButton("Look again", symbol: "arrow.clockwise")
        button.target = self
        button.action = #selector(lookAgain)
        return leadingRow([button])
    }

    private func leadingRow(_ views: [NSView]) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = ViewerDesign.Space.lg
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    @objc private func lookAgain() {
        reloadTailnet()
    }

    @objc private func openTailscale() {
        guard let url = tailscaleActionURL else { return }
        onOpenTailscaleApp(url)
    }

    @objc private func deviceChosen(_ sender: TailnetDeviceRowButton) {
        enterCodeStep(
            device: ViewerPairingDevice(address: sender.row.peer.dialAddress, name: sender.row.peer.displayName),
            isPairingAgain: false
        )
    }

    @objc private func enterAddressManually() {
        enterCodeStep(device: nil, isPairingAgain: false)
    }

    @objc private func backToList() {
        showList()
    }

    // MARK: - Add a machine, step two: the code

    private func enterCodeStep(device: ViewerPairingDevice?, isPairingAgain: Bool) {
        step = .typeCode(device: device, isPairingAgain: isPairingAgain)
        form = device.map { ViewerPairingForm(address: $0.address, name: $0.name) } ?? ViewerPairingForm()
        addressField.stringValue = device?.address ?? ""
        nameField.stringValue = device?.name ?? ""
        codeField.stringValue = ""
        isPairing = false
        codeErrorsRevealed = false
        pairIntentSent = false
        pairingAgainHostPublicKey = nil
        messageHeadline.stringValue = ""
        messageDetail.stringValue = ""
        setFieldsEditable(true)
        renderStep()
        window.makeFirstResponder(device == nil ? addressField : codeField)
        requestCredentialLine()
        announceThisMachine(to: device)
    }

    private func codeBody(device: ViewerPairingDevice?, isPairingAgain: Bool) -> NSView {
        addressHint.stringValue = Self.addressHintText
        codeHint.stringValue = Self.codeHintText
        nameHint.isHidden = true
        // The default hint is the tallest text this field ever shows -- fixing
        // its height here keeps the code field, name field and Pair button in
        // place whether the hint changes length within itself or is replaced
        // by a shorter error.
        addressHintReservedHeight?.isActive = false
        let reserved = addressHint.heightAnchor.constraint(
            equalToConstant: addressHint.intrinsicContentSize.height
        )
        reserved.isActive = true
        addressHintReservedHeight = reserved

        var views: [NSView] = [
            heading(
                device.map { "Type the Code Shown on \($0.label)" }
                    ?? "Type the Code Shown on That Machine"
            )
        ]
        if isPairingAgain {
            views.append(sentence("Pairing again replaces the saved key."))
        }
        if !credentialLine.stringValue.isEmpty {
            views.append(credentialLine)
        }
        if device == nil {
            views.append(fieldGroup(
                label: "The address of the machine you want to add",
                field: addressField,
                hint: addressHint,
                fieldHeight: 32
            ))
        }
        views.append(fieldGroup(label: nil, field: codeField, hint: codeHint, fieldHeight: 44))
        views.append(messageHeadline)
        views.append(messageDetail)
        views.append(fieldGroup(
            label: "Name (optional)",
            field: nameField,
            hint: nameHint,
            fieldHeight: 32
        ))

        let back = ViewerFormControls.linkButton("Back", symbol: "chevron.left")
        back.target = self
        back.action = #selector(backFromCode)
        let buttonRow = NSStackView(views: [pairButton, back])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = ViewerDesign.Space.md
        views.append(buttonRow)

        let stack = column(views, spacing: ViewerDesign.Space.md)
        for view in stack.arrangedSubviews where view !== buttonRow {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        messageHeadline.isHidden = messageHeadline.stringValue.isEmpty
        messageDetail.isHidden = messageDetail.stringValue.isEmpty
        refresh()
        return stack
    }

    /// A field, its sentence label where it has one, and the hint or error
    /// that belongs beside it. The code field needs no label: the heading
    /// above it already says what is being typed.
    private func fieldGroup(
        label: String?,
        field: NSTextField,
        hint: NSTextField,
        fieldHeight: CGFloat
    ) -> NSView {
        var views: [NSView] = []
        if let label {
            views.append(sentence(label))
        }
        views.append(field)
        views.append(hint)
        let stack = column(views, spacing: ViewerDesign.Space.xxs)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        field.heightAnchor.constraint(equalToConstant: fieldHeight).isActive = true
        return stack
    }

    @objc private func backFromCode() {
        onCodeStepAbandoned?()
        showList()
    }

    private func requestCredentialLine() {
        guard let credentialProvider, !credentialLineRequested else { return }
        credentialLineRequested = true
        Task { @MainActor in
            let line: String
            do {
                _ = try await credentialProvider.register()
                line = PresenceCredentialRegistrationCopy.successLine
            } catch {
                line = PresenceCredentialRegistrationCopy.line(for: error)
            }
            self.credentialLine.stringValue = line
            if case .typeCode = self.step {
                self.renderStep()
            }
        }
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
            self.showMessage(headline: copy.headline, detail: copy.detail, tone: .bad)
        }
    }

    private func showMessage(headline: String, detail: String, tone: ViewerStatusTone) {
        messageHeadline.stringValue = headline
        messageHeadline.textColor = (tone == .bad ? ViewerDesign.bad : ViewerDesign.ink).nsColor
        messageDetail.stringValue = detail
        messageHeadline.isHidden = headline.isEmpty
        messageDetail.isHidden = detail.isEmpty
        resizeToFit()
    }

    // MARK: - Live validation

    public func controlTextDidChange(_ notification: Notification) {
        form = ViewerPairingForm(
            address: addressField.stringValue,
            code: codeField.stringValue,
            name: nameField.stringValue
        )
        regroupCodeField()
        refresh()
    }

    /// Reformats the code field to `418 297` as it is typed, the same grouping
    /// the host panel shows -- `form` above already read the digits before this
    /// runs, so regrouping the display never changes what gets submitted. The
    /// caret moves with its own digit, not to the end, so correcting a digit in
    /// the middle of the code does not jump the cursor past what was just
    /// typed.
    private func regroupCodeField() {
        let raw = codeField.stringValue
        let grouped = ViewerPairingForm.groupedCodeDisplay(raw)
        guard grouped != raw else { return }
        let editor = window.fieldEditor(false, for: codeField) as? NSTextView
        let digitsBeforeCaret = editor.map { raw.prefix($0.selectedRange().location).filter(\.isNumber).count }
        codeField.stringValue = grouped
        guard let editor, let digitsBeforeCaret else { return }
        var caret = grouped.startIndex
        var seenDigits = 0
        while caret < grouped.endIndex, seenDigits < digitsBeforeCaret {
            if grouped[caret].isNumber { seenDigits += 1 }
            caret = grouped.index(after: caret)
        }
        let location = grouped.distance(from: grouped.startIndex, to: caret)
        editor.setSelectedRange(NSRange(location: location, length: 0))
    }

    public func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        field.layer?.borderColor = ViewerDesign.accent.cgColor
        guard field === codeField,
              let editor = window.fieldEditor(false, for: field) as? NSTextView else { return }
        // A refocused code field is typed into again, so a count-down left over
        // from before this focus should not still read as an error.
        codeErrorsRevealed = false
        refresh()
        // The one number a person reads aloud across a room. Tracking on an
        // editable field lives on the field editor's typing attributes; the
        // field's own font is the only part that survives without this.
        editor.typingAttributes[.kern] = ViewerDesign.kern(ViewerDesign.Tracking.widest, size: 20)
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        field.layer?.borderColor = ViewerDesign.line.cgColor
        guard field === codeField else { return }
        codeErrorsRevealed = true
        refresh()
    }

    private func refresh() {
        apply(state: form.addressState, to: addressHint, hint: Self.addressHintText)
        apply(
            state: form.codeState,
            to: codeHint,
            hint: Self.codeHintText,
            forceMuted: form.codeIsStillTyping && !codeErrorsRevealed
        )
        ViewerFormControls.style(
            pairButton,
            title: isPairing ? "Pairing\u{2026}" : "Pair",
            isPrimary: true,
            isEnabled: form.canSubmit && !isPairing
        )
        pairButton.keyEquivalent = "\r"
        resizeToFit()
    }

    /// One label per field, never an error line somewhere else: the message
    /// replaces the hint in place, so nothing on screen moves as it appears.
    /// `forceMuted` keeps the code field's count-down in its ordinary hint
    /// colour while it still reads as progress rather than a mistake.
    private func apply(
        state: ViewerPairingFieldState,
        to label: NSTextField,
        hint: String,
        forceMuted: Bool = false
    ) {
        label.stringValue = state.message ?? hint
        label.textColor = (state.message == nil || forceMuted)
            ? ViewerDesign.muted.nsColor
            : ViewerDesign.bad.nsColor
    }

    private func setFieldsEditable(_ editable: Bool) {
        for field in [addressField, codeField, nameField] {
            field.isEditable = editable
            field.textColor = editable
                ? ViewerDesign.ink.nsColor
                : ViewerDesign.muted.nsColor
        }
    }

    // MARK: - Pairing

    @objc private func submit() {
        guard case let .typeCode(device, _) = step else { return }
        guard !isPairing, let submission = form.submission, let pair else { return }
        isPairing = true
        codeErrorsRevealed = true
        setFieldsEditable(false)
        refresh()
        showMessage(
            headline: "Asking \(submission.displayName) to accept this machine\u{2026}",
            detail: "This takes a moment. Leave the code on \(submission.displayName)\u{2019}s screen "
                + "until this finishes.",
            tone: .info
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
                if copy.needsFreshCode {
                    // Retyping a spent code can only fail again, and a field
                    // still holding it invites exactly that.
                    self.codeField.stringValue = ""
                }
                self.form = ViewerPairingForm(
                    address: self.addressField.stringValue,
                    code: self.codeField.stringValue,
                    name: self.nameField.stringValue
                )
                self.refresh()
                self.showMessage(headline: copy.headline, detail: copy.detail, tone: .bad)
                self.window.makeFirstResponder(self.field(for: copy.focus))
            }
        }
    }

    private func field(for field: ViewerPairingField) -> NSTextField {
        switch field {
        case .address: return addressField
        case .code: return codeField
        case .name: return nameField
        }
    }

    // MARK: - Window

    /// There is no Quit button in this window, so the red one is how a person
    /// leaves from here. Refused rather than performed, so the viewer's own
    /// quit path is what actually ends the process.
    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        onCloseRequested?()
        return false
    }
}

/// One saved machine: its name, the single line under it, and the two things that
/// can be done to the row itself. Everything it says is `YourMachinesRow`'s
/// decision; this draws it.
@MainActor
final class SavedMachineRowButton: NSButton {
    let hostPublicKey: Data
    let cancelButton = NSButton()
    let moreButton = NSButton()
    var rowMenu: NSMenu?

    init(row: YourMachinesRow, isSelected: Bool) {
        hostPublicKey = row.hostPublicKey
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        // Left at the default, an `NSButton` draws its own stock "Button"
        // title underneath whatever is added as a subview.
        title = ""
        wantsLayer = true
        layer?.backgroundColor = ViewerDesign.chromeBg2.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = (isSelected ? ViewerDesign.accent : ViewerDesign.chromeBorder2).cgColor
        layer?.cornerRadius = ViewerDesign.Radius.base

        let name = NSTextField(labelWithString: row.name)
        name.font = ViewerDesign.font(mono: false, size: 14, weight: .medium)
        name.textColor = ViewerDesign.ink.nsColor
        name.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(labelWithString: row.detail)
        detail.font = ViewerDesign.font(mono: false, size: 12)
        detail.textColor = ViewerDesign.muted.nsColor
        detail.lineBreakMode = .byWordWrapping
        detail.maximumNumberOfLines = 0
        detail.translatesAutoresizingMaskIntoConstraints = false

        let detailRow: NSView
        if let kind = row.dot {
            let detailStack = NSStackView(views: [SavedMachineRowButton.dot(for: kind), detail])
            detailStack.orientation = .horizontal
            detailStack.alignment = .centerY
            detailStack.spacing = ViewerDesign.Space.xxs
            detailStack.translatesAutoresizingMaskIntoConstraints = false
            detailRow = detailStack
        } else {
            detailRow = detail
        }

        let text = NSStackView(views: [name, detailRow])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = ViewerDesign.Space.xxs
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(text)

        ViewerFormControls.style(cancelButton, title: "Cancel", isPrimary: false, isEnabled: true)
        cancelButton.isBordered = false
        cancelButton.wantsLayer = true
        cancelButton.layer?.cornerRadius = ViewerDesign.Radius.base
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.isHidden = !row.offersCancel
        addSubview(cancelButton)

        moreButton.isBordered = false
        moreButton.translatesAutoresizingMaskIntoConstraints = false
        moreButton.attributedTitle = NSAttributedString(
            string: "\u{2026}",
            attributes: [
                .font: ViewerDesign.font(mono: false, size: 16, weight: .medium),
                .foregroundColor: ViewerDesign.muted.nsColor
            ]
        )
        addSubview(moreButton)

        let inset = ViewerDesign.Space.md
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            text.topAnchor.constraint(equalTo: topAnchor, constant: ViewerDesign.Space.sm),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ViewerDesign.Space.sm),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cancelButton.leadingAnchor, constant: -ViewerDesign.Space.xs),

            cancelButton.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -ViewerDesign.Space.xs),
            cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            cancelButton.heightAnchor.constraint(equalToConstant: 24),
            cancelButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 64),

            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -ViewerDesign.Space.xs),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.widthAnchor.constraint(equalToConstant: 24),
            moreButton.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The dot beside a row's address. Online and offline hold still; only
    /// `.activity` pulses, standing in for the words a connecting or
    /// stopping row's detail line no longer carries alone. Held static
    /// under Reduce Motion, since a pulse conveys nothing a person who has
    /// asked for less motion needs the animation itself to receive.
    static func dot(for kind: YourMachinesRow.RowDot) -> NSView {
        let dot = NSView()
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        let color: ViewerColor
        switch kind {
        case .online: color = ViewerDesign.ok
        case .offline: color = ViewerDesign.bad
        case .activity: color = ViewerDesign.warn
        }
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6)
        ])
        if kind == .activity {
            ViewerPulse.apply(to: dot.layer)
        } else {
            ViewerPulse.remove(from: dot.layer)
        }
        return dot
    }

    /// The labels are non-interactive, but AppKit's default hit-testing finds
    /// them before this button's own mouse tracking, which would leave only the
    /// row's bare margin clickable. The two real controls on the row keep their
    /// own hits; everything else in the row's bounds is the row.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        for control in [cancelButton, moreButton] where !control.isHidden && control.frame.contains(local) {
            return control
        }
        return bounds.contains(local) ? self : nil
    }

    /// Right-clicking the row offers the same two actions its own "…" button
    /// does, since that is where a person looks for them first.
    override func menu(for event: NSEvent) -> NSMenu? {
        rowMenu
    }
}
#endif

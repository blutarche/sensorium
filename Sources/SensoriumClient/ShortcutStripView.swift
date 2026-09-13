#if canImport(AppKit)
import AppKit
import SensoriumCore

/// The row of system shortcuts that hangs from the top edge of a session
/// window: Mission Control, Spotlight, Switch App and the rest, for the machine
/// being worked on rather than this one. A small tab at the top centre is all
/// of it that shows until the tab is hovered or clicked.
///
/// Deliberately dumb, like the other chrome over the canvas. When it is on
/// screen and what a press does are `ShortcutStripModel`'s decisions, what each
/// press sends is `ShortcutStripAction`'s, and both are verified without a
/// window. This wires them to buttons and slides the bar.
@MainActor
public final class ShortcutStripView: NSView {
    /// The strip of window nothing of this view draws in or takes a click in.
    /// In full screen this is where the menu bar comes back when the pointer
    /// reaches the top of the screen, and anything put here could be aimed at
    /// only by summoning the menu bar over it.
    public static let topClearance: CGFloat = 6
    /// The bar itself: one row of icon-only buttons, grouped into a few small
    /// clusters, and the padding around it.
    public static let barHeight: CGFloat = 38
    /// Everything, which is the bar below the clearance above it.
    public static let height: CGFloat = topClearance + barHeight
    /// Small enough to be ignorable over a picture, large enough to aim at.
    public static let handleSize = NSSize(width: 36, height: 8)
    /// The height of one pill-shaped cluster background, and of every button
    /// inside it. `fileprivate` rather than `private`: `ShortcutStripIconButton`,
    /// declared lower in this same file, sizes itself from it too.
    fileprivate static let clusterHeight: CGFloat = 28

    private let bar = NSView()
    private let separator = NSView()
    private let hostNameLabel = NSTextField(labelWithString: "")
    private let clusterRow = NSStackView()
    private let confirmRow = NSStackView()
    private let question = NSTextField(labelWithString: "")
    private let confirmButton = ShortcutStripButton(title: "")
    private let cancelButton = ShortcutStripButton(title: "Cancel")
    private let handle = ShortcutStripHandle()
    private let pinButton: ShortcutStripIconButton
    private var barTop: NSLayoutConstraint!
    private var model: ShortcutStripModel
    private let hostName: String
    private let pinMemoryStore: any ShortcutStripPinMemoryStoring
    private var tickTask: Task<Void, Never>?
    /// What `tickTask` is already waiting for. A pointer moving over an open
    /// strip reports every motion, and each report ends in `apply()`; without
    /// this, each one would cancel and replace a task waiting for a deadline
    /// that had not moved.
    private var scheduledDeadline: TimeInterval?

    /// Where a press goes. The window controller hands the whole chord to the
    /// session's input path in one call.
    public var onSend: ((ShortcutStripAction) -> Void)?

    /// Fired whenever `pinnedBandHeight` changes, so the window controller can
    /// give the video and the session HUD back the top edge live, without a
    /// session restart. Not fired at construction time -- a caller that wants
    /// the state a restored pin already starts in reads `pinnedBandHeight`
    /// once, right after setting this.
    public var onPinnedBandHeightChanged: ((CGFloat) -> Void)?
    private var lastReportedPinnedBandHeight: CGFloat = 0

    public init(hostName: String, pinMemoryStore: (any ShortcutStripPinMemoryStoring)? = nil) {
        self.hostName = hostName
        let pinMemoryStore = pinMemoryStore ?? Self.defaultPinMemoryStore()
        self.pinMemoryStore = pinMemoryStore
        model = ShortcutStripModel(isPinned: pinMemoryStore.isPinned())
        pinButton = ShortcutStripIconButton(symbolName: "pin")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        // The bar starts above the top edge and slides down into view, so the
        // part of it that is still outside must not be drawn over the picture.
        layer?.masksToBounds = true

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.wantsLayer = true
        // Slightly translucent rather than solid: the picture underneath shows
        // faintly through the bar, the way Screen Sharing's own toolbar sits
        // over the screen it is showing. `NSVisualEffectView` would give a
        // true blur, but this system never uses one -- see `docs/design-system.md`'s
        // "no shadows" rule, which names it alongside `NSShadow`.
        bar.layer?.backgroundColor = ViewerDesign.chromeBg2.nsColor.withAlphaComponent(0.88).cgColor
        addSubview(bar)

        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.wantsLayer = true
        separator.layer?.backgroundColor = ViewerDesign.chromeBorder2.cgColor
        bar.addSubview(separator)

        hostNameLabel.translatesAutoresizingMaskIntoConstraints = false
        hostNameLabel.stringValue = hostName
        hostNameLabel.font = ViewerDesign.font(mono: false, size: 12)
        hostNameLabel.textColor = ViewerDesign.muted.nsColor
        hostNameLabel.lineBreakMode = .byTruncatingTail
        hostNameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        bar.addSubview(hostNameLabel)

        clusterRow.translatesAutoresizingMaskIntoConstraints = false
        clusterRow.orientation = .horizontal
        clusterRow.alignment = .centerY
        clusterRow.spacing = ViewerDesign.Space.sm
        // The clusters must fit inside the bar rather than push it wider: a
        // window narrower than their natural width is exactly when this
        // matters, and letting them win would drag the centred handle off
        // with them.
        clusterRow.setClippingResistancePriority(.defaultLow, for: .horizontal)
        for cluster in Self.actionClusters {
            let buttons = cluster.map { action -> ShortcutStripIconButton in
                let button = ShortcutStripIconButton(symbolName: action.symbolName)
                button.toolTip = action.tooltip(hostName: hostName)
                button.onPress = { [weak self] in self?.press(action) }
                return button
            }
            clusterRow.addArrangedSubview(Self.makeCluster(buttons))
        }
        bar.addSubview(clusterRow)

        pinButton.onPress = { [weak self] in self?.togglePin() }
        let pinCluster = Self.makeCluster([pinButton])
        bar.addSubview(pinCluster)
        updatePinAppearance()

        question.translatesAutoresizingMaskIntoConstraints = false
        question.font = ViewerDesign.font(mono: false, size: 12)
        question.textColor = ViewerDesign.ink.nsColor
        confirmButton.onPress = { [weak self] in self?.confirmPending() }
        cancelButton.onPress = { [weak self] in self?.cancelPending() }
        confirmRow.translatesAutoresizingMaskIntoConstraints = false
        confirmRow.orientation = .horizontal
        confirmRow.alignment = .centerY
        confirmRow.spacing = ViewerDesign.Space.xs
        confirmRow.setViews([question, confirmButton, cancelButton], in: .leading)
        confirmRow.isHidden = true
        bar.addSubview(confirmRow)

        // Added last, so it stays visible over the bar it summoned: the click
        // that opens the strip is also the click that closes it.
        handle.toolTip = "Shortcuts for \(hostName)"
        handle.onPress = { [weak self] in self?.handleClicked() }
        addSubview(handle)

        barTop = bar.topAnchor.constraint(equalTo: topAnchor, constant: -Self.barHeight)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            barTop,
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: Self.barHeight),

            separator.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            hostNameLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: ViewerDesign.Space.sm),
            hostNameLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            // Centred as a group of clusters rather than pinned to the bar's
            // leading edge: the handle above it is centred too, and a strip
            // that reads as one balanced shape looks intentional in a way a
            // left-aligned shelf of buttons does not.
            clusterRow.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            clusterRow.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            clusterRow.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: ViewerDesign.Space.xs),
            clusterRow.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -ViewerDesign.Space.xs),

            pinCluster.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -ViewerDesign.Space.sm),
            pinCluster.centerYAnchor.constraint(equalTo: bar.centerYAnchor),

            confirmRow.centerXAnchor.constraint(equalTo: bar.centerXAnchor),
            confirmRow.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            confirmRow.leadingAnchor.constraint(greaterThanOrEqualTo: bar.leadingAnchor, constant: ViewerDesign.Space.xs),

            handle.centerXAnchor.constraint(equalTo: centerXAnchor),
            handle.topAnchor.constraint(equalTo: topAnchor, constant: Self.topClearance),
            handle.widthAnchor.constraint(equalToConstant: Self.handleSize.width),
            handle.heightAnchor.constraint(equalToConstant: Self.handleSize.height)
        ])
        apply(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Nothing under a strip that is not on screen: a closed bar must never
    /// take a click meant for the machine being worked on. The handle is the
    /// one exception, and only while there is a live session behind it. The
    /// clearance at the top is nobody's: a click there is the picture's,
    /// whether the strip is open or closed.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard distanceFromTop(of: local) >= Self.topClearance else { return nil }
        if model.showsHandle, handle.frame.contains(local) {
            return handle
        }
        guard isBarOnScreen else { return nil }
        return super.hitTest(point)
    }

    /// A click that reached this view rather than one of its buttons landed on
    /// the bar itself, and it stops here: without these it would walk the
    /// responder chain to the canvas and out to the machine being worked on.
    public override func mouseDown(with event: NSEvent) {}

    public override func mouseUp(with event: NSEvent) {}

    public override func rightMouseDown(with event: NSEvent) {}

    public override func rightMouseUp(with event: NSEvent) {}

    public override func otherMouseDown(with event: NSEvent) {}

    public override func otherMouseUp(with event: NSEvent) {}

    public func phaseChanged(_ phase: ViewerSessionPhase) {
        model.phaseChanged(phase, now: Self.now())
        apply()
    }

    /// The pointer left the canvas altogether, or the window stopped being the
    /// key one. Neither produces the motion the strip is otherwise driven by,
    /// so without this a strip left open would stay open (unless pinned, which
    /// keeps it open regardless of this too).
    public func pointerLeftWindow() {
        pointerMoved(to: nil)
    }

    /// Where the pointer is, in the coordinates of the view this strip sits in.
    /// `nil` means it is not in that view at all. Which parts of the strip that
    /// lands on is this view's own business, since it is the only thing that
    /// knows where they were laid out.
    public func pointerMoved(to pointInSuperview: NSPoint?) {
        let now = Self.now()
        let point = pointInSuperview.map { convert($0, from: superview) }
        let overHandle = model.showsHandle && point.map { handle.frame.contains($0) } == true
        let overStrip = isBarOnScreen && point.map { bar.frame.contains($0) } == true
        model.pointerOverHandle(overHandle, now: now)
        model.pointerOverStrip(overStrip, now: now)
        apply()
    }

    public func toggleRequested() {
        model.toggleRequested()
        apply()
    }

    /// True when Escape closed the strip, and the caller should not pass that
    /// keystroke on to the machine being worked on.
    @discardableResult
    public func escapePressed() -> Bool {
        let closed = model.escapePressed()
        apply()
        return closed
    }

    /// What a button does, and the only way one is pressed.
    public func press(_ action: ShortcutStripAction) {
        guard let press = model.press(action) else { return }
        switch press {
        case let .send(action):
            onSend?(action)
        case .askToConfirm:
            break
        }
        apply()
    }

    /// True while something of this strip is under the pointer, which is what
    /// keeps the far machine's own pointer from following a hand aiming at the
    /// handle or at a button up here.
    public func coversPointInSuperview(_ point: NSPoint) -> Bool {
        let local = convert(point, from: superview)
        guard distanceFromTop(of: local) >= Self.topClearance else { return false }
        if model.showsHandle, handle.frame.contains(local) {
            return true
        }
        return isBarOnScreen && bar.frame.contains(local)
    }

    private func handleClicked() {
        model.handleClicked()
        apply()
    }

    private func confirmPending() {
        guard let action = model.confirmPending() else { return }
        onSend?(action)
        apply()
    }

    private func cancelPending() {
        model.cancelPending()
        apply()
    }

    /// The pin button itself: keeping the strip open needs no pointer, which
    /// is exactly the case a hover-driven hide cannot express, so this talks
    /// to the model directly rather than through `press(_:)`, which is only
    /// for chords sent to the machine being worked on.
    private func togglePin() {
        model.togglePinRequested(now: Self.now())
        pinMemoryStore.remember(isPinned: model.isPinned)
        updatePinAppearance()
        apply()
    }

    private func updatePinAppearance() {
        pinButton.setSymbol(model.isPinned ? "pin.fill" : "pin")
        pinButton.toolTip = model.isPinned ? "Let close" : "Keep open"
    }

    private var isBarOnScreen: Bool {
        switch model.visibility {
        case .shown, .hiding, .confirming: true
        case .hidden: false
        }
    }

    /// How much of the top edge this strip is claiming right now: its own
    /// full height while pinned open, zero the moment it is not -- an
    /// unpinned strip revealed by a hover still overlays the picture, the way
    /// it always has. See `ShortcutStripLayoutPolicy`, which this only feeds.
    public var pinnedBandHeight: CGFloat {
        let isStripOpen: Bool
        switch model.visibility {
        case .shown, .confirming: isStripOpen = true
        case .hidden, .hiding: isStripOpen = false
        }
        return ShortcutStripLayoutPolicy.videoTopInset(
            isPinned: model.isPinned,
            isStripOpen: isStripOpen,
            stripHeight: Self.height
        )
    }

    private func apply(animated: Bool = true) {
        handle.isHidden = !model.showsHandle
        if case let .confirming(action) = model.visibility, let confirmation = action.confirmation(hostName: hostName) {
            question.stringValue = confirmation.question
            confirmButton.setLabel(confirmation.confirmTitle)
            cancelButton.setLabel(confirmation.cancelTitle)
            confirmRow.isHidden = false
            clusterRow.isHidden = true
        } else {
            confirmRow.isHidden = true
            clusterRow.isHidden = false
        }
        let target: CGFloat = isBarOnScreen ? Self.topClearance : -Self.barHeight
        if barTop.constant != target {
            // Animated only in a real window: offscreen rendering has no run
            // loop to finish an animation, and a bar caught halfway is not the
            // state anybody asked to look at.
            if animated, window != nil {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    barTop.animator().constant = target
                }
            } else {
                barTop.constant = target
            }
        }
        scheduleTick()

        let band = pinnedBandHeight
        if band != lastReportedPinnedBandHeight {
            lastReportedPinnedBandHeight = band
            onPinnedBandHeightChanged?(band)
        }
    }

    /// One wake-up at the moment the model's own delay expires, rather than a
    /// timer running over a live video window for the life of the session.
    private func scheduleTick() {
        guard model.nextDeadline != scheduledDeadline else { return }
        scheduledDeadline = model.nextDeadline
        tickTask?.cancel()
        guard let deadline = model.nextDeadline else {
            tickTask = nil
            return
        }
        let delay = max(0, deadline - Self.now())
        tickTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.model.tick(now: Self.now())
            self.apply()
        }
    }

    private func distanceFromTop(of point: NSPoint) -> CGFloat {
        isFlipped ? point.y : bounds.maxY - point.y
    }

    private static func now() -> TimeInterval {
        Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000
    }

    /// The four clusters of action buttons, grouped by what a person is doing
    /// with them rather than by chord: window management, moving between
    /// desktops, launching or finding something, and the two disruptive
    /// actions. The pin sits apart from these, in its own cluster at the far
    /// trailing edge, the way Screen Sharing's own toolbar keeps one cluster
    /// away from the rest of the group it centres.
    private static let actionClusters: [[ShortcutStripAction]] = [
        [.missionControl, .applicationWindows, .showDesktop],
        [.desktopLeft, .desktopRight],
        [.spotlight, .launchpad, .switchApp],
        [.lockScreen, .quitApp]
    ]

    /// One pill-shaped, darker sub-background holding a small group of
    /// buttons -- the shape Screen Sharing's own toolbar groups its controls
    /// into. Rounder than anything else this design system draws: see the
    /// comment on `bar`'s own background for why a pill is the one deliberate
    /// exception to "nothing in this system is rounder than 6," made here to
    /// match a named, specific reference rather than to round shapes generally.
    private static func makeCluster(_ buttons: [NSView]) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = clusterHeight / 2
        pill.layer?.backgroundColor = ViewerDesign.chromeBg.nsColor.withAlphaComponent(0.55).cgColor
        let row = NSStackView(views: buttons)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 2
        pill.addSubview(row)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: clusterHeight),
            row.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: ViewerDesign.Space.xxs),
            row.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -ViewerDesign.Space.xxs),
            row.topAnchor.constraint(equalTo: pill.topAnchor),
            row.bottomAnchor.constraint(equalTo: pill.bottomAnchor)
        ])
        return pill
    }

    /// Next to `savedHostURL()` in the same "Sensorium" Application Support
    /// directory every other per-viewer file already lives in. Owner-only,
    /// like `FileHostScreenModeMemoryStore`'s own file, for the same reason:
    /// nothing about this viewer's own settings should be readable by another
    /// account on the same Mac, even though a pin is not a secret.
    private static func defaultPinMemoryStore() -> any ShortcutStripPinMemoryStoring {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base
            .appendingPathComponent("Sensorium", isDirectory: true)
            .appendingPathComponent("shortcut-strip-pin.json")
        return FileShortcutStripPinMemoryStore(url: url)
    }
}

/// The tab that makes the strip findable: translucent, low contrast, and no
/// bigger than it has to be, because it is the one piece of viewer chrome that
/// is on screen for the whole of a live session. Never focusable, and it never
/// makes itself first responder on a click: the keyboard belongs to the canvas.
@MainActor
private final class ShortcutStripHandle: NSView {
    var onPress: (() -> Void)?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = ShortcutStripView.handleSize.height / 2
        layer?.backgroundColor = ViewerDesign.ink.nsColor.withAlphaComponent(0.3).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ViewerDesign.chromeBg.nsColor.withAlphaComponent(0.35).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var acceptsFirstResponder: Bool { false }

    /// The window this sits in is usually already key, but a click on the
    /// handle must work on the first one either way, without the window's
    /// canvas taking that click as well.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    /// The other half of that click, and the buttons the handle does nothing
    /// with, are consumed rather than passed on: every one of them would
    /// otherwise walk the responder chain out to the machine being worked on.
    override func mouseUp(with event: NSEvent) {}

    override func rightMouseDown(with event: NSEvent) {}

    override func rightMouseUp(with event: NSEvent) {}

    override func otherMouseDown(with event: NSEvent) {}

    override func otherMouseUp(with event: NSEvent) {}
}

/// One button on the strip. Never focusable: the keyboard belongs to the canvas
/// for the whole life of the session, and a Tab that landed up here would be a
/// keystroke the machine being worked on never received.
@MainActor
private final class ShortcutStripButton: NSButton {
    var onPress: (() -> Void)?

    init(title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = ViewerDesign.Radius.base
        layer?.backgroundColor = ViewerDesign.bg4.cgColor
        target = self
        action = #selector(fire)
        setLabel(title)
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func setLabel(_ text: String) {
        attributedTitle = NSAttributedString(
            string: text,
            attributes: [
                .font: ViewerDesign.font(mono: false, size: 12),
                .foregroundColor: ViewerDesign.ink.nsColor
            ]
        )
        invalidateIntrinsicContentSize()
    }

    /// The horizontal padding a flat button has no bezel to give it.
    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(attributedTitle.size().width) + ViewerDesign.Space.sm * 2, height: 24)
    }

    override var acceptsFirstResponder: Bool { false }

    @objc private func fire() {
        onPress?()
    }
}

/// One icon-only button inside a cluster: a glyph and nothing else, the way
/// Screen Sharing's own toolbar draws a control, with what it does and which
/// machine it sends to left entirely to the tooltip. Never focusable, for the
/// reason every other control on the strip is not -- the keyboard belongs to
/// the canvas for the life of the session.
@MainActor
private final class ShortcutStripIconButton: NSButton {
    static let size: CGFloat = ShortcutStripView.clusterHeight
    private static let iconPointSize: CGFloat = 18

    var onPress: (() -> Void)?

    private let icon = NSImageView()
    private var trackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet { updateBackground() }
    }

    init(symbolName: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .none
        refusesFirstResponder = true
        wantsLayer = true
        layer?.cornerRadius = ViewerDesign.Radius.base
        target = self
        action = #selector(fire)
        // NSButton draws its own placeholder title ("Button") whenever none
        // has been set. This button draws only the icon subview below, so
        // the button's own title must be silenced or it shows through
        // underneath that subview.
        self.title = ""
        imagePosition = .noImage

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = ViewerDesign.ink.nsColor
        addSubview(icon)
        setSymbol(symbolName)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size),
            heightAnchor.constraint(equalToConstant: Self.size),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: Self.iconPointSize),
            icon.heightAnchor.constraint(equalToConstant: Self.iconPointSize)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Swapped when the pin button's own state changes; every other button's
    /// symbol is fixed for its whole life.
    func setSymbol(_ symbolName: String) {
        let configuration = NSImage.SymbolConfiguration(pointSize: Self.iconPointSize, weight: .medium)
        icon.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
    }

    override var acceptsFirstResponder: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    /// Pressed feedback for the length of the click, not just the hover under
    /// it: `super.mouseDown` runs its own tracking loop and does not return
    /// until the button is released.
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = ViewerDesign.ink.nsColor.withAlphaComponent(0.18).cgColor
        super.mouseDown(with: event)
        updateBackground()
    }

    private func updateBackground() {
        layer?.backgroundColor = isHovering
            ? ViewerDesign.ink.nsColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }

    @objc private func fire() {
        onPress?()
    }
}
#endif

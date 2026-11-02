import AppKit
import SensoriumCore
import Foundation

/// What the empty Paired machines section tells the person to do. It depends
/// on what the window offers beside it: a code already on screen carries its
/// own instruction, so this line says what follows it, and a host that cannot
/// offer a code yet has nothing to show. While a pairing finishes, the status
/// card already says what is happening, so the section says nothing, its
/// heading included.
package enum PairedMachinesEmptyState {
    case codeShowing
    case canShowCode
    case cannotPairYet
    case pairingFinishing

    package var subtext: String {
        switch self {
        case .codeShowing:
            return "The machine appears here once the code is typed on it."
        case .canShowCode:
            return "Show a pairing code, then type it on the machine you are pairing."
        case .cannotPairYet:
            return "Machines appear here once they pair."
        case .pairingFinishing:
            return ""
        }
    }

    package var showsLines: Bool {
        self != .pairingFinishing
    }
}

/// One short row per machine that has ever paired, all in one card: its
/// name, its Share host screen switch, and a menu holding its rarer actions.
/// Visible in every state the surrounding
/// `HostSetupWindowController` can be in, not only while a session is live
/// -- someone who paired a machine months ago must see it without hunting.
@MainActor
final class PairedMachinesView: NSView {
    private let eyebrow = NSTextField(labelWithAttributedString: CanvasDesign.eyebrow("Paired machines"))
    /// The two-line empty state: what is empty, then what to do about it.
    private let emptyHeading = PairedMachinesView.label("No machine is paired.")
    private let emptySubtext = PairedMachinesView.label(
        HostTextFlow.flow(PairedMachinesEmptyState.canShowCode.subtext),
        color: CanvasDesign.muted
    )
    private let lastSessionCard = NSView()
    private let lastSessionEyebrow = NSTextField(labelWithAttributedString: CanvasDesign.eyebrow("Last host screen session"))
    private let lastSessionLabel = PairedMachinesView.label("", color: CanvasDesign.muted)
    private let lastSessionStack = NSStackView()
    private let stack = NSStackView()
    /// The one card every machine's row sits in, edge to edge.
    private let rowsStack = NSStackView()
    private var rowViews: [PairedMachineRowView] = []
    private var emptyState = PairedMachinesEmptyState.canShowCode
    private var pairedNames: [String] = []
    private var lastSessionLine: String?

    /// The width this section is laid out at. A machine name is held whole on
    /// the last-session line only when it fits that line; `0` means unknown,
    /// and a name is then always held whole.
    var columnWidth: CGFloat = 0 {
        didSet { showLastSession() }
    }

    var onToggleSharing: ((Data, Bool) -> Void)?
    var onRemovePairedDevice: ((Data) -> Void)?
    var onToggleAskFirst: ((Data, Bool) -> Void)?
    /// The row's machine and the name it shows now.
    var onRenamePairedDevice: ((Data, String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CanvasDesign.Space.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        rowsStack.orientation = .vertical
        rowsStack.alignment = .leading
        rowsStack.spacing = 0
        rowsStack.translatesAutoresizingMaskIntoConstraints = false
        rowsStack.applyDesignSurface(fill: CanvasDesign.bg2, radius: CanvasDesign.Radius.base)

        // Same card treatment as the paired machines' own card.
        lastSessionCard.applyDesignSurface(fill: CanvasDesign.bg2, radius: CanvasDesign.Radius.base)
        lastSessionCard.translatesAutoresizingMaskIntoConstraints = false

        lastSessionStack.orientation = .vertical
        lastSessionStack.alignment = .leading
        lastSessionStack.spacing = CanvasDesign.Space.xxs
        lastSessionStack.translatesAutoresizingMaskIntoConstraints = false
        lastSessionCard.addSubview(lastSessionStack)
        lastSessionStack.addArrangedSubview(lastSessionLabel)
        lastSessionLabel.widthAnchor.constraint(lessThanOrEqualTo: lastSessionStack.widthAnchor).isActive = true
        let lastSessionInset = CanvasDesign.Space.md
        NSLayoutConstraint.activate([
            lastSessionStack.leadingAnchor.constraint(equalTo: lastSessionCard.leadingAnchor, constant: lastSessionInset),
            lastSessionStack.trailingAnchor.constraint(lessThanOrEqualTo: lastSessionCard.trailingAnchor, constant: -lastSessionInset),
            lastSessionStack.topAnchor.constraint(equalTo: lastSessionCard.topAnchor, constant: lastSessionInset),
            lastSessionStack.bottomAnchor.constraint(equalTo: lastSessionCard.bottomAnchor, constant: -lastSessionInset)
        ])

        emptyHeading.font = CanvasDesign.font(.primary, size: 13, weight: .medium)
        for view in [eyebrow, emptyHeading, emptySubtext, rowsStack, lastSessionEyebrow, lastSessionCard] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        rowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        lastSessionCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(CanvasDesign.Space.xs, after: eyebrow)
        stack.setCustomSpacing(CanvasDesign.Space.xxs, after: emptyHeading)
        stack.setCustomSpacing(CanvasDesign.Space.lg, after: emptySubtext)
        stack.setCustomSpacing(CanvasDesign.Space.lg, after: rowsStack)
        stack.setCustomSpacing(CanvasDesign.Space.xs, after: lastSessionEyebrow)

        lastSessionEyebrow.isHidden = true
        lastSessionCard.isHidden = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Rebuilds one row per entry, in the order given.
    func update(rows: [HostScreenArmingPresentation.PairedMachineRow]) {
        for row in rowViews {
            rowsStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        rowViews = rows.enumerated().map { index, row in
            let rowView = PairedMachineRowView(row: row, isFirst: index == 0)
            rowView.onToggle = { [weak self] isOn in self?.onToggleSharing?(row.devicePublicKey, isOn) }
            rowView.onRemove = { [weak self] in self?.onRemovePairedDevice?(row.devicePublicKey) }
            // The placeholder title is not a name to start from.
            let currentName = row.deviceName == HostScreenArmingPresentation.unnamedMachineTitle ? "" : row.deviceName
            rowView.onRename = { [weak self] in self?.onRenamePairedDevice?(row.devicePublicKey, currentName) }
            rowView.onToggleAskFirst = { [weak self] isOn in self?.onToggleAskFirst?(row.devicePublicKey, isOn) }
            return rowView
        }
        for rowView in rowViews {
            rowsStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        rowsStack.isHidden = rows.isEmpty
        showEmptyState()
        pairedNames = rows.map(\.deviceName)
        showLastSession()
    }

    /// The frame of each thing this section draws as a row -- the heading,
    /// every machine, the last-session card -- in `space`'s coordinates, so
    /// something laid over the window can end between them.
    func rowFrames(in space: NSView) -> [NSRect] {
        space.layoutSubtreeIfNeeded()
        var rows: [NSView] = []
        for view in stack.arrangedSubviews where !view.isHidden {
            if view === rowsStack {
                rows += rowViews.filter { !$0.isHidden }
            } else {
                rows.append(view)
            }
        }
        return rows.map { space.convert($0.bounds, from: $0) }
    }

    func setEmptyState(_ state: PairedMachinesEmptyState) {
        emptyState = state
        emptySubtext.stringValue = HostTextFlow.flow(state.subtext)
        showEmptyState()
    }

    private func showEmptyState() {
        let shown = rowViews.isEmpty && emptyState.showsLines
        emptyHeading.isHidden = !shown
        emptySubtext.isHidden = !shown
        eyebrow.isHidden = rowViews.isEmpty && !emptyState.showsLines
        hideWhenNothingShows()
    }

    /// A section with nothing to show takes no room, so the window's gap
    /// around it is not paid twice.
    private func hideWhenNothingShows() {
        isHidden = stack.arrangedSubviews.allSatisfy(\.isHidden)
    }

    /// `nil` when host screen has never run on this machine.
    func updateLastSession(_ line: String?) {
        lastSessionLine = line
        showLastSession()
    }

    /// The last-session line with its break points tidied: a machine name
    /// that fits the card stays whole, the date never splits.
    private func showLastSession() {
        let measure = columnWidth > 0
            ? HostTextFlow.Measure(
                attributes: [.font: CanvasDesign.font(.primary, size: 13)],
                width: columnWidth - CanvasDesign.Space.md * 2
            )
            : nil
        lastSessionLabel.stringValue = lastSessionLine.map {
            HostTextFlow.flow($0, names: pairedNames, measure: measure)
        } ?? ""
        lastSessionEyebrow.isHidden = lastSessionLine == nil
        lastSessionCard.isHidden = lastSessionLine == nil
        hideWhenNothingShows()
    }

    fileprivate static func label(_ text: String = "", color: DesignColor = CanvasDesign.ink) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = CanvasDesign.font(.primary, size: 13)
        label.textColor = color.nsColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        return label
    }
}

/// A pill-shaped on/off control drawn with this app's own design tokens,
/// rather than `NSSwitch`'s system-drawn track: that track's on-colour
/// follows `NSColor.controlAccentColor`, which a person can set to
/// Graphite, at which point on and off render as the same grey and the
/// control stops reading as a toggle at all.
@MainActor
final class HostScreenSharingToggleControl: NSControl {
    static let size = NSSize(width: 38, height: 22)
    private static let inset: CGFloat = 2

    private let trackLayer = CALayer()
    private let knobLayer = CALayer()

    var isOn: Bool {
        didSet {
            guard isOn != oldValue else { return }
            layoutTrack()
        }
    }

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        trackLayer.addSublayer(knobLayer)
        trackLayer.frame = bounds
        trackLayer.cornerRadius = Self.size.height / 2
        knobLayer.backgroundColor = NSColor.white.cgColor
        knobLayer.cornerRadius = (Self.size.height - Self.inset * 2) / 2
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height)
        ])
        layoutTrack()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    override func accessibilityValue() -> Any? { isOn ? 1 : 0 }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        isOn.toggle()
        sendAction(action, to: target)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isOn.toggle()
        sendAction(action, to: target)
    }

    private func layoutTrack() {
        trackLayer.setAppearanceColor((isOn ? CanvasDesign.accent : CanvasDesign.bg4).nsColor, for: "backgroundColor")
        let knobDiameter = Self.size.height - Self.inset * 2
        let knobX = isOn ? Self.size.width - Self.inset - knobDiameter : Self.inset
        knobLayer.frame = NSRect(x: knobX, y: Self.inset, width: knobDiameter, height: knobDiameter)
    }
}

/// One machine's own row, one short line in the shared card: its name over
/// a muted line saying what it may share, then its Share host screen switch
/// and a "more" button. The button's menu holds the actions a person needs
/// rarely: Rename, ask first, the key fingerprint, and Remove. The row's
/// height is fixed, so ten machines take ten short lines whatever their
/// names: text that does not fit truncates rather than wrapping.
@MainActor
private final class PairedMachineRowView: NSView {
    static let height: CGFloat = 48
    private static let sharingOffLine = "Host screen sharing off"

    /// The hairline above every row but the first, starting at the text's
    /// inset, as in a settings list.
    private let separator = NSView()
    private let nameLabel = PairedMachineRowView.singleLineLabel(size: 13, color: CanvasDesign.ink)
    private let subtitleLabel = PairedMachineRowView.singleLineLabel(size: 12, color: CanvasDesign.muted)
    /// The name over the subtitle.
    private let stack = NSStackView()
    private let toggle: HostScreenSharingToggleControl
    private let moreButton = PairedMachineMoreButton()
    private let actionsMenu = NSMenu()
    private let asksWhenInUse: Bool

    var onToggle: ((Bool) -> Void)?
    var onRemove: (() -> Void)?
    var onRename: (() -> Void)?
    var onToggleAskFirst: ((Bool) -> Void)?

    init(row: HostScreenArmingPresentation.PairedMachineRow, isFirst: Bool) {
        toggle = HostScreenSharingToggleControl(isOn: row.isSharingRealScreen)
        asksWhenInUse = row.asksWhenInUse
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        separator.applyDesignSurface(fill: CanvasDesign.line2, radius: CanvasDesign.Radius.none)
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.isHidden = isFirst

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        for label in [nameLabel, subtitleLabel] {
            stack.addArrangedSubview(label)
            label.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }

        toggle.target = self
        toggle.setAccessibilityLabel("Share host screen with \(row.deviceName)")
        toggle.action = #selector(toggled)
        moreButton.target = self
        moreButton.action = #selector(moreTapped)
        moreButton.setAccessibilityLabel("More actions for \(row.deviceName)")

        for view: NSView in [separator, stack, toggle, moreButton] {
            addSubview(view)
        }
        let inset = CanvasDesign.Space.md
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: toggle.leadingAnchor, constant: -CanvasDesign.Space.sm),
            toggle.centerYAnchor.constraint(equalTo: centerYAnchor),
            toggle.trailingAnchor.constraint(equalTo: moreButton.leadingAnchor, constant: -CanvasDesign.Space.xs),
            moreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            moreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -CanvasDesign.Space.xs)
        ])

        nameLabel.stringValue = row.deviceName
        let subtitle = Self.subtitle(for: row)
        subtitleLabel.stringValue = subtitle ?? ""
        subtitleLabel.isHidden = subtitle == nil
        buildActionsMenu(for: row)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Rename, ask first, the key line when there is one, then Remove apart
    /// from the rest. Ask first only means anything for a machine allowed to
    /// share, so it is offered only then.
    private func buildActionsMenu(for row: HostScreenArmingPresentation.PairedMachineRow) {
        actionsMenu.autoenablesItems = false
        let rename = NSMenuItem(title: "Rename\u{2026}", action: #selector(renameTapped), keyEquivalent: "")
        rename.target = self
        actionsMenu.addItem(rename)

        let askFirst = NSMenuItem(
            title: HostScreenArmingPresentation.asksWhenInUseLabel, action: #selector(askFirstToggled), keyEquivalent: ""
        )
        askFirst.target = self
        askFirst.state = row.asksWhenInUse ? .on : .off
        askFirst.isEnabled = row.isSharingRealScreen
        actionsMenu.addItem(askFirst)

        if let keyFingerprintLine = row.keyFingerprintLine {
            let key = NSMenuItem(title: keyFingerprintLine, action: nil, keyEquivalent: "")
            key.isEnabled = false
            actionsMenu.addItem(key)
        }

        actionsMenu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove", action: #selector(removeTapped), keyEquivalent: "")
        remove.target = self
        remove.attributedTitle = NSAttributedString(
            string: remove.title,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: CanvasDesign.bad.nsColor]
        )
        actionsMenu.addItem(remove)
    }

    /// What this machine may share, or why it shares nothing.
    private static func subtitle(for row: HostScreenArmingPresentation.PairedMachineRow) -> String? {
        guard row.isSharingRealScreen else { return sharingOffLine }
        if let sharedDisplaysLine = row.sharedDisplaysLine {
            return withoutClosingFullStop(sharedDisplaysLine)
        }
        return row.notOfferedReason
    }

    /// `sharedDisplaysLine` without its trailing period: a status line under
    /// a name, not a sentence of its own.
    private static func withoutClosingFullStop(_ sharedDisplaysLine: String) -> String {
        sharedDisplaysLine.hasSuffix(".") ? String(sharedDisplaysLine.dropLast()) : sharedDisplaysLine
    }

    private static func singleLineLabel(size: CGFloat, color: DesignColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = CanvasDesign.font(.primary, size: size)
        label.textColor = color.nsColor
        label.usesSingleLineMode = true
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    @objc private func toggled() {
        onToggle?(toggle.isOn)
    }

    @objc private func moreTapped() {
        let below = moreButton.isFlipped
            ? moreButton.bounds.maxY + CanvasDesign.Space.xxs
            : moreButton.bounds.minY - CanvasDesign.Space.xxs
        actionsMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: below), in: moreButton)
    }

    @objc private func askFirstToggled() {
        onToggleAskFirst?(!asksWhenInUse)
    }

    @objc private func removeTapped() {
        onRemove?()
    }

    @objc private func renameTapped() {
        onRename?()
    }
}

/// A row's flat "more" button: three dots in muted ink, no border and no
/// fill, drawn here rather than taken from a symbol image.
@MainActor
private final class PairedMachineMoreButton: NSButton {
    static let size = NSSize(width: 24, height: 24)
    private static let dotDiameter: CGFloat = 3
    private static let dotGap: CGFloat = 3

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        title = ""
        isBordered = false
        imagePosition = .noImage
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.size.width),
            heightAnchor.constraint(equalToConstant: Self.size.height)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func draw(_ dirtyRect: NSRect) {
        let span = Self.dotDiameter * 3 + Self.dotGap * 2
        let y = (bounds.height - Self.dotDiameter) / 2
        CanvasDesign.muted.nsColor.setFill()
        for index in 0..<3 {
            let x = (bounds.width - span) / 2 + CGFloat(index) * (Self.dotDiameter + Self.dotGap)
            NSBezierPath(ovalIn: NSRect(x: x, y: y, width: Self.dotDiameter, height: Self.dotDiameter)).fill()
        }
    }
}

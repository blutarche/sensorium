import AppKit
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

/// One row per machine that has ever paired, each with its own Rename,
/// Remove and Share host screen controls. Visible in every state the surrounding
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
    private let lastSessionEyebrow = NSTextField(labelWithAttributedString: CanvasDesign.eyebrow("Last Host Screen Session"))
    private let lastSessionLabel = PairedMachinesView.label("", color: CanvasDesign.muted)
    private let lastSessionStack = NSStackView()
    private let stack = NSStackView()
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
        rowsStack.spacing = CanvasDesign.Space.sm
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        // Same card treatment as a paired machine's own row.
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
        rowViews = rows.map { row in
            let rowView = PairedMachineRowView(row: row)
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

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isOn.toggle()
        sendAction(action, to: target)
    }

    private func layoutTrack() {
        trackLayer.backgroundColor = (isOn ? CanvasDesign.accent : CanvasDesign.bg4).cgColor
        let knobDiameter = Self.size.height - Self.inset * 2
        let knobX = isOn ? Self.size.width - Self.inset - knobDiameter : Self.inset
        knobLayer.frame = NSRect(x: knobX, y: Self.inset, width: knobDiameter, height: knobDiameter)
    }
}

/// One machine's own row, four lines at most: its name beside Rename and Remove, the
/// Share host screen toggle, the ask-first checkbox while it is sharing, and
/// one wrapping line combining its key fingerprint, which display it may
/// share, and why sharing is or is not available -- everything this row
/// used to spread across as many separate paragraphs, said once.
@MainActor
private final class PairedMachineRowView: NSView {
    private let nameLabel = PairedMachinesView.label()
    private let toggle: HostScreenSharingToggleControl
    private let toggleLabel = PairedMachinesView.label("Share host screen")
    /// Visible only while this row is sharing -- the setting only means
    /// anything for a machine whose session could prompt at all.
    private let askFirstCheckbox = NSButton(
        checkboxWithTitle: HostScreenArmingPresentation.asksWhenInUseLabel, target: nil, action: nil
    )
    private let metaLabel = PairedMachinesView.label("", color: CanvasDesign.muted)
    private let renameButton = NSButton()
    private let removeButton = NSButton()
    private let stack = NSStackView()

    var onToggle: ((Bool) -> Void)?
    var onRemove: (() -> Void)?
    var onRename: (() -> Void)?
    var onToggleAskFirst: ((Bool) -> Void)?

    init(row: HostScreenArmingPresentation.PairedMachineRow) {
        toggle = HostScreenSharingToggleControl(isOn: row.isSharingRealScreen)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = CanvasDesign.bg2.cgColor
        layer?.cornerRadius = CanvasDesign.Radius.base

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CanvasDesign.Space.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        toggle.target = self
        toggle.action = #selector(toggled)
        let toggleRow = NSStackView(views: [toggle, toggleLabel])
        toggleRow.orientation = .horizontal
        toggleRow.alignment = .centerY
        toggleRow.spacing = CanvasDesign.Space.sm

        Self.styleRowButton(removeButton, title: "Remove", color: CanvasDesign.bad)
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        Self.styleRowButton(renameButton, title: "Rename", color: CanvasDesign.ink)
        renameButton.target = self
        renameButton.action = #selector(renameTapped)

        // The name, Rename and Remove share one line -- Remove pinned to the
        // row's trailing edge with Rename just before it, the name taking
        // whatever is left and wrapping before it ever runs under a button.
        // The name is centred on the buttons; the row is as tall as the
        // taller of the two, held to it by the weaker equalities below.
        let nameRow = NSView()
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameRow.addSubview(nameLabel)
        nameRow.addSubview(renameButton)
        nameRow.addSubview(removeButton)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: nameRow.leadingAnchor),
            nameLabel.centerYAnchor.constraint(equalTo: renameButton.centerYAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: renameButton.leadingAnchor, constant: -CanvasDesign.Space.sm),
            renameButton.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -CanvasDesign.Space.xs),
            renameButton.centerYAnchor.constraint(equalTo: removeButton.centerYAnchor),
            removeButton.trailingAnchor.constraint(equalTo: nameRow.trailingAnchor),
            nameRow.topAnchor.constraint(lessThanOrEqualTo: nameLabel.topAnchor),
            nameRow.topAnchor.constraint(lessThanOrEqualTo: removeButton.topAnchor),
            nameRow.bottomAnchor.constraint(greaterThanOrEqualTo: nameLabel.bottomAnchor),
            nameRow.bottomAnchor.constraint(greaterThanOrEqualTo: removeButton.bottomAnchor)
        ])
        for anchor in [
            nameRow.topAnchor.constraint(equalTo: nameLabel.topAnchor),
            nameRow.topAnchor.constraint(equalTo: removeButton.topAnchor),
            nameRow.bottomAnchor.constraint(equalTo: nameLabel.bottomAnchor),
            nameRow.bottomAnchor.constraint(equalTo: removeButton.bottomAnchor)
        ] {
            anchor.priority = .defaultLow
            anchor.isActive = true
        }

        askFirstCheckbox.font = CanvasDesign.font(.primary, size: 12)
        (askFirstCheckbox.cell as? NSButtonCell)?.attributedTitle = NSAttributedString(
            string: HostScreenArmingPresentation.asksWhenInUseLabel,
            attributes: [
                .font: CanvasDesign.font(.primary, size: 12),
                .foregroundColor: CanvasDesign.ink.nsColor
            ]
        )
        askFirstCheckbox.target = self
        askFirstCheckbox.action = #selector(askFirstToggled)

        for view: NSView in [nameRow, toggleRow, askFirstCheckbox, metaLabel] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        // The name/Remove line alone reaches the true trailing edge --
        // every other line merely wraps under whatever width it needs.
        nameRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let inset = CanvasDesign.Space.sm
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])

        nameLabel.stringValue = row.deviceName
        toggle.isEnabled = true
        toggle.alphaValue = 1
        toggleLabel.alphaValue = 1
        askFirstCheckbox.state = row.asksWhenInUse ? .on : .off
        askFirstCheckbox.isHidden = !row.isSharingRealScreen
        let meta = Self.metaLine(for: row)
        metaLabel.stringValue = meta ?? ""
        metaLabel.isHidden = meta == nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The key fingerprint and which display may be shared (or why not),
    /// joined into the one secondary line this row has room for -- each
    /// piece already reads as a plain sentence fragment on its own, so
    /// " \u{00B7} " between them is the only punctuation this needs.
    private static func metaLine(for row: HostScreenArmingPresentation.PairedMachineRow) -> String? {
        var parts: [String] = []
        if let keyFingerprintLine = row.keyFingerprintLine {
            parts.append(keyFingerprintLine)
        }
        if let sharedDisplaysLine = row.sharedDisplaysLine {
            parts.append(bareDisplayList(from: sharedDisplaysLine))
        } else if let notOfferedReason = row.notOfferedReason {
            parts.append(notOfferedReason)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// Drops `sharedDisplaysLine`'s own "May share " lead-in and trailing
    /// period, leaving the bare display list -- "Built-in Display" rather
    /// than "May share Built-in Display." -- to sit as one segment beside
    /// this row's other segments rather than reading as its own sentence.
    private static func bareDisplayList(from sharedDisplaysLine: String) -> String {
        var text = sharedDisplaysLine
        if text.hasPrefix("May share ") {
            text.removeFirst("May share ".count)
        }
        if text.hasSuffix(".") {
            text.removeLast()
        }
        return text
    }

    @objc private func toggled() {
        onToggle?(toggle.isOn)
    }

    @objc private func askFirstToggled() {
        onToggleAskFirst?(askFirstCheckbox.state == .on)
    }

    @objc private func removeTapped() {
        onRemove?()
    }

    @objc private func renameTapped() {
        onRename?()
    }

    /// A row's small bordered text button. Sized from the label itself, not
    /// left to the bordered-off cell's own tight fit: without this the title
    /// all but touches the border on every side. Insets match this row's own
    /// outer padding horizontally and the row's tightest vertical gap
    /// otherwise.
    private static func styleRowButton(_ button: NSButton, title: String, color: DesignColor) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = CanvasDesign.Radius.tight
        button.layer?.backgroundColor = CanvasDesign.bg3.cgColor
        button.layer?.borderWidth = 1
        button.layer?.borderColor = CanvasDesign.line2.cgColor
        let attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: CanvasDesign.font(.primary, size: 12, weight: .regular),
                .foregroundColor: color.nsColor
            ]
        )
        button.attributedTitle = attributedTitle
        button.translatesAutoresizingMaskIntoConstraints = false
        let titleSize = attributedTitle.size()
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: ceil(titleSize.width) + CanvasDesign.Space.sm * 2),
            button.heightAnchor.constraint(equalToConstant: ceil(titleSize.height) + CanvasDesign.Space.xs * 2)
        ])
    }
}

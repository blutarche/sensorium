import AppKit
import Foundation

/// One row per machine that has ever paired, each with its own Remove and
/// Share host screen controls. Visible in every state the surrounding
/// `HostSetupWindowController` can be in, not only while a session is live
/// -- someone who paired a machine months ago must see it without hunting.
@MainActor
final class PairedMachinesView: NSView {
    private let eyebrow = NSTextField(labelWithAttributedString: CanvasDesign.eyebrow("Paired machines"))
    private let emptyLabel = PairedMachinesView.label("No machine has paired yet.", color: CanvasDesign.muted)
    private let lastSessionCard = NSView()
    private let lastSessionEyebrow = NSTextField(labelWithAttributedString: CanvasDesign.eyebrow("Last Host Screen Session"))
    private let lastSessionLabel = PairedMachinesView.label("", color: CanvasDesign.muted)
    private let lastSessionStack = NSStackView()
    private let stack = NSStackView()
    private let rowsStack = NSStackView()
    private var rowViews: [PairedMachineRowView] = []

    var onToggleSharing: ((Data, Bool) -> Void)?
    var onRemovePairedDevice: ((Data) -> Void)?
    var onToggleAskFirst: ((Data, Bool) -> Void)?

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

        for view in [eyebrow, emptyLabel, rowsStack, lastSessionEyebrow, lastSessionCard] {
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor).isActive = true
        }
        rowsStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        lastSessionCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        stack.setCustomSpacing(CanvasDesign.Space.xs, after: eyebrow)
        stack.setCustomSpacing(CanvasDesign.Space.sm, after: rowsStack)
        stack.setCustomSpacing(CanvasDesign.Space.xs, after: lastSessionEyebrow)

        lastSessionEyebrow.isHidden = true
        lastSessionCard.isHidden = true

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
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
            rowView.onToggleAskFirst = { [weak self] isOn in self?.onToggleAskFirst?(row.devicePublicKey, isOn) }
            return rowView
        }
        for rowView in rowViews {
            rowsStack.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: rowsStack.widthAnchor).isActive = true
        }
        emptyLabel.isHidden = !rows.isEmpty
        rowsStack.isHidden = rows.isEmpty
    }

    /// `nil` when host screen has never run on this machine.
    func updateLastSession(_ line: String?) {
        lastSessionLabel.stringValue = line ?? ""
        lastSessionEyebrow.isHidden = line == nil
        lastSessionCard.isHidden = line == nil
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

/// One machine's own row, four lines at most: its name beside Remove, the
/// Share host screen toggle, the ask-first checkbox while it is sharing, and
/// one wrapping line combining its key fingerprint, which display it may
/// share, and why sharing is or is not available -- everything this row
/// used to spread across as many separate paragraphs, said once.
@MainActor
private final class PairedMachineRowView: NSView {
    private let nameLabel = PairedMachinesView.label()
    private let toggle: HostScreenSharingToggleControl
    private let toggleLabel = PairedMachinesView.label("Share host screen", color: CanvasDesign.muted)
    /// Visible only while this row is sharing -- the setting only means
    /// anything for a machine whose session could prompt at all.
    private let askFirstCheckbox = NSButton(
        checkboxWithTitle: HostScreenArmingPresentation.asksWhenInUseLabel, target: nil, action: nil
    )
    private let metaLabel = PairedMachinesView.label("", color: CanvasDesign.muted)
    private let removeButton = NSButton()
    private let stack = NSStackView()

    var onToggle: ((Bool) -> Void)?
    var onRemove: (() -> Void)?
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

        removeButton.isBordered = false
        removeButton.wantsLayer = true
        removeButton.layer?.cornerRadius = CanvasDesign.Radius.tight
        removeButton.layer?.backgroundColor = CanvasDesign.bg3.cgColor
        removeButton.layer?.borderWidth = 1
        removeButton.layer?.borderColor = CanvasDesign.line2.cgColor
        let removeTitle = NSAttributedString(
            string: "Remove",
            attributes: [
                .font: CanvasDesign.font(.primary, size: 12, weight: .regular),
                .foregroundColor: CanvasDesign.bad.nsColor
            ]
        )
        removeButton.attributedTitle = removeTitle
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.translatesAutoresizingMaskIntoConstraints = false
        // Sized from the label itself, not left to the bordered-off cell's own
        // tight fit: without this the title all but touches the border on
        // every side. Insets match this row's own outer padding (`inset`
        // below) horizontally and the row's tightest vertical gap otherwise.
        let removeTitleSize = removeTitle.size()
        let removeHorizontalInset = CanvasDesign.Space.md
        let removeVerticalInset = CanvasDesign.Space.xs

        // The name and Remove share one line -- Remove pinned to the row's
        // trailing edge, the name taking whatever is left and wrapping
        // before it ever runs under the button. Top-aligned, not centred:
        // a long name can wrap to a second line the button never grows to
        // match, and centring would then drift the button off the name's
        // own first line.
        let nameRow = NSView()
        nameRow.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameRow.addSubview(nameLabel)
        nameRow.addSubview(removeButton)
        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: nameRow.leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: nameRow.topAnchor),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: removeButton.leadingAnchor, constant: -CanvasDesign.Space.sm),
            removeButton.trailingAnchor.constraint(equalTo: nameRow.trailingAnchor),
            removeButton.topAnchor.constraint(equalTo: nameRow.topAnchor),
            nameRow.bottomAnchor.constraint(greaterThanOrEqualTo: nameLabel.bottomAnchor),
            nameRow.bottomAnchor.constraint(greaterThanOrEqualTo: removeButton.bottomAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: ceil(removeTitleSize.width) + removeHorizontalInset * 2),
            removeButton.heightAnchor.constraint(equalToConstant: ceil(removeTitleSize.height) + removeVerticalInset * 2)
        ])

        askFirstCheckbox.font = CanvasDesign.font(.primary, size: 12)
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
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])

        nameLabel.stringValue = row.deviceName
        let sharingAllowed = row.isSharingRealScreen || row.blockedReason == nil
        toggle.isEnabled = sharingAllowed
        // `NSSwitch` dims a disabled control to 0.4 alpha; this custom
        // control and its label match, so a blocked row never reads as an
        // enabled off switch.
        toggle.alphaValue = sharingAllowed ? 1 : 0.4
        toggleLabel.alphaValue = sharingAllowed ? 1 : 0.4
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

    /// The key fingerprint, which display may be shared (or why not), and
    /// why sharing is or is not available, joined into the one secondary
    /// line this row has room for -- each piece already reads as a plain
    /// sentence fragment on its own, so " \u{00B7} " between them is the
    /// only punctuation this needs.
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
        // Blocked reason outranks the credential summary; the two never
        // both apply.
        if let reason = row.blockedReason ?? row.credentialSummary {
            parts.append(reason)
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
}

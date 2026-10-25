import AppKit
import Foundation

/// The small sheet a paired machine's Rename opens: a heading naming the
/// machine, one field prefilled with the name this machine shows for it now,
/// with Cancel and Rename.
/// Return renames and Escape cancels. What it hands back is the field as
/// typed; `PairedDeviceName.normalized` decides what is stored.
@MainActor
public final class PairedMachineRenameView: NSView {
    static let width: CGFloat = 320

    private static let titleFont = CanvasDesign.font(.primary, size: 14, weight: .semibold)
    private static var textWidth: CGFloat { width - CanvasDesign.Space.lg * 2 }

    /// How tall the sheet is when it needs no more room than its own content,
    /// which a long name in the heading can add a line to.
    package static func naturalHeight(currentName: String = "") -> CGFloat {
        PairedMachineRenameView(currentName: currentName, onRename: { _ in }, onCancel: {}).fittingSize.height
    }

    /// Names the machine being renamed, held whole where it fits. A machine
    /// with no name of its own is described instead: its row's "Unnamed
    /// machine" would read here as if it were the name.
    private static func heading(forMachineNamed currentName: String) -> String {
        guard !currentName.isEmpty else { return "Rename the unnamed machine" }
        let name = currentName
        return HostTextFlow.flow(
            "Rename \(name)",
            names: [name],
            measure: HostTextFlow.Measure(attributes: [.font: titleFont], width: textWidth)
        )
    }

    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let nameField = NSTextField()
    private let hintLabel = NSTextField(
        wrappingLabelWithString: HostTextFlow.flow(
            "Only this machine uses this name. Leave it empty to use the name the other machine reports."
        )
    )
    private let cancelButton = NSButton()
    private let renameButton = NSButton()
    private let onRename: (String) -> Void
    private let onCancel: () -> Void

    /// `minimumHeight` lets a sheet reach down to a gap between the rows it
    /// covers; the content then sits centred in the extra room.
    public init(
        currentName: String,
        minimumHeight: CGFloat = 0,
        onRename: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onRename = onRename
        self.onCancel = onCancel
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: max(160, minimumHeight)))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = CanvasDesign.chromeBg.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = CanvasDesign.line2.cgColor
        layer?.cornerRadius = CanvasDesign.Radius.base

        titleLabel.font = Self.titleFont
        titleLabel.textColor = CanvasDesign.ink.nsColor
        titleLabel.stringValue = Self.heading(forMachineNamed: currentName)
        // Same reason as the hint's: a wrapping label is one line tall until
        // it is laid out.
        titleLabel.preferredMaxLayoutWidth = Self.textWidth

        nameField.stringValue = currentName
        nameField.placeholderString = currentName
        nameField.font = CanvasDesign.font(.primary, size: 13)
        nameField.textColor = CanvasDesign.ink.nsColor
        nameField.focusRingType = .none
        nameField.translatesAutoresizingMaskIntoConstraints = false

        hintLabel.font = CanvasDesign.font(.primary, size: 12)
        hintLabel.textColor = CanvasDesign.muted.nsColor
        // Without this a wrapping label reports one line's height until it is
        // laid out, and the view then grows past the height it reported.
        hintLabel.preferredMaxLayoutWidth = Self.textWidth

        Self.style(cancelButton, title: "Cancel", fill: CanvasDesign.bg3, text: CanvasDesign.ink, bordered: true)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)

        Self.style(renameButton, title: "Rename", fill: CanvasDesign.accent, text: CanvasDesign.chromeBg, bordered: false)
        renameButton.keyEquivalent = "\r"
        renameButton.target = self
        renameButton.action = #selector(renameTapped)

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = CanvasDesign.Space.xs
        buttons.setViews([cancelButton, renameButton], in: .trailing)

        let stack = NSStackView(views: [titleLabel, nameField, hintLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CanvasDesign.Space.xs
        stack.setCustomSpacing(CanvasDesign.Space.md, after: hintLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let inset = CanvasDesign.Space.lg
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.width),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: inset),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -inset),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The field, so a sheet can put the cursor in it as it opens.
    var initialFirstResponder: NSView { nameField }

    private static func style(_ button: NSButton, title: String, fill: DesignColor, text: DesignColor, bordered: Bool) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = CanvasDesign.Radius.tight
        button.layer?.backgroundColor = fill.cgColor
        if bordered {
            button.layer?.borderWidth = 1
            button.layer?.borderColor = CanvasDesign.line2.cgColor
        }
        let attributed = NSAttributedString(
            string: title,
            attributes: [
                .font: CanvasDesign.font(.primary, size: 13, weight: .medium),
                .foregroundColor: text.nsColor
            ]
        )
        button.attributedTitle = attributed
        button.translatesAutoresizingMaskIntoConstraints = false
        let size = attributed.size()
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: ceil(size.width) + CanvasDesign.Space.md * 2),
            button.heightAnchor.constraint(equalToConstant: ceil(size.height) + CanvasDesign.Space.xs * 2)
        ])
    }

    @objc private func renameTapped() {
        onRename(nameField.stringValue)
    }

    @objc private func cancelTapped() {
        onCancel()
    }
}

/// Dims a window's content while a sheet is up, so the window behind reads as
/// inactive. It takes every click, though the sheet already blocks input.
@MainActor
package final class PairedMachineSheetScrim: NSView {
    package static let opacity: CGFloat = 0.62

    package override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = CanvasDesign.chromeBg.nsColor.withAlphaComponent(Self.opacity).cgColor
        autoresizingMask = [.width, .height]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    package override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// Lays a scrim over `window`'s content; remove it when the sheet ends.
    package static func cover(_ window: NSWindow) -> PairedMachineSheetScrim? {
        guard let content = window.contentView else { return nil }
        let scrim = PairedMachineSheetScrim(frame: content.bounds)
        content.addSubview(scrim)
        return scrim
    }
}

/// Puts `PairedMachineRenameView` up as a sheet on the host window.
@MainActor
enum PairedMachineRenameSheet {
    /// `minimumHeight` is how far down the window the sheet reaches: the
    /// caller picks a depth whose bottom edge falls between two rows.
    static func present(
        on window: NSWindow,
        currentName: String,
        minimumHeight: CGFloat = 0,
        onRename: @escaping (String) -> Void
    ) {
        let height = max(PairedMachineRenameView.naturalHeight(currentName: currentName), minimumHeight)
        let sheet = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: PairedMachineRenameView.width, height: height),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        sheet.appearance = NSAppearance(named: .darkAqua)
        sheet.backgroundColor = CanvasDesign.chromeBg.nsColor
        let scrim = PairedMachineSheetScrim.cover(window)
        let view = PairedMachineRenameView(
            currentName: currentName,
            minimumHeight: height,
            onRename: { [weak window, weak sheet] typed in
                if let window, let sheet { window.endSheet(sheet) }
                onRename(typed)
            },
            onCancel: { [weak window, weak sheet] in
                if let window, let sheet { window.endSheet(sheet) }
            }
        )
        sheet.contentView = view
        sheet.initialFirstResponder = view.initialFirstResponder
        window.beginSheet(sheet) { _ in scrim?.removeFromSuperview() }
    }
}

#if canImport(AppKit)
import AppKit
import SensoriumCore

/// One tailnet device, drawn as a row: the device's name and address, or its
/// offline note, at the same button-as-row shape the rest of this viewer's
/// chrome uses. Selecting a row is the whole gesture -- no separate confirm
/// step, because the step after it is asking for the six digits and choosing
/// the wrong machine there is exactly as recoverable as choosing the wrong one
/// here.
@MainActor
final class TailnetDeviceRowButton: NSButton {
    let row: TailnetDevicePickerRow

    init(row: TailnetDevicePickerRow) {
        self.row = row
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        // Left at the default, an `NSButton` draws its own stock "Button"
        // title underneath whatever is added as a subview -- the title and
        // subtitle below are the row's only text.
        title = ""
        wantsLayer = true
        layer?.backgroundColor = ViewerDesign.chromeBg2.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = ViewerDesign.chromeBorder2.cgColor
        layer?.cornerRadius = ViewerDesign.Radius.base

        let title = NSTextField(labelWithString: row.title)
        title.font = ViewerDesign.font(mono: false, size: 14, weight: .medium)
        title.textColor = (row.peer.isOnline ? ViewerDesign.ink : ViewerDesign.muted).nsColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(labelWithString: row.subtitle)
        subtitle.font = ViewerDesign.font(mono: true, size: 11)
        subtitle.textColor = (row.peer.isOnline ? ViewerDesign.muted : ViewerDesign.muted2).nsColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = ViewerDesign.Space.xxs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let inset = ViewerDesign.Space.md
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: ViewerDesign.Space.sm),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -ViewerDesign.Space.sm)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// The title/subtitle labels are non-interactive, but AppKit's default
    /// hit-testing still finds them before this button's own mouse-tracking
    /// gets a look, which would make everywhere but the row's bare margin
    /// unclickable. Redirecting every hit in this button's bounds back to
    /// itself is the standard fix for a control with subviews standing in
    /// for its title.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }
}
#endif

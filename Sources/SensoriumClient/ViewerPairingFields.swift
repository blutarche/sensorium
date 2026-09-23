#if canImport(AppKit)
import AppKit
import Foundation

/// The controls the viewer's own forms are built from, in one place so a
/// window that asks for a pairing code and a window that lists saved machines draw
/// the same text field, the same hint row and the same link.
@MainActor
enum ViewerFormControls {
    static func label(_ text: String, font: NSFont, color: ViewerColor, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color.nsColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = width
        return label
    }

    /// The hint/error row reserves the taller of its two possible messages
    /// where a caller pins its height (see the address hint below), so a
    /// shorter message must sit at the top of that box rather than centred
    /// within it -- otherwise a one-line error would appear to drop halfway
    /// down the row it shares with the two-line default hint.
    static func hintLabel(width: CGFloat) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        let cell = ViewerTopAlignedWrappingCell(textCell: "")
        cell.font = ViewerDesign.font(mono: false, size: 12)
        cell.textColor = ViewerDesign.muted.nsColor
        cell.lineBreakMode = .byWordWrapping
        cell.isEditable = false
        cell.isSelectable = false
        cell.isBezeled = false
        cell.drawsBackground = false
        field.cell = cell
        field.font = cell.font
        field.textColor = cell.textColor
        field.lineBreakMode = .byWordWrapping
        field.maximumNumberOfLines = 0
        field.preferredMaxLayoutWidth = width
        return field
    }

    static func placeholder(_ text: String, mono: Bool, size: CGFloat) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: [
                .font: ViewerDesign.font(mono: mono, size: size),
                .foregroundColor: ViewerDesign.muted2.nsColor
            ]
        )
    }

    static func textField(mono: Bool, size: CGFloat) -> NSTextField {
        let field = NSTextField()
        let cell = ViewerPairingFieldCell(textCell: "")
        cell.isEditable = true
        cell.isSelectable = true
        cell.isBezeled = false
        cell.drawsBackground = false
        cell.usesSingleLineMode = true
        cell.wraps = false
        cell.isScrollable = true
        field.cell = cell
        field.font = ViewerDesign.font(mono: mono, size: size)
        field.textColor = ViewerDesign.ink.nsColor
        field.isBordered = false
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.backgroundColor = ViewerDesign.bg4.cgColor
        field.layer?.cornerRadius = ViewerDesign.Radius.base
        field.layer?.borderWidth = 1
        field.layer?.borderColor = ViewerDesign.line.cgColor
        return field
    }

    /// The gap `linkButton`'s own icon sits at ahead of its title. NSButton
    /// has no spacing property between an image and a title beside it, so
    /// this is baked into the icon itself as transparent trailing margin.
    private static let linkIconTitleGap: CGFloat = 4

    /// A word that acts, drawn as text rather than as a control: the way back,
    /// the way to look again, the way to type an address instead. `symbol`
    /// names an SF Symbol drawn ahead of the title, tinted the same accent,
    /// for a link a person might otherwise read as plain text over one to press.
    static func linkButton(_ title: String, symbol: String? = nil) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: ViewerDesign.font(mono: false, size: 13),
                .foregroundColor: ViewerDesign.accent.nsColor
            ]
        )
        button.translatesAutoresizingMaskIntoConstraints = false
        if let symbol,
           let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
               .withSymbolConfiguration(NSImage.SymbolConfiguration(scale: .small)) {
            button.image = withTrailingGap(icon, linkIconTitleGap)
            button.imagePosition = .imageLeading
            button.imageHugsTitle = true
            button.contentTintColor = ViewerDesign.accent.nsColor
        }
        return button
    }

    /// A copy of `image`, widened by `gap` points of transparent margin on
    /// its trailing edge -- see `linkIconTitleGap`.
    private static func withTrailingGap(_ image: NSImage, _ gap: CGFloat) -> NSImage {
        let padded = NSImage(size: NSSize(width: image.size.width + gap, height: image.size.height))
        padded.lockFocus()
        image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
        padded.unlockFocus()
        padded.isTemplate = image.isTemplate
        return padded
    }

    /// A button that commits. The accent is for the one action a step exists
    /// to reach; every other button on the same step is outlined instead.
    static func actionButton(_ title: String) -> NSButton {
        let button = ViewerFormActionButton()
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = ViewerDesign.Radius.base
        button.translatesAutoresizingMaskIntoConstraints = false
        // Required, not the default: this button is sized to its own
        // intrinsic width below, and one that could still compress under
        // that guarantee would silently reopen the edge-to-edge overflow
        // the padding exists to prevent.
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.heightAnchor.constraint(equalToConstant: 32).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        style(button, title: title, isPrimary: true, isEnabled: true)
        return button
    }

    static func style(_ button: NSButton, title: String, isPrimary: Bool, isEnabled: Bool) {
        button.isEnabled = isEnabled
        let filled = isPrimary && isEnabled
        button.layer?.backgroundColor = filled
            ? ViewerDesign.accent.cgColor
            : ViewerDesign.chromeBg2.cgColor
        button.layer?.borderWidth = filled ? 0 : 1
        button.layer?.borderColor = ViewerDesign.line.cgColor
        let color: ViewerColor
        if filled {
            color = ViewerDesign.chromeBg
        } else {
            color = isEnabled ? ViewerDesign.ink : ViewerDesign.muted2
        }
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: ViewerDesign.font(mono: false, size: 14, weight: .medium),
                .foregroundColor: color.nsColor
            ]
        )
    }
}

/// The `>= 96` width floor above only pads a short title like "Pair"; a
/// longer one outgrows it with no horizontal margin at all, hugging the
/// accent fill edge-to-edge. This adds that margin regardless of title
/// length, the same fix `ViewerActionButton` makes for the status panel's
/// own buttons.
final class ViewerFormActionButton: NSButton {
    override var intrinsicContentSize: NSSize {
        let titleWidth = ceil(attributedTitle.size().width)
        return NSSize(width: titleWidth + ViewerDesign.Space.md * 2, height: 32)
    }
}

/// AppKit gives a borderless text field no inset at all, which puts the caret
/// against the fill's edge. There is no property for it; a cell is the only
/// place the text and the field editor are both positioned.
final class ViewerPairingFieldCell: NSTextFieldCell {
    private static let horizontalInset = ViewerDesign.Space.sm

    /// Centred on the font's own full line box, not `cellSize(forBounds:)`:
    /// that measures the full line box too, but `NSTextFieldCell`'s own
    /// drawing then places single-line text within it hugging the top rather
    /// than centred, which is exactly the crookedness this cell exists to
    /// fix. `boundingRectForFont`, not `ascender - descender`: a mono digit's
    /// glyph can sit taller than the font's own ascender/descender pair
    /// reports, and the shorter box clipped its top -- `drawInterior` below
    /// draws unclipped now, but the box is still what this rect centres in.
    override func titleRect(forBounds rect: NSRect) -> NSRect {
        let inset = rect.insetBy(dx: Self.horizontalInset, dy: 0)
        guard let font else { return inset }
        let lineHeight = ceil(font.boundingRectForFont.height)
        return NSRect(
            x: inset.origin.x,
            y: inset.origin.y + (inset.height - lineHeight) / 2,
            width: inset.width,
            height: lineHeight
        )
    }

    /// Draws the string directly rather than through `super`: `super`'s own
    /// `drawInterior` recomputes its own vertical placement from the frame it
    /// is given instead of trusting `titleRect(forBounds:)`, which is the top
    /// bias `titleRect` above works around. Placeholder is drawn the same way
    /// `NSTextFieldCell` would when the field is empty and not being edited.
    /// While the field editor is active it already draws the live text over
    /// this cell, so the string is skipped here to avoid drawing it twice.
    /// `draw(at:)`, not `draw(in:)`: the latter clips to the rect it is given,
    /// and a mono digit's glyph can draw taller than `titleRect`'s own box,
    /// which is sized to look centred rather than to bound every glyph. Only
    /// the origin is used, so the horizontal inset and vertical centring
    /// `titleRect` computed still hold; nothing here constrains the width,
    /// same as `NSTextFieldCell`'s own unclipped single-line drawing.
    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        guard (controlView as? NSTextField)?.currentEditor() == nil else { return }
        let rect = titleRect(forBounds: cellFrame)
        let toDraw = stringValue.isEmpty ? (placeholderAttributedString ?? attributedStringValue) : attributedStringValue
        toDraw.draw(at: rect.origin)
    }

    override func edit(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor: NSText,
        delegate: Any?,
        event: NSEvent?
    ) {
        super.edit(
            withFrame: titleRect(forBounds: rect),
            in: controlView,
            editor: editor,
            delegate: delegate,
            event: event
        )
    }

    override func select(
        withFrame rect: NSRect,
        in controlView: NSView,
        editor: NSText,
        delegate: Any?,
        start: Int,
        length: Int
    ) {
        super.select(
            withFrame: titleRect(forBounds: rect),
            in: controlView,
            editor: editor,
            delegate: delegate,
            start: start,
            length: length
        )
    }
}

/// A wrapping label cell that draws at the top of its bounds rather than
/// vertically centred -- `NSTextFieldCell`'s own default when its frame is
/// taller than the text needs, which the hint/error row's reserved height
/// deliberately makes true for a one-line message under a two-line box.
final class ViewerTopAlignedWrappingCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        let natural = cellSize(forBounds: NSRect(x: 0, y: 0, width: rect.width, height: .greatestFiniteMagnitude))
        var top = super.drawingRect(forBounds: rect)
        top.size.height = min(top.height, natural.height)
        return top
    }
}
#endif

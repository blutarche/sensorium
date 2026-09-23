#if canImport(AppKit)
import AppKit

/// A brief, dismissible banner over the canvas for something that failed
/// without ending the session: a refused request, such as a "Displays"
/// increase, or a clipboard that was not shared.
/// Distinct from `ViewerSessionStatusOverlay`: that overlay means the session
/// itself is down and dims the whole picture; this means one request did not
/// go through and the picture underneath is exactly as live as it was a
/// moment ago.
@MainActor
public final class ViewerTransientNoticeView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let dismissButton = NSButton()
    private var hideTask: Task<Void, Never>?
    /// Long enough to read a full sentence, short enough not to become a
    /// second, permanent status line competing with the HUD.
    private static let autoDismissSeconds: Double = 6

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = ViewerDesign.chromeBg2.cgColor
        layer?.cornerRadius = ViewerDesign.Radius.base
        layer?.borderWidth = 1
        layer?.borderColor = ViewerDesign.warn.cgColor

        label.font = ViewerDesign.font(mono: false, size: 12)
        label.textColor = ViewerDesign.ink.nsColor
        label.lineBreakMode = .byWordWrapping
        // Unbounded: the banner has no fixed height and grows with the label,
        // so a sentence that wraps to a fourth line costs nothing -- a cap
        // here would cut off the remedy, which is the sentence's last line.
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 360
        label.translatesAutoresizingMaskIntoConstraints = false

        dismissButton.isBordered = false
        dismissButton.attributedTitle = NSAttributedString(
            string: "\u{2715}",
            attributes: [
                .font: ViewerDesign.font(mono: false, size: 11),
                .foregroundColor: ViewerDesign.ink.nsColor
            ]
        )
        dismissButton.target = self
        dismissButton.action = #selector(dismissTapped)
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(label)
        addSubview(dismissButton)
        let inset = ViewerDesign.Space.sm
        // 24pt square: the glyph itself is a few points wide, but the tap
        // target it sits in must not be.
        let dismissHitArea: CGFloat = 24
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            label.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset),
            dismissButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: ViewerDesign.Space.xs),
            dismissButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            dismissButton.centerYAnchor.constraint(equalTo: label.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: dismissHitArea),
            dismissButton.heightAnchor.constraint(equalToConstant: dismissHitArea)
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    public func show(_ text: String) {
        label.stringValue = text
        isHidden = false
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.autoDismissSeconds))
            guard !Task.isCancelled else { return }
            self?.isHidden = true
        }
    }

    @objc private func dismissTapped() {
        hideTask?.cancel()
        isHidden = true
    }
}
#endif

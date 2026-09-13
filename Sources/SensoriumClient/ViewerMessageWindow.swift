#if canImport(AppKit)
import AppKit

/// Which of this window's buttons ended it, so a caller offering more than
/// one can act on the one actually tapped instead of only ever dismissing.
public enum ViewerMessageWindowResult: Equatable, Sendable {
    case dismissed
    /// `actionTitle`'s own button was tapped -- only reachable when the
    /// caller supplied one.
    case actionTapped
    /// `secondaryActionTitle`'s own button was tapped -- the second thing to
    /// try, offered beneath the first. Only reachable when the caller
    /// supplied one.
    case secondaryActionTapped
}

/// One thing to say, and either one way out or a fix to offer alongside it.
/// Used when the viewer cannot start at all — there is no session to put a
/// status overlay on and no form to fill in, and the alternative is a line on
/// a stream a double-clicked app has nobody reading.
///
/// Thin, like the pairing window: it is handed the words and shows them.
@MainActor
public final class ViewerMessageWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private var continuation: CheckedContinuation<ViewerMessageWindowResult, Never>?
    private var hasFinished = false
    private var result: ViewerMessageWindowResult = .dismissed

    /// `actionTitle` is `nil` for a plain one-button message. Non-`nil` adds a
    /// second, primary button above the dismiss button, styled the way
    /// this app's other primary actions are.
    ///
    /// `actionIsDefault` decides which button Return activates. `false` --
    /// the default -- keeps `dismissTitle` the one Return key, or a stray
    /// keystroke, cannot fire by accident; a caller whose action is not
    /// destructive (an undo, a retry) may opt into `true` instead.
    public init(
        eyebrow: String,
        headline: String,
        detail: String,
        actionTitle: String? = nil,
        actionIsDefault: Bool = false,
        secondaryActionTitle: String? = nil,
        dismissTitle: String
    ) {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 200),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Sensorium"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = ViewerDesign.chromeBg.nsColor
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = ViewerDesign.chromeBg.cgColor

        let eyebrowLabel = NSTextField(labelWithAttributedString: NSAttributedString(
            string: eyebrow,
            attributes: [
                .font: ViewerDesign.font(mono: true, size: 12, weight: .medium),
                .foregroundColor: ViewerDesign.muted2.nsColor,
                .kern: ViewerDesign.kern(ViewerDesign.Tracking.widest, size: 12)
            ]
        ))
        let headlineLabel = Self.label(
            headline,
            font: ViewerDesign.font(mono: false, size: 20, weight: .medium),
            color: ViewerDesign.ink
        )
        let detailLabel = Self.label(
            detail,
            font: ViewerDesign.font(mono: false, size: 12),
            color: ViewerDesign.muted
        )

        // Present together, whichever button Return activates is the primary
        // one -- filled accent -- and the other steps back to a plain
        // outline, the same primary/secondary pairing the pairing window
        // already uses. Present alone, dismiss carries the filled accent.
        let actionIsPrimary = actionTitle != nil && actionIsDefault
        let actionButton: NSButton?
        if let actionTitle {
            let button = NSButton()
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = ViewerDesign.Radius.base
            if actionIsPrimary {
                button.layer?.backgroundColor = ViewerDesign.accent.cgColor
            } else {
                button.layer?.backgroundColor = ViewerDesign.bg4.cgColor
                button.layer?.borderWidth = 1
                button.layer?.borderColor = ViewerDesign.line.cgColor
            }
            button.attributedTitle = NSAttributedString(
                string: actionTitle,
                attributes: [
                    .font: ViewerDesign.font(mono: false, size: 14, weight: .medium),
                    .foregroundColor: (actionIsPrimary ? ViewerDesign.chromeBg : ViewerDesign.ink).nsColor
                ]
            )
            button.target = self
            button.action = #selector(actionTapped)
            button.keyEquivalent = actionIsDefault ? "\r" : ""
            button.translatesAutoresizingMaskIntoConstraints = false
            actionButton = button
        } else {
            actionButton = nil
        }

        // The second thing to try, always outlined: only one button on a
        // screen may read as the first choice.
        let secondaryActionButton: NSButton?
        if let secondaryActionTitle {
            let button = NSButton()
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = ViewerDesign.Radius.base
            button.layer?.backgroundColor = ViewerDesign.bg4.cgColor
            button.layer?.borderWidth = 1
            button.layer?.borderColor = ViewerDesign.line.cgColor
            button.attributedTitle = NSAttributedString(
                string: secondaryActionTitle,
                attributes: [
                    .font: ViewerDesign.font(mono: false, size: 14, weight: .medium),
                    .foregroundColor: ViewerDesign.ink.nsColor
                ]
            )
            button.target = self
            button.action = #selector(secondaryActionTapped)
            button.translatesAutoresizingMaskIntoConstraints = false
            secondaryActionButton = button
        } else {
            secondaryActionButton = nil
        }

        let dismissButton = NSButton()
        dismissButton.isBordered = false
        dismissButton.wantsLayer = true
        dismissButton.layer?.cornerRadius = ViewerDesign.Radius.base
        if actionButton != nil && actionIsPrimary {
            dismissButton.layer?.backgroundColor = ViewerDesign.bg4.cgColor
            dismissButton.layer?.borderWidth = 1
            dismissButton.layer?.borderColor = ViewerDesign.line.cgColor
        } else {
            dismissButton.layer?.backgroundColor = ViewerDesign.accent.cgColor
        }
        dismissButton.attributedTitle = NSAttributedString(
            string: dismissTitle,
            attributes: [
                .font: ViewerDesign.font(mono: false, size: 14, weight: .medium),
                // `.ink`, the same off-white a secondary `ViewerActionButton`
                // uses (see ClientCanvasWindowController.swift): `.muted2`
                // here read as a disabled label on this button's `.bg4` fill.
                .foregroundColor: (actionButton != nil && actionIsPrimary ? ViewerDesign.ink : ViewerDesign.chromeBg).nsColor
            ]
        )
        dismissButton.target = self
        dismissButton.action = #selector(dismiss)
        dismissButton.keyEquivalent = (actionButton == nil || !actionIsDefault) ? "\r" : ""
        dismissButton.translatesAutoresizingMaskIntoConstraints = false

        // The default -- whichever button Return activates -- sits in the
        // top slot: a reader's eye and the keyboard should meet the same
        // button first, not whichever role happens to be second.
        let buttonsTopFirst = actionIsPrimary
            ? [actionButton, secondaryActionButton, dismissButton]
            : [dismissButton, actionButton, secondaryActionButton]
        let arrangedSubviews = ([eyebrowLabel, headlineLabel, detailLabel] + buttonsTopFirst).compactMap { $0 }
        let root = NSStackView(views: arrangedSubviews)
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = ViewerDesign.Space.sm
        root.translatesAutoresizingMaskIntoConstraints = false
        root.setCustomSpacing(ViewerDesign.Space.xs, after: headlineLabel)
        root.setCustomSpacing(ViewerDesign.Space.lg, after: detailLabel)
        content.addSubview(root)

        let inset = ViewerDesign.Space.xl
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        var constraints = [
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
            root.widthAnchor.constraint(equalToConstant: Self.windowWidth - inset * 2),
            dismissButton.heightAnchor.constraint(equalToConstant: 32)
        ]
        if let actionButton {
            constraints.append(actionButton.heightAnchor.constraint(equalToConstant: 32))
        }
        if let secondaryActionButton {
            constraints.append(secondaryActionButton.heightAnchor.constraint(equalToConstant: 32))
        }
        NSLayoutConstraint.activate(constraints)

        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(
            width: Self.windowWidth,
            height: ceil(root.fittingSize.height) + inset * 2
        ))
    }

    /// Shows the window and answers once one of its buttons ends it.
    /// Requires a running AppKit event loop.
    public func run() async -> ViewerMessageWindowResult {
        if hasFinished { return result }
        NSApplication.shared.setActivationPolicy(.regular)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { (continuation: CheckedContinuation<ViewerMessageWindowResult, Never>) in
            if hasFinished {
                continuation.resume(returning: result)
            } else {
                self.continuation = continuation
            }
        }
    }

    @objc public func dismiss() {
        finish(with: .dismissed)
    }

    /// Public, like `dismiss()`, so the effect is one action a test can
    /// drive without simulating a click.
    @objc public func actionTapped() {
        finish(with: .actionTapped)
    }

    /// Public for the same reason `actionTapped()` is.
    @objc public func secondaryActionTapped() {
        finish(with: .secondaryActionTapped)
    }

    private func finish(with result: ViewerMessageWindowResult) {
        guard !hasFinished else { return }
        hasFinished = true
        self.result = result
        window.delegate = nil
        window.close()
        continuation?.resume(returning: result)
        continuation = nil
    }

    public func windowWillClose(_ notification: Notification) {
        dismiss()
    }

    private static let windowWidth: CGFloat = 460

    private static func label(_ text: String, font: NSFont, color: ViewerColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = color.nsColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = windowWidth - ViewerDesign.Space.xl * 2
        return label
    }
}
#endif

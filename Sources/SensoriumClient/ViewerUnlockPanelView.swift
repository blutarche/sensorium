#if canImport(AppKit)
import AppKit
import Foundation

/// An in-window panel offering to unlock the host's locked login window. Shown
/// only while the host reports its screen locked; it holds a secure password
/// field and an Unlock button, and shows a brief notice after each attempt.
///
/// The typed password is turned into raw bytes and the field is cleared the
/// moment it is submitted, so the panel keeps nothing a person typed once the
/// request is on its way. `secureField.stringValue` below and
/// `HostScreenUnlockCopy.passwordBytes(from:)` are this code's own String
/// handling of the password, not something internal to AppKit:
/// `NSSecureTextField` has no accessor that is not a `String`, so reading it
/// and turning it into bytes are unavoidably first-party. Both happen once,
/// in `submit` below, and the field is cleared in that same call --
/// everywhere the password is held or sent after that is `Data`/`[UInt8]`.
@MainActor
public final class ViewerUnlockPanelView: NSView, NSTextFieldDelegate {
    private let titleLabel = NSTextField(labelWithString: "Unlock the host")
    private let secureField = NSSecureTextField()
    private let unlockButton = NSButton()
    private let noticeLabel = NSTextField(labelWithString: "")

    /// Called with the raw UTF-8 bytes of the typed password. The field is
    /// already cleared by the time this fires, so the caller holds the only
    /// reference this side keeps: it sends the bytes once and drops them. It
    /// does not claim to wipe them, because copy-on-write `Data` gives no way
    /// to reach the transient copies framing makes.
    public var onSubmit: ((Data) -> Void)?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = ViewerDesign.chromeBg2.cgColor
        layer?.cornerRadius = ViewerDesign.Radius.base
        layer?.borderWidth = 1
        layer?.borderColor = ViewerDesign.accent.cgColor

        titleLabel.font = ViewerDesign.font(mono: false, size: 13)
        titleLabel.textColor = ViewerDesign.ink.nsColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        secureField.font = ViewerDesign.font(mono: false, size: 12)
        secureField.placeholderString = "Login password"
        secureField.translatesAutoresizingMaskIntoConstraints = false
        secureField.target = self
        secureField.action = #selector(submit)
        secureField.delegate = self

        unlockButton.title = "Unlock"
        unlockButton.bezelStyle = .rounded
        unlockButton.target = self
        unlockButton.action = #selector(submit)
        // No `keyEquivalent = "\r"`: a default-button Return runs before keyDown
        // for every bare Return anywhere in the window, and while a locked host
        // screen is live the focus stays on the canvas, so such a Return would
        // fire Unlock instead of reaching the host. Return still submits when the
        // secure field itself has focus, through its own action set above.
        unlockButton.translatesAutoresizingMaskIntoConstraints = false

        noticeLabel.font = ViewerDesign.font(mono: false, size: 11)
        noticeLabel.textColor = ViewerDesign.ink.nsColor
        noticeLabel.lineBreakMode = .byWordWrapping
        noticeLabel.maximumNumberOfLines = 0
        noticeLabel.preferredMaxLayoutWidth = 300
        noticeLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(secureField)
        addSubview(unlockButton)
        addSubview(noticeLabel)
        let inset = ViewerDesign.Space.sm
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: inset),
            secureField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            secureField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: ViewerDesign.Space.xs),
            secureField.widthAnchor.constraint(equalToConstant: 200),
            unlockButton.leadingAnchor.constraint(equalTo: secureField.trailingAnchor, constant: ViewerDesign.Space.xs),
            unlockButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            unlockButton.centerYAnchor.constraint(equalTo: secureField.centerYAnchor),
            noticeLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            noticeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            noticeLabel.topAnchor.constraint(equalTo: secureField.bottomAnchor, constant: ViewerDesign.Space.xs),
            noticeLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Offers the prompt, clearing any stale field contents and notice only on
    /// the hidden-to-visible transition. The host follows every unlock result
    /// with a fresh lock-state report, and on a still-locked screen that
    /// re-offers the prompt in the same round trip; clearing here every time
    /// would wipe the notice the result just set before the person could read
    /// it. A first-time offer still starts clean, and `hide` between sessions
    /// is what makes the next offer a first-time one.
    public func show() {
        if isHidden {
            secureField.stringValue = ""
            noticeLabel.stringValue = ""
            setSubmitting(false)
            isHidden = false
        }
    }

    public func hide() {
        secureField.stringValue = ""
        setSubmitting(false)
        isHidden = true
    }

    /// Disables or re-enables the field and Unlock button for the span of one
    /// submit. A submit waits on a host round trip and then a multi-second
    /// presence prompt; without this a person could fire a second submit into
    /// that gap, which the flow can only refuse. Disabling the field also closes
    /// its own Return-to-submit path, since a disabled field fires no action.
    private func setSubmitting(_ submitting: Bool) {
        secureField.isEnabled = !submitting
        unlockButton.isEnabled = !submitting
    }

    /// Whether the field and Unlock button are currently accepting input. Read
    /// by the viewer's tests to prove a submit disables them until it resolves.
    public var isAcceptingInput: Bool {
        secureField.isEnabled && unlockButton.isEnabled
    }

    /// The notice currently shown beneath the field, empty when there is
    /// none. Read by the viewer's tests to prove a result notice survives the
    /// lock-state report the host sends right after it.
    public var noticeText: String {
        noticeLabel.stringValue
    }

    /// The brief notice after one attempt. A wrong password keeps the prompt up
    /// to try again; every other outcome is shown and the field is cleared.
    public func showResult(_ line: String) {
        setSubmitting(false)
        noticeLabel.stringValue = line
        secureField.stringValue = ""
    }

    /// Submits whatever is typed, driven by the field's own Return and the
    /// Unlock button's click -- never a global key equivalent, so a bare Return
    /// aimed at the live canvas reaches the host instead of firing Unlock. An
    /// empty field submits nothing, so a stray Return costs a round trip to a
    /// host that would only answer that the password was wrong.
    @objc public func submit() {
        let bytes = HostScreenUnlockCopy.passwordBytes(from: secureField.stringValue)
        // An empty field sends nothing. The host refuses an empty password as a
        // wrong one without charging a guess, so this costs no attempt either
        // way -- it spares the round trip and the misleading notice. The guard
        // is before the clear so an empty submit never wipes a field a person is
        // still typing.
        guard !bytes.isEmpty else { return }
        // The field is cleared before the callback fires so it holds nothing
        // typed while the send is in flight.
        secureField.stringValue = ""
        setSubmitting(true)
        onSubmit?(bytes)
    }
}
#endif

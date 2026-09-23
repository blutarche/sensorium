import AppKit
import Foundation

/// The host's one window. Nothing here is configured, opening the app is
/// the whole interaction, so it only shows what is already true, the
/// pairing code on request, every paired machine, and the last host-screen
/// session. Status words come from `HostOperatorPanelView`, so window and
/// menu bar cannot drift apart.
@MainActor
public final class HostSetupWindowController: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let onRevealPairingCode: @MainActor () -> Void
    private let onStop: @MainActor () -> Void
    private let onHidePairingCode: @MainActor () -> Void
    private let onOpenPermissionSettings: @MainActor (String) -> Void
    private let onReplaceIdentity: @MainActor () -> Void
    private let onRetryIdentityRead: @MainActor () -> Void
    private let autoLoginStatus: @MainActor () -> HostAutoLoginStatus
    private let onToggleAutoLogin: @MainActor (Bool) -> Void
    /// The clock this window reads, so a test can hold time still.
    private let now: @MainActor () -> Date
    /// Looked up fresh on every `refresh()`, never cached across it: whether
    /// Tailscale is installed can change while this window is open, and the
    /// button must not keep offering to open an app that is no longer there.
    private let tailscaleAppURLLookup: @MainActor () -> URL?
    private let onOpenTailscaleApp: @MainActor (URL) -> Void
    private let root = NSStackView()
    private let panel = HostOperatorPanelView()
    private let stopButton = NSButton()
    private let permissionButton = NSButton()
    private let tailscaleButton = NSButton()
    /// The identity panel's primary action, above `replaceIdentityButton`:
    /// reading the key again is the first thing to try, and making a new one
    /// is what is left when that keeps failing.
    private let retryIdentityButton = NSButton()
    private let replaceIdentityButton = NSButton()
    private let revealButton = NSButton()
    /// The pairing section's own control: a code the person at this machine
    /// has finished reading out is theirs to take back off the screen,
    /// without waiting for it to expire and without touching anything else
    /// this window shows.
    private let hideCodeButton = NSButton()
    private let pairingCodeView = PairingCodeView()
    private let pairedMachines = PairedMachinesView()
    /// Whether this app opens at login. Off by default in the control
    /// itself -- the process that owns this window applies the "on by
    /// default" choice once, at launch, before this window is ever shown;
    /// this checkbox only ever reflects and changes what is already true.
    private let autoLoginCheckbox = NSButton(checkboxWithTitle: "Open at login", target: nil, action: nil)
    /// Extra text under the checkbox for a status that is not a plain
    /// on/off: `.requiresApproval` needs a trip to System Settings before
    /// it takes effect, and `.notFound` means the platform will not do this
    /// at all -- neither reads as the checkbox simply being off.
    private let autoLoginStatusLabel = NSTextField(labelWithString: "")
    private var status: HostOperatorStatus
    /// Tailscale's app when installed, its download page when not; `nil`
    /// only while the button is hidden.
    private var tailscaleActionURL: URL?
    /// Runs only while a pairing code is counting down.
    private var countdownTicker: Timer?

    private static let windowWidth: CGFloat = 360
    private static let tailscaleDownloadURL = URL(string: "https://tailscale.com/download")!

    public init(
        status: HostOperatorStatus,
        onRevealPairingCode: @escaping @MainActor () -> Void,
        onStop: @escaping @MainActor () -> Void,
        onHidePairingCode: @escaping @MainActor () -> Void = {},
        onOpenPermissionSettings: @escaping @MainActor (String) -> Void = { url in
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        },
        // Tailscale's own bundle identifiers, macsys (the system-extension
        // build) checked first: whichever one is actually installed is the
        // one this machine has.
        tailscaleAppURLLookup: @escaping @MainActor () -> URL? = {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys")
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos")
        },
        onOpenTailscaleApp: @escaping @MainActor (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        },
        onReplaceIdentity: @escaping @MainActor () -> Void = {},
        onRetryIdentityRead: @escaping @MainActor () -> Void = {},
        onToggleSharing: @escaping @MainActor (Data, Bool) -> Void,
        onRemovePairedDevice: @escaping @MainActor (Data) -> Void,
        onToggleAskFirst: @escaping @MainActor (Data, Bool) -> Void = { _, _ in },
        // Read fresh on every `refresh()`, never cached across it, the same
        // as `tailscaleAppURLLookup` above: the owner can change this in
        // System Settings directly while the window is open.
        autoLoginStatus: @escaping @MainActor () -> HostAutoLoginStatus = { .notRegistered },
        onToggleAutoLogin: @escaping @MainActor (Bool) -> Void = { _ in },
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        self.onRevealPairingCode = onRevealPairingCode
        self.onStop = onStop
        self.onHidePairingCode = onHidePairingCode
        self.onOpenPermissionSettings = onOpenPermissionSettings
        self.tailscaleAppURLLookup = tailscaleAppURLLookup
        self.onOpenTailscaleApp = onOpenTailscaleApp
        self.onReplaceIdentity = onReplaceIdentity
        self.onRetryIdentityRead = onRetryIdentityRead
        self.autoLoginStatus = autoLoginStatus
        self.onToggleAutoLogin = onToggleAutoLogin
        self.now = now
        self.status = status
        pairedMachines.onToggleSharing = onToggleSharing
        pairedMachines.onRemovePairedDevice = onRemovePairedDevice
        pairedMachines.onToggleAskFirst = onToggleAskFirst
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.title = "Sensorium Host"
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = CanvasDesign.chromeBg.nsColor
        window.isReleasedWhenClosed = false
        window.delegate = self

        buildContent()
        refresh()
    }

    public func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    public func update(_ status: HostOperatorStatus) {
        self.status = status
        refresh()
    }

    public func updatePairedMachines(_ rows: [HostScreenArmingPresentation.PairedMachineRow]) {
        pairedMachines.update(rows: rows)
        resizeToFit()
    }

    public func updateLastHostScreenSession(_ line: String?) {
        pairedMachines.updateLastSession(line)
        resizeToFit()
    }

    public func windowWillClose(_ notification: Notification) {
        // Closing only hides the window; the ticker must not keep running
        // against it.
        stopCountdownTicker()
    }

    // MARK: - Layout

    private func buildContent() {
        let content = NSView()
        content.wantsLayer = true
        content.layer?.backgroundColor = CanvasDesign.chromeBg.cgColor

        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = CanvasDesign.Space.sm
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)

        panel.translatesAutoresizingMaskIntoConstraints = false
        // The code is drawn at the window's full width, outside the status
        // card.
        panel.showsPairingCode = false

        stopButton.isBordered = false
        stopButton.wantsLayer = true
        stopButton.layer?.cornerRadius = CanvasDesign.Radius.base
        stopButton.layer?.backgroundColor = CanvasDesign.bad.cgColor
        stopButton.attributedTitle = NSAttributedString(
            string: "Stop",
            attributes: [
                .font: CanvasDesign.font(.primary, size: 14, weight: .semibold),
                .foregroundColor: NSColor.white
            ]
        )
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.translatesAutoresizingMaskIntoConstraints = false

        permissionButton.isBordered = false
        permissionButton.wantsLayer = true
        permissionButton.layer?.cornerRadius = CanvasDesign.Radius.base
        permissionButton.layer?.backgroundColor = CanvasDesign.warn.cgColor
        permissionButton.target = self
        permissionButton.action = #selector(permissionTapped)
        permissionButton.translatesAutoresizingMaskIntoConstraints = false

        configureProblemActionButton(tailscaleButton, action: #selector(tailscaleTapped))
        configureProblemActionButton(retryIdentityButton, action: #selector(retryIdentityReadTapped))
        configureSecondaryActionButton(replaceIdentityButton, action: #selector(replaceIdentityTapped))

        revealButton.isBordered = false
        revealButton.wantsLayer = true
        revealButton.layer?.cornerRadius = CanvasDesign.Radius.base
        revealButton.target = self
        revealButton.action = #selector(revealTapped)
        revealButton.translatesAutoresizingMaskIntoConstraints = false
        revealButton.attributedTitle = NSAttributedString(
            string: "Show pairing code",
            attributes: [
                .font: CanvasDesign.font(.primary, size: 14, weight: .medium),
                .foregroundColor: CanvasDesign.chromeBg.nsColor
            ]
        )
        revealButton.layer?.backgroundColor = CanvasDesign.accent.cgColor

        pairingCodeView.translatesAutoresizingMaskIntoConstraints = false

        hideCodeButton.isBordered = false
        hideCodeButton.wantsLayer = true
        hideCodeButton.layer?.cornerRadius = CanvasDesign.Radius.base
        hideCodeButton.layer?.borderWidth = 1
        hideCodeButton.layer?.borderColor = CanvasDesign.line2.cgColor
        hideCodeButton.attributedTitle = NSAttributedString(
            string: "Hide code",
            attributes: [
                .font: CanvasDesign.font(.primary, size: 14, weight: .medium),
                .foregroundColor: CanvasDesign.ink.nsColor
            ]
        )
        hideCodeButton.target = self
        hideCodeButton.action = #selector(hideCodeTapped)
        hideCodeButton.translatesAutoresizingMaskIntoConstraints = false

        pairedMachines.translatesAutoresizingMaskIntoConstraints = false

        autoLoginCheckbox.font = CanvasDesign.font(.primary, size: 13)
        (autoLoginCheckbox.cell as? NSButtonCell)?.attributedTitle = NSAttributedString(
            string: "Open at login",
            attributes: [
                .font: CanvasDesign.font(.primary, size: 13),
                .foregroundColor: CanvasDesign.ink.nsColor
            ]
        )
        autoLoginCheckbox.target = self
        autoLoginCheckbox.action = #selector(autoLoginToggled)
        autoLoginCheckbox.translatesAutoresizingMaskIntoConstraints = false

        autoLoginStatusLabel.font = CanvasDesign.font(.primary, size: 12)
        autoLoginStatusLabel.textColor = CanvasDesign.muted.nsColor
        autoLoginStatusLabel.lineBreakMode = .byWordWrapping
        autoLoginStatusLabel.maximumNumberOfLines = 0
        autoLoginStatusLabel.translatesAutoresizingMaskIntoConstraints = false

        let groups: [NSView] = [
            panel, stopButton, permissionButton, tailscaleButton,
            retryIdentityButton, replaceIdentityButton, revealButton, pairingCodeView, hideCodeButton,
            autoLoginCheckbox, autoLoginStatusLabel, pairedMachines
        ]
        for view in groups {
            root.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
        }
        root.setCustomSpacing(CanvasDesign.Space.lg, after: panel)
        root.setCustomSpacing(CanvasDesign.Space.lg, after: stopButton)
        root.setCustomSpacing(CanvasDesign.Space.lg, after: permissionButton)
        root.setCustomSpacing(CanvasDesign.Space.lg, after: tailscaleButton)
        root.setCustomSpacing(CanvasDesign.Space.sm, after: retryIdentityButton)
        root.setCustomSpacing(CanvasDesign.Space.lg, after: replaceIdentityButton)
        root.setCustomSpacing(CanvasDesign.Space.lg, after: revealButton)
        root.setCustomSpacing(CanvasDesign.Space.lg, after: hideCodeButton)
        root.setCustomSpacing(CanvasDesign.Space.xs, after: autoLoginCheckbox)
        root.setCustomSpacing(CanvasDesign.Space.lg, after: autoLoginStatusLabel)

        let inset = CanvasDesign.Space.xl
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
            root.widthAnchor.constraint(equalToConstant: Self.windowWidth - inset * 2),
            stopButton.heightAnchor.constraint(equalToConstant: 32),
            permissionButton.heightAnchor.constraint(equalToConstant: 32),
            tailscaleButton.heightAnchor.constraint(equalToConstant: 32),
            retryIdentityButton.heightAnchor.constraint(equalToConstant: 32),
            replaceIdentityButton.heightAnchor.constraint(equalToConstant: 32),
            revealButton.heightAnchor.constraint(equalToConstant: 32),
            hideCodeButton.heightAnchor.constraint(equalToConstant: 32)
        ])

        window.contentView = content
        resizeToFit()
    }

    // MARK: - State

    private func refresh() {
        var presentation = status.presentation(now: now())

        let isConnected: Bool
        switch status.connection {
        case .serving, .servingHostScreen:
            isConnected = true
        case .notHosting, .hosting, .pairingApproved:
            isConnected = false
        }
        stopButton.isHidden = !isConnected

        // Screen Recording first, the same priority `HostOperatorStatus`
        // already gives it: without it nothing else here works either.
        if let alert = presentation.alerts.first {
            permissionButton.isHidden = false
            permissionButton.attributedTitle = NSAttributedString(
                string: alert.windowButtonTitle,
                attributes: [
                    .font: CanvasDesign.font(.primary, size: 13, weight: .medium),
                    .foregroundColor: CanvasDesign.chromeBg.nsColor
                ]
            )
            permissionButton.identifier = NSUserInterfaceItemIdentifier(alert.settingsURL)
        } else {
            permissionButton.isHidden = true
        }

        // Only the no-address problem offers this button; a bind failure is
        // not fixed by opening Tailscale. When Tailscale is absent the card
        // re-reads with its own problem, so "Download Tailscale" never sits
        // under a headline telling you to open it.
        if status.problem == HostStartupProblemCopy.noTailnetAddress {
            tailscaleButton.isHidden = false
            if let appURL = tailscaleAppURLLookup() {
                tailscaleActionURL = appURL
                setButtonTitle(tailscaleButton, "Open Tailscale")
            } else {
                tailscaleActionURL = Self.tailscaleDownloadURL
                setButtonTitle(tailscaleButton, "Download Tailscale")
                var notInstalled = status
                notInstalled.problem = HostStartupProblemCopy.tailscaleNotInstalled
                presentation = notInstalled.presentation(now: now())
            }
        } else {
            tailscaleActionURL = nil
            tailscaleButton.isHidden = true
        }

        if let identityProblem = presentation.identityProblem {
            retryIdentityButton.isHidden = false
            setButtonTitle(retryIdentityButton, identityProblem.retryButtonTitle)
            replaceIdentityButton.isHidden = false
            setButtonTitle(replaceIdentityButton, identityProblem.replaceButtonTitle, color: CanvasDesign.ink)
        } else {
            retryIdentityButton.isHidden = true
            replaceIdentityButton.isHidden = true
        }

        panel.presentation = presentation

        switch autoLoginStatus() {
        case .enabled:
            autoLoginCheckbox.state = .on
            autoLoginCheckbox.isEnabled = true
            autoLoginStatusLabel.stringValue = ""
            autoLoginStatusLabel.isHidden = true
        case .notRegistered:
            autoLoginCheckbox.state = .off
            autoLoginCheckbox.isEnabled = true
            autoLoginStatusLabel.stringValue = ""
            autoLoginStatusLabel.isHidden = true
        case .requiresApproval:
            // Registered, but macOS will not actually launch it until the
            // owner approves it themselves -- shown, not silently read as on.
            autoLoginCheckbox.state = .on
            autoLoginCheckbox.isEnabled = true
            autoLoginStatusLabel.stringValue = "Needs your approval in System Settings General Login Items."
            autoLoginStatusLabel.isHidden = false
        case .notFound:
            // The platform reports this app as not found: nothing here can
            // turn login items on, so the control is shown disabled rather
            // than silently doing nothing when clicked.
            autoLoginCheckbox.state = .off
            autoLoginCheckbox.isEnabled = false
            autoLoginStatusLabel.stringValue = "Not available on this Mac."
            autoLoginStatusLabel.isHidden = false
        }

        refreshPairingSection(presentation)

        switch presentation.pairingCountdown {
        case .some:
            startCountdownTicker()
        case .none:
            stopCountdownTicker()
        }

        resizeToFit()
    }

    /// The pairing section alone, so a countdown tick can redraw it without
    /// recomputing the rest of the window.
    private func refreshPairingSection(_ presentation: HostOperatorPresentation) {
        let canReveal: Bool
        switch status.connection {
        // A pairing already approved is a machine already confirming the
        // code it was given -- a fresh reveal here would only offer a
        // second, redundant code.
        case .notHosting, .pairingApproved:
            canReveal = false
        case .hosting, .serving, .servingHostScreen:
            canReveal = true
        }
        // The pairing code itself replaces this button the moment one is on
        // screen.
        revealButton.isHidden = !canReveal || presentation.pairingCode != nil
        let anotherFilledButtonAbove = !stopButton.isHidden || !permissionButton.isHidden
            || !tailscaleButton.isHidden || !retryIdentityButton.isHidden
        setRevealButton(enabled: canReveal, dropsToPlain: anotherFilledButtonAbove)

        if let code = presentation.pairingCode {
            pairingCodeView.isHidden = false
            hideCodeButton.isHidden = false
            pairingCodeView.update(
                code: code,
                countdown: presentation.pairingCountdown,
                countdownIsUrgent: presentation.countdownIsUrgent
            )
        } else {
            pairingCodeView.isHidden = true
            hideCodeButton.isHidden = true
        }
    }

    private func startCountdownTicker() {
        guard countdownTicker == nil else {
            return
        }
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePairingCountdownTick()
            }
        }
        // `.common`, so the countdown keeps moving while the person at this
        // machine has this window's own menu or a sheet open -- the same
        // mode `HostMenuBarPresence`'s own ticker uses, for the same reason.
        RunLoop.main.add(ticker, forMode: .common)
        countdownTicker = ticker
    }

    private func stopCountdownTicker() {
        countdownTicker?.invalidate()
        countdownTicker = nil
    }

    /// Not `private`: `CanvasHostTestHooks` fires this tick synchronously.
    func handlePairingCountdownTick() {
        let presentation = status.presentation(now: now())
        refreshPairingSection(presentation)
        resizeToFit()
        // A code that expired between ticks leaves nothing to count down.
        if presentation.pairingCountdown == nil {
            stopCountdownTicker()
        }
    }

    /// Not `private`: `CanvasHostTestHooks` reads this to prove the ticker
    /// stopped.
    var isPairingCountdownTickerRunning: Bool {
        countdownTicker != nil
    }

    @objc private func revealTapped() {
        onRevealPairingCode()
    }

    @objc private func stopTapped() {
        onStop()
    }

    @objc private func hideCodeTapped() {
        onHidePairingCode()
    }

    @objc private func permissionTapped() {
        guard let url = permissionButton.identifier?.rawValue else { return }
        onOpenPermissionSettings(url)
    }

    @objc private func tailscaleTapped() {
        guard let url = tailscaleActionURL else { return }
        onOpenTailscaleApp(url)
    }

    @objc private func replaceIdentityTapped() {
        onReplaceIdentity()
    }

    @objc private func autoLoginToggled() {
        onToggleAutoLogin(autoLoginCheckbox.state == .on)
        refresh()
    }

    @objc private func retryIdentityReadTapped() {
        onRetryIdentityRead()
    }

    /// Shared styling for the gold action buttons.
    private func configureProblemActionButton(_ button: NSButton, action: Selector) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = CanvasDesign.Radius.base
        button.layer?.backgroundColor = CanvasDesign.warn.cgColor
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    /// The outlined counterpart, for an action offered beneath a gold one:
    /// two filled buttons in a row would read as two equal first choices.
    private func configureSecondaryActionButton(_ button: NSButton, action: Selector) {
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.cornerRadius = CanvasDesign.Radius.base
        button.layer?.borderWidth = 1
        button.layer?.borderColor = CanvasDesign.line2.cgColor
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func setButtonTitle(_ button: NSButton, _ title: String, color: DesignColor = CanvasDesign.chromeBg) {
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: CanvasDesign.font(.primary, size: 13, weight: .medium),
                .foregroundColor: color.nsColor
            ]
        )
    }

    /// Drops its fill for a plain border whenever another filled button
    /// already sits above it, so two filled buttons never compete.
    /// `isBordered` stays `false` in both styles, or a native bezel
    /// overrides the 32pt height.
    private func setRevealButton(enabled: Bool, dropsToPlain: Bool) {
        revealButton.isEnabled = enabled
        revealButton.isBordered = false
        if dropsToPlain {
            revealButton.layer?.backgroundColor = nil
            revealButton.layer?.borderWidth = 1
            revealButton.layer?.borderColor = CanvasDesign.line2.cgColor
            revealButton.attributedTitle = NSAttributedString(
                string: "Show pairing code",
                attributes: [
                    .font: CanvasDesign.font(.primary, size: 14, weight: .medium),
                    .foregroundColor: CanvasDesign.ink.nsColor
                ]
            )
        } else {
            revealButton.layer?.backgroundColor = (enabled ? CanvasDesign.accent : CanvasDesign.bg3).cgColor
            revealButton.layer?.borderWidth = enabled ? 0 : 1
            revealButton.layer?.borderColor = CanvasDesign.line2.cgColor
            revealButton.attributedTitle = NSAttributedString(
                string: "Show pairing code",
                attributes: [
                    .font: CanvasDesign.font(.primary, size: 14, weight: .medium),
                    .foregroundColor: CanvasDesign.chromeBg.nsColor
                ]
            )
        }
    }

    /// The window has no scroll view: its height is whatever the panel and
    /// the paired-machines section currently need.
    private func resizeToFit() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let height = ceil(root.fittingSize.height) + CanvasDesign.Space.xl * 2
        window.setContentSize(NSSize(width: Self.windowWidth, height: height))
    }
}

/// The pairing code at the window's full width, outside the status card.
/// `NSTextField` rather than `HostOperatorPanelView`'s private Core
/// Graphics drawing, which is not reachable from here.
@MainActor
private final class PairingCodeView: NSView {
    private let digitsLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private static let inset = CanvasDesign.Space.md

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        // No border: the same flat `bg2` card the status and last-session
        // cards use.
        applyDesignSurface(fill: CanvasDesign.bg2, radius: CanvasDesign.Radius.base)

        digitsLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(digitsLabel)

        countdownLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countdownLabel)

        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)

        NSLayoutConstraint.activate([
            digitsLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            digitsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            digitsLabel.topAnchor.constraint(equalTo: topAnchor, constant: Self.inset),
            countdownLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            countdownLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            countdownLabel.topAnchor.constraint(equalTo: digitsLabel.bottomAnchor, constant: CanvasDesign.Space.xs),
            hintLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset),
            hintLabel.topAnchor.constraint(equalTo: countdownLabel.bottomAnchor, constant: CanvasDesign.Space.xs),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.inset)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    func update(code: String, countdown: String?, countdownIsUrgent: Bool) {
        digitsLabel.attributedStringValue = Self.text(
            code,
            size: 30,
            weight: .semibold,
            color: CanvasDesign.ink,
            tracking: CanvasDesign.Tracking.wide,
            alignment: .center
        )
        countdownLabel.isHidden = countdown == nil
        countdownLabel.attributedStringValue = CanvasDesign.textWithTabularDigits(
            countdown ?? "",
            size: 12,
            color: countdownIsUrgent ? CanvasDesign.warn : CanvasDesign.muted,
            tracking: CanvasDesign.Tracking.snug,
            alignment: .center
        )
        hintLabel.isHidden = countdown == nil
        hintLabel.attributedStringValue = Self.sansText(
            HostOperatorPresentation.pairingCodeHint,
            size: 12,
            weight: .regular,
            color: CanvasDesign.muted,
            tracking: CanvasDesign.Tracking.snug,
            alignment: .center
        )
    }

    /// Mono face for the digits; every other line here is a sentence, not
    /// data.
    private static func text(
        _ string: String,
        size: CGFloat,
        weight: NSFont.Weight,
        color: DesignColor,
        tracking: CGFloat,
        alignment: NSTextAlignment
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        return NSAttributedString(
            string: string,
            attributes: [
                .font: CanvasDesign.font(.mono, size: size, weight: weight),
                .foregroundColor: color.nsColor,
                .kern: CanvasDesign.kern(tracking, size: size),
                .paragraphStyle: paragraph
            ]
        )
    }

    private static func sansText(
        _ string: String,
        size: CGFloat,
        weight: NSFont.Weight,
        color: DesignColor,
        tracking: CGFloat,
        alignment: NSTextAlignment
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        return NSAttributedString(
            string: string,
            attributes: [
                .font: CanvasDesign.font(.primary, size: size, weight: weight),
                .foregroundColor: color.nsColor,
                .kern: CanvasDesign.kern(tracking, size: size),
                .paragraphStyle: paragraph
            ]
        )
    }
}

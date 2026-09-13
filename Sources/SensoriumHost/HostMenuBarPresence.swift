import AppKit
import Foundation
import SensoriumCore

/// The host's presence on the machine it actually runs on.
///
/// `sensoriumd` draws its workspace onto the session canvas, which by
/// definition only the remote viewer can see, and prints everything else to a
/// terminal the shipped launchers do not show. This is the surface that fills
/// that gap — a menu-bar item on the physical machine's own menu bar, never on
/// the canvas.
///
/// Deliberately thin: it draws `HostOperatorPresentation` and owns no state of
/// its own beyond the status it was last given, so the words themselves are
/// decided and tested in `HostOperatorStatus`.
@MainActor
public final class HostMenuBarPresence: NSObject {
    private let openSettings: (String) -> Void
    /// `nil` on the CLI `pair`/`serve` paths, which have no setup window.
    private let openSetup: (@MainActor () -> Void)?
    /// `nil` on the same CLI paths as `openSetup`. Offers Stop, the same
    /// immediate end-of-session action the window's own Stop button
    /// gives, reachable without opening it.
    private let onStop: (@MainActor () -> Void)?
    /// `nil` on the same CLI paths as `openSetup`. Turning sharing off from
    /// here is a one-click path -- someone who armed this months ago must
    /// be able to end it without opening a window first.
    private let onTurnOffSharing: (@MainActor (Data) -> Void)?
    private let quit: () -> Void
    private let panel = HostOperatorPanelView()
    private var statusItem: NSStatusItem?
    private var status: HostOperatorStatus
    private var rendered: HostOperatorPresentation?
    /// Shown whether or not a session is being served, when idle and not
    /// only while serving, so this is not part of
    /// `HostOperatorPresentation`, which describes the session activity
    /// only.
    private var armingLines: [HostScreenArmingPresentation.DeviceLine] = []
    /// Runs only while a pairing code is counting down; nothing else on this
    /// item changes on its own, and a host serving a session should not wake
    /// once a second to redraw an unchanged menu.
    private var countdownTicker: Timer?

    public init(
        status: HostOperatorStatus,
        openSettings: @escaping (String) -> Void = { url in
            if let url = URL(string: url) {
                NSWorkspace.shared.open(url)
            }
        },
        openSetup: (@MainActor () -> Void)? = nil,
        onStop: (@MainActor () -> Void)? = nil,
        onTurnOffSharing: (@MainActor (Data) -> Void)? = nil,
        quit: @escaping () -> Void
    ) {
        self.status = status
        self.openSettings = openSettings
        self.openSetup = openSetup
        self.onStop = onStop
        self.onTurnOffSharing = onTurnOffSharing
        self.quit = quit
    }

    /// Visible whenever anything is armed, independent of whether a
    /// session is currently being served.
    public func updateArming(_ lines: [HostScreenArmingPresentation.DeviceLine]) {
        armingLines = lines
        rebuildMenu()
    }

    /// Adds the item to the menu bar. Never activates the application and
    /// never asks for `.regular`: a status item is visible under `.accessory`,
    /// so this cannot put a Dock icon on this machine or take focus from
    /// whatever the person at this machine is doing.
    public func install() {
        guard statusItem == nil else {
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.menu = NSMenu()
        statusItem = item
        render(rebuildingItems: true)
    }

    public func update(_ status: HostOperatorStatus) {
        self.status = status
        render(rebuildingItems: false)
    }

    private func render(rebuildingItems: Bool) {
        let presentation = status.presentation(now: Date())
        guard rebuildingItems || presentation != rendered else {
            return
        }
        // The item set changes only when a permission does, and the panel's
        // height only when a code appears or a line wraps differently; the
        // countdown changing every second must not rebuild a menu the person
        // at this machine may have open.
        let alertsChanged = rebuildingItems || presentation.alerts != rendered?.alerts
        let previousPanelHeight = panel.frame.height
        rendered = presentation
        if let button = statusItem?.button {
            button.image = Self.icon(for: presentation.indicator)
            // The menu bar's own text, not the canvas: left in the system
            // font and colour so it follows a light or dark menu bar, which a
            // fixed palette colour could not.
            button.title = presentation.menuBarTitle.map { " \($0)" } ?? ""
            button.toolTip = presentation.headline
        }
        panel.presentation = presentation
        if alertsChanged || panel.frame.height != previousPanelHeight {
            rebuildMenu()
        }
        switch presentation.pairingCountdown {
        case .some:
            startCountdownTicker()
        case .none:
            countdownTicker?.invalidate()
            countdownTicker = nil
        }
    }

    private func rebuildMenu() {
        guard let menu = statusItem?.menu, let presentation = rendered else {
            return
        }
        menu.removeAllItems()
        panel.frame = NSRect(origin: .zero, size: panel.fittingSize)
        let panelItem = NSMenuItem()
        panelItem.view = panel
        menu.addItem(panelItem)
        let isConnected: Bool
        switch status.connection {
        case .serving, .servingHostScreen:
            isConnected = true
        case .notHosting, .hosting, .pairingApproved:
            isConnected = false
        }
        if isConnected, onStop != nil {
            menu.addItem(.separator())
            let stopItem = NSMenuItem(title: "Stop", action: #selector(stopTapped), keyEquivalent: "")
            stopItem.target = self
            menu.addItem(stopItem)
        }
        if !armingLines.isEmpty {
            menu.addItem(.separator())
            for line in armingLines {
                let stateItem = NSMenuItem(
                    title: "Sharing host screen with \(line.deviceName)",
                    action: nil,
                    keyEquivalent: ""
                )
                stateItem.isEnabled = false
                menu.addItem(stateItem)
                let credentialItem = NSMenuItem(
                    title: line.credentialSummary
                        ?? HostScreenArmingPresentation.noCredentialNotice(deviceName: line.deviceName),
                    action: nil,
                    keyEquivalent: ""
                )
                credentialItem.isEnabled = false
                menu.addItem(credentialItem)
                // Revokes the Share host screen permission; the Stop item
                // above ends only the live session.
                let turnOffItem = NSMenuItem(
                    title: "Turn Off Share Host Screen for \(line.deviceName)",
                    action: #selector(turnOffSharing(_:)),
                    keyEquivalent: ""
                )
                turnOffItem.target = self
                turnOffItem.representedObject = line.devicePublicKey
                menu.addItem(turnOffItem)
            }
        }
        if !presentation.alerts.isEmpty {
            menu.addItem(.separator())
            for alert in presentation.alerts {
                let item = NSMenuItem(
                    title: alert.title,
                    action: #selector(openSettingsPane(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = alert.settingsURL
                menu.addItem(item)
            }
        }
        if openSetup != nil {
            menu.addItem(.separator())
            let setupItem = NSMenuItem(title: "Host Setup\u{2026}", action: #selector(openSetupWindow), keyEquivalent: "")
            setupItem.target = self
            menu.addItem(setupItem)
        }
        menu.addItem(.separator())
        let aboutItem = NSMenuItem(title: "About Sensorium Host", action: #selector(openAboutPanel), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Sensorium Host", action: #selector(quitHost), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func startCountdownTicker() {
        guard countdownTicker == nil else {
            return
        }
        let ticker = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.render(rebuildingItems: false)
            }
        }
        // `.common`, so the countdown keeps moving while the person at this
        // machine holds the menu open — menu tracking runs its own run-loop
        // mode.
        RunLoop.main.add(ticker, forMode: .common)
        countdownTicker = ticker
    }

    @objc
    private func openSettingsPane(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? String else {
            return
        }
        openSettings(url)
    }

    @objc
    private func openAboutPanel() {
        NSApplication.shared.orderFrontStandardAboutPanel(options: SensoriumCredit.standardAboutPanelOptions)
    }

    @objc
    private func quitHost() {
        quit()
    }

    @objc
    private func openSetupWindow() {
        openSetup?()
    }

    @objc
    private func stopTapped() {
        onStop?()
    }

    @objc
    private func turnOffSharing(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? Data else {
            return
        }
        onTurnOffSharing?(key)
    }

    /// A template image, as the menu bar requires: macOS recolours it for a
    /// light or dark bar and for the highlighted state, which a fixed palette
    /// colour cannot follow. The shape, not the colour, is what distinguishes
    /// the four states.
    private static func icon(for indicator: HostOperatorIndicator) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            let canvas = NSBezierPath(
                roundedRect: NSRect(x: 1.5, y: 3.5, width: 13, height: 9),
                xRadius: CanvasDesign.Radius.tight,
                yRadius: CanvasDesign.Radius.tight
            )
            canvas.lineWidth = 1
            NSColor.black.setStroke()
            NSColor.black.setFill()
            switch indicator {
            case .idle:
                canvas.stroke()
            case .waiting:
                canvas.stroke()
                for offset in stride(from: 0, through: 8, by: 4) {
                    NSBezierPath(rect: NSRect(x: 4 + CGFloat(offset), y: 7, width: 2, height: 2)).fill()
                }
            case .serving:
                canvas.fill()
            case .servingHostScreen:
                // Filled like `.serving` plus a centre ring: distinct
                // enough to read at menu-bar size. The title text itself
                // is `HostOperatorPresentation.menuBarTitle`, drawn by the
                // status item that owns this image, not here.
                canvas.fill()
                NSColor.white.setFill()
                NSBezierPath(ovalIn: NSRect(x: 6.5, y: 6.5, width: 3, height: 3)).fill()
            case .attention:
                canvas.stroke()
                NSBezierPath(rect: NSRect(x: 7.5, y: 8, width: 1, height: 3)).fill()
                NSBezierPath(rect: NSRect(x: 7.5, y: 5.5, width: 1, height: 1)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The panel inside the menu: the state in words, the pairing code at a size
/// it can be read aloud from, and what each missing permission costs.
///
/// Drawn rather than laid out in subviews because every line of it is text on
/// a flat surface — see `docs/design-system.md`, which forbids the elevation a
/// stack of AppKit controls would bring with it, and forbids the semantic
/// colours those controls would default to.
@MainActor
final class HostOperatorPanelView: NSView {
    private static let width: CGFloat = 288
    private static let inset = CanvasDesign.Space.md
    /// The code box's own internal padding -- top, around the digits, and
    /// bottom, around the countdown -- the same `Space.md` `PairingCodeView`
    /// (the Host Setup window's own code box) uses for the same purpose.
    private static let codeBoxInset = CanvasDesign.Space.md

    var presentation: HostOperatorPresentation? {
        didSet {
            guard presentation != oldValue else {
                return
            }
            invalidateIntrinsicContentSize()
            frame = NSRect(origin: frame.origin, size: fittingSize)
            needsDisplay = true
        }
    }

    /// `true` draws the code inset in this card; `HostSetupWindowController`
    /// sets it `false` and draws the code itself, outside the card, at the
    /// window's own full width.
    var showsPairingCode = true

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize {
        NSSize(width: Self.width, height: panelLayout().height)
    }

    override var intrinsicContentSize: NSSize { fittingSize }

    override func draw(_ dirtyRect: NSRect) {
        CanvasDesign.bg2.nsColor.setFill()
        bounds.fill()
        let layout = panelLayout()
        if let codeBox = layout.codeBox {
            let path = NSBezierPath(
                roundedRect: codeBox.insetBy(dx: 0.5, dy: 0.5),
                xRadius: CanvasDesign.Radius.base,
                yRadius: CanvasDesign.Radius.base
            )
            // `bg3` fill, no border: a `bg2` fill would vanish against this
            // panel's own `bg2`.
            CanvasDesign.bg3.nsColor.setFill()
            path.fill()
        }
        for element in layout.texts {
            element.text.draw(with: element.frame, options: NSString.DrawingOptions.usesLineFragmentOrigin)
        }
    }

    private struct Layout {
        var texts: [(text: NSAttributedString, frame: NSRect)] = []
        var codeBox: NSRect?
        var height: CGFloat = 0
    }

    /// `panelLayout()`'s own texts, in the order `draw(_:)` draws them --
    /// `CanvasHostTestHooks`' only route into this view's private layout,
    /// since neither `panelLayout()` nor `Layout` needs to be seen past
    /// this file for anything production code does.
    func testLayoutTexts() -> [NSAttributedString] {
        panelLayout().texts.map(\.text)
    }

    private func panelLayout() -> Layout {
        var layout = Layout()
        guard let presentation else {
            return layout
        }
        let contentWidth = Self.width - Self.inset * 2
        var y = Self.inset

        func place(_ text: NSAttributedString, gapAbove: CGFloat = 0) {
            y += gapAbove
            let height = text.boundingRect(
                with: NSSize(width: contentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            ).height
            layout.texts.append((text, NSRect(x: Self.inset, y: y, width: contentWidth, height: ceil(height))))
            y += ceil(height)
        }

        place(CanvasDesign.eyebrow(presentation.eyebrow, color: presentation.eyebrowColor))
        place(
            Self.text(presentation.headline, face: .primary, size: 14, weight: .medium, color: CanvasDesign.ink),
            gapAbove: CanvasDesign.Space.xs
        )
        // Left blank exactly when the permission alert below is the one
        // place that names this fact -- an empty line would still draw a
        // gap for nothing to fill.
        if !presentation.detail.isEmpty {
            place(
                Self.text(
                    presentation.detail,
                    face: .primary,
                    size: 12,
                    weight: .regular,
                    color: presentation.detailIsWarning ? CanvasDesign.warn : CanvasDesign.muted
                ),
                gapAbove: CanvasDesign.Space.xxs
            )
        }

        if showsPairingCode, let code = presentation.pairingCode {
            y += CanvasDesign.Space.sm
            let boxContentWidth = contentWidth - Self.codeBoxInset * 2
            // The one thing the host has to communicate, at the size it takes
            // to read six digits aloud across a room.
            let digits = Self.text(
                code,
                face: .mono,
                size: 30,
                weight: .semibold,
                color: CanvasDesign.ink,
                tracking: CanvasDesign.Tracking.wide,
                alignment: .center
            )
            let digitsHeight = ceil(digits.boundingRect(
                with: NSSize(width: boxContentWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin]
            ).height)

            // Countdown inside the same box as the digits, not a separate
            // line below it.
            var countdown: NSAttributedString?
            var countdownHeight: CGFloat = 0
            if let countdownText = presentation.pairingCountdown {
                let text = CanvasDesign.textWithTabularDigits(
                    countdownText,
                    size: 12,
                    // The same `warn` the permission alerts carry: in the last
                    // seconds this line is the urgent thing on the panel, and
                    // muted grey would say the opposite.
                    color: presentation.countdownIsUrgent ? CanvasDesign.warn : CanvasDesign.muted,
                    alignment: .center
                )
                countdown = text
                countdownHeight = ceil(text.boundingRect(
                    with: NSSize(width: boxContentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin]
                ).height)
            }

            // Names which machine the digits are typed on -- shown whenever the
            // countdown is, the same "code and its countdown ... inset
            // inside this card" box, not a separate fact outside it.
            var hint: NSAttributedString?
            var hintHeight: CGFloat = 0
            if countdown != nil {
                let text = Self.text(
                    HostOperatorPresentation.pairingCodeHint,
                    face: .primary,
                    size: 12,
                    weight: .regular,
                    color: CanvasDesign.muted,
                    alignment: .center
                )
                hint = text
                hintHeight = ceil(text.boundingRect(
                    with: NSSize(width: boxContentWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin]
                ).height)
            }

            let boxHeight = Self.codeBoxInset * 2 + digitsHeight
                + (countdown != nil ? CanvasDesign.Space.xs + countdownHeight : 0)
                + (hint != nil ? CanvasDesign.Space.xs + hintHeight : 0)
            let box = NSRect(x: Self.inset, y: y, width: contentWidth, height: boxHeight)
            layout.codeBox = box

            layout.texts.append((
                digits,
                NSRect(
                    x: Self.inset + Self.codeBoxInset,
                    y: box.minY + Self.codeBoxInset,
                    width: boxContentWidth,
                    height: digitsHeight
                )
            ))
            if let countdown {
                layout.texts.append((
                    countdown,
                    NSRect(
                        x: Self.inset + Self.codeBoxInset,
                        y: box.minY + Self.codeBoxInset + digitsHeight + CanvasDesign.Space.xs,
                        width: boxContentWidth,
                        height: countdownHeight
                    )
                ))
            }
            if let hint {
                layout.texts.append((
                    hint,
                    NSRect(
                        x: Self.inset + Self.codeBoxInset,
                        y: box.minY + Self.codeBoxInset + digitsHeight + CanvasDesign.Space.xs + countdownHeight
                            + CanvasDesign.Space.xs,
                        width: boxContentWidth,
                        height: hintHeight
                    )
                ))
            }
            y = box.maxY
        }

        // Screen Recording's own alert is skipped here exactly when the
        // status card above already says so -- repeating it in a second
        // card beneath would say the same thing twice. Still shown live,
        // mid-session, when the status card kept the connected machine's name
        // instead.
        for alert in presentation.alerts
        where !(alert.kind == .screenRecording && presentation.screenRecordingReplacesStatusCard) {
            // Named for the permission actually missing, not a generic
            // "PERMISSION NEEDED" that reads the same for either.
            place(
                CanvasDesign.eyebrow("\(alert.kind.rawValue.uppercased()) NEEDED", color: CanvasDesign.warn),
                gapAbove: CanvasDesign.Space.md
            )
            place(
                Self.text(alert.detail, face: .primary, size: 12, weight: .regular, color: CanvasDesign.ink2),
                gapAbove: CanvasDesign.Space.xxs
            )
        }

        layout.height = y + Self.inset
        return layout
    }

    private static func text(
        _ string: String,
        face: DesignTypeface,
        size: CGFloat,
        weight: NSFont.Weight,
        color: DesignColor,
        tracking: CGFloat = CanvasDesign.Tracking.snug,
        alignment: NSTextAlignment = .left
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = alignment
        return NSAttributedString(
            string: string,
            attributes: [
                .font: CanvasDesign.font(face, size: size, weight: weight),
                .foregroundColor: color.nsColor,
                .kern: CanvasDesign.kern(tracking, size: size),
                .paragraphStyle: paragraph
            ]
        )
    }
}

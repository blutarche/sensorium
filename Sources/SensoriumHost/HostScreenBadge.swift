#if os(macOS)
import AppKit
import SensoriumCore
import CoreGraphics
import Foundation
import QuartzCore


/// The badge's background. `hitTest` routes every point outside the Stop
/// button back here, so dot, labels and empty space act as one surface: a
/// click toggles collapsed, a drag moves the window and reports where it
/// was released. Stop keeps its own single-click behaviour.
@MainActor
private final class BadgeSurfaceView: NSView {
    weak var stopButton: NSButton?
    var onClick: (() -> Void)?
    var onDragEnd: (() -> Void)?

    private var dragStartScreenPoint: NSPoint?
    private var dragStartWindowOrigin: NSPoint?
    private var didDrag = false
    private static let dragThreshold: CGFloat = 3

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let result = super.hitTest(point) else { return nil }
        if let stopButton, result === stopButton || result.isDescendant(of: stopButton) {
            return result
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        dragStartScreenPoint = NSEvent.mouseLocation
        dragStartWindowOrigin = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartScreenPoint, let dragStartWindowOrigin, let window else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragStartScreenPoint.x
        let dy = current.y - dragStartScreenPoint.y
        if !didDrag, HostScreenBadgeState.isDrag(from: dragStartScreenPoint, to: current, threshold: Self.dragThreshold) {
            didDrag = true
        }
        if didDrag {
            window.setFrameOrigin(NSPoint(x: dragStartWindowOrigin.x + dx, y: dragStartWindowOrigin.y + dy))
        }
    }

    override func mouseUp(with event: NSEvent) {
        if didDrag {
            onDragEnd?()
        } else {
            onClick?()
        }
        dragStartScreenPoint = nil
        dragStartWindowOrigin = nil
        didDrag = false
    }
}

/// The one window Sensorium places on a physical display: an always-on-top,
/// non-activating panel naming the connected machine and display, with a
/// Stop button. No `.closable`/`.titled` bit, so no click, local or
/// injected, can dismiss it; only Stop does. It stays in the captured
/// stream on purpose, so both people see the same fact: a capture content
/// filter must never exclude it. Its dropped position is remembered per
/// display, on disk, across restarts; collapsed state persists for this
/// process only, never to disk. A thin gradient traces its edge in every
/// state, rotating continuously unless Reduce Motion is on, and the
/// collapsed pill's fill breathes gently unless Reduce Motion is on.
@MainActor
public final class HostScreenBadgeWindowController: NSObject {
    private let state: HostScreenBadgeState
    private let window: NSPanel
    private let positionStore: HostScreenBadgePositionStore
    private let restoresPersistedLayout: Bool
    /// The display this badge belongs on: the one the session streams.
    private let targetDisplayID: CGDirectDisplayID?
    /// The target's current geometry, resolved on each layout pass.
    private let displayGeometry: @MainActor (CGDirectDisplayID) -> HostScreenBadgeDisplayGeometry?
    /// Which app is sharing, above the device name: the person at this machine
    /// may never have opened Sensorium Host themselves. Hidden in the
    /// collapsed pill, which has no room for it.
    private let eyebrowLabel = NSTextField(labelWithString: "")
    private let deviceLabel = NSTextField(labelWithString: "")
    /// The second line in the badge's expanded and shrunk forms. Hidden in
    /// the collapsed pill, whose tooltip carries the same words instead.
    private let displayLabel = NSTextField(labelWithString: "")
    private let stopButton = NSButton()
    /// Shown only in the collapsed pill, as the one fact a glance at a tiny
    /// corner badge still needs to convey: something is live.
    private let statusDot = NSView()
    /// The badge's animated border. Masked by `borderMaskLayer` to a stroke
    /// of the badge's own rounded rect, so only the edge itself carries the
    /// gradient.
    private let borderGradientLayer = CAGradientLayer()
    private let borderMaskLayer = CAShapeLayer()
    /// Whether Reduce Motion is on, read fresh on every layout pass rather
    /// than once at construction, so a badge already on screen goes still
    /// the moment the person turns it on. A closure, not a direct call to
    /// `NSWorkspace`, so a test can drive both branches without touching
    /// this machine's real accessibility setting.
    private let prefersReducedMotion: () -> Bool
    private var insetConstraints: [NSLayoutConstraint] = []
    private var stopWidthConstraint: NSLayoutConstraint?
    private var stopHeightConstraint: NSLayoutConstraint?
    private var minimumWidthConstraint: NSLayoutConstraint?
    private var maximumWidthConstraint: NSLayoutConstraint?
    /// Active only in the collapsed pill, where a long device name must
    /// truncate rather than stretch a corner badge across the screen.
    private var pillDeviceMaxWidthConstraint: NSLayoutConstraint?

    private static let margin: CGFloat = 12
    private static let borderWidth: CGFloat = 1.5
    private static let borderRotationStartKey = "borderGradientStartPointRotation"
    private static let borderRotationEndKey = "borderGradientEndPointRotation"
    private static let collapsedPulseKey = "collapsedPillOpacityPulse"
    /// The collapsed state left behind by whichever badge last changed it,
    /// so the next one -- the next session, in the same host process --
    /// starts where the person left it. In memory only, never written to
    /// disk; the dropped position, by contrast, lives in `positionStore`.
    /// The first badge of a host process opens as the small corner pill.
    private static var persistedCollapsed = true

    /// Type sizes and insets per badge state. Shrunk keeps every element
    /// at smaller type; pill drops the eyebrow and display line, which is
    /// what makes it small.
    private struct Metrics {
        let eyebrowSize: CGFloat
        let deviceSize: CGFloat
        let detailSize: CGFloat
        let stopSize: CGFloat
        let inset: CGFloat
        let stopButtonSize: NSSize
        /// Bounds on the window's width: wide enough that a short device
        /// name does not leave Stop crowding the text, and capped so a long
        /// one truncates instead of walking across the display.
        let minimumWidth: CGFloat
        let maximumWidth: CGFloat

        static let expanded = Metrics(
            eyebrowSize: 11, deviceSize: 17, detailSize: 13, stopSize: 13, inset: CanvasDesign.Space.md,
            stopButtonSize: NSSize(width: 52, height: 28), minimumWidth: 280, maximumWidth: 420
        )
        static let shrunk = Metrics(
            eyebrowSize: 9, deviceSize: 13, detailSize: 11, stopSize: 12, inset: CanvasDesign.Space.xs + 2,
            stopButtonSize: NSSize(width: 44, height: 24), minimumWidth: 220, maximumWidth: 340
        )
        static let pill = Metrics(
            eyebrowSize: 0, deviceSize: 12, detailSize: 0, stopSize: 10, inset: CanvasDesign.Space.xxs + 1,
            stopButtonSize: NSSize(width: 34, height: 18), minimumWidth: 90, maximumWidth: 260
        )
    }

    /// `restoresPersistedLayout` is `true` for every real caller: the spot
    /// this device last dropped the badge on this display, and whether it
    /// was collapsed, is what a new session's badge should also start as.
    /// It exists as a parameter, not a hard-coded step, only so a test can
    /// build a badge at a specific, known position or collapsed state
    /// without that choice being silently overwritten by a stored position
    /// or by whatever an earlier badge in the same process left behind.
    public init(
        state: HostScreenBadgeState,
        targetDisplayID: CGDirectDisplayID? = nil,
        restoresPersistedLayout: Bool = true,
        positionStore: HostScreenBadgePositionStore = .shared,
        displayGeometry: @escaping @MainActor (CGDirectDisplayID) -> HostScreenBadgeDisplayGeometry? = HostScreenBadgeWindowController.systemDisplayGeometry,
        prefersReducedMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    ) {
        self.state = state
        self.targetDisplayID = targetDisplayID
        self.restoresPersistedLayout = restoresPersistedLayout
        self.positionStore = positionStore
        self.displayGeometry = displayGeometry
        self.prefersReducedMotion = prefersReducedMotion
        window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.expanded.minimumWidth, height: 0),
            styleMask: [.nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        super.init()

        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        // Set after `isFloatingPanel`, which resets an `NSPanel`'s level to
        // `.floating` as a side effect. The overlay level keeps the badge
        // above the Dock and the menu bar wherever it is dropped.
        window.isFloatingPanel = true
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        window.becomesKeyOnlyIfNeeded = true
        window.hidesOnDeactivate = false
        // The invariant requires a continuous, unmissable indication for
        // the whole session -- the app's own Hide (Cmd-H) must not be able
        // to take this window down.
        window.canHide = false
        window.backgroundColor = CanvasDesign.chromeBg.nsColor
        window.isReleasedWhenClosed = false

        if restoresPersistedLayout {
            state.setCollapsed(Self.persistedCollapsed)
        }

        buildContent()
        refresh()
        state.onExpansionChange = { [weak self] in self?.refresh() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleScreenParametersChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    public func show() {
        window.orderFrontRegardless()
    }

    public func hide() {
        window.orderOut(nil)
    }

    /// `false` by construction: no `.closable` bit, so no close control,
    /// local or injected, can dismiss the badge.
    public var hasNativeCloseControl: Bool {
        window.styleMask.contains(.closable)
    }

    private func buildContent() {
        let content = BadgeSurfaceView()
        content.wantsLayer = true
        content.layer?.setAppearanceColor(CanvasDesign.chromeBg.nsColor, for: "backgroundColor")
        content.layer?.cornerRadius = CanvasDesign.Radius.base

        borderGradientLayer.setAppearanceGradientColors(HostScreenBadgeState.borderGradientColors.map(\.nsColor))
        borderMaskLayer.fillColor = nil
        borderMaskLayer.strokeColor = NSColor.black.cgColor
        borderMaskLayer.lineWidth = Self.borderWidth
        borderGradientLayer.mask = borderMaskLayer
        content.layer?.addSublayer(borderGradientLayer)

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = CanvasDesign.Space.xxs
        stack.translatesAutoresizingMaskIntoConstraints = false

        deviceLabel.textColor = CanvasDesign.ink.nsColor
        displayLabel.textColor = CanvasDesign.muted.nsColor
        for label in [eyebrowLabel, deviceLabel, displayLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        statusDot.wantsLayer = true
        statusDot.layer?.setAppearanceColor(CanvasDesign.bad.nsColor, for: "backgroundColor")
        statusDot.layer?.cornerRadius = 4
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.isHidden = true

        stopButton.isBordered = false
        stopButton.wantsLayer = true
        stopButton.layer?.cornerRadius = CanvasDesign.Radius.tight
        stopButton.layer?.setAppearanceColor(CanvasDesign.bad.nsColor, for: "backgroundColor")
        stopButton.target = self
        stopButton.action = #selector(stopTapped)
        stopButton.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [statusDot, stack, stopButton])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = CanvasDesign.Space.sm
        row.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(row)

        stack.addArrangedSubview(eyebrowLabel)
        stack.addArrangedSubview(deviceLabel)
        stack.addArrangedSubview(displayLabel)

        content.stopButton = stopButton
        content.onClick = { [weak self] in
            guard let self else { return }
            self.state.toggleCollapsed()
            Self.persistedCollapsed = self.state.isCollapsed
        }
        content.onDragEnd = { [weak self] in self?.commitDraggedOrigin() }

        insetConstraints = [
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ]
        let stopWidth = stopButton.widthAnchor.constraint(equalToConstant: 0)
        let stopHeight = stopButton.heightAnchor.constraint(equalToConstant: 0)
        let minimumWidth = content.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)
        let maximumWidth = content.widthAnchor.constraint(lessThanOrEqualToConstant: 0)
        let pillDeviceMaxWidth = deviceLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 160)
        stopWidthConstraint = stopWidth
        stopHeightConstraint = stopHeight
        minimumWidthConstraint = minimumWidth
        maximumWidthConstraint = maximumWidth
        pillDeviceMaxWidthConstraint = pillDeviceMaxWidth
        NSLayoutConstraint.activate(
            insetConstraints + [stopWidth, stopHeight, minimumWidth, maximumWidth, statusDot.widthAnchor.constraint(equalToConstant: 8), statusDot.heightAnchor.constraint(equalToConstant: 8)]
        )

        window.contentView = content
    }

    /// Applies the current state's `Metrics`, then sizes the window to what
    /// the content actually needs -- measured, never a fixed height that a
    /// later font change silently overflows -- and repositions it so its
    /// origin, the anchor point collapsing and expanding must not move,
    /// stays put as its size changes.
    private func refresh() {
        if state.isCollapsed {
            applyPillMetrics()
        } else {
            applyFullMetrics(state.isExpanded ? .expanded : .shrunk)
        }

        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
        layoutBorderGradient()
        updateCollapsedPulse()
        layoutOrigin()
    }

    /// Sizes the border gradient and its stroke mask to the badge's current
    /// bounds, then keeps its rotation running -- or holds it on one fixed
    /// diagonal under Reduce Motion. Runs on every `refresh()`, since every
    /// badge state (expanded, shrunk, collapsed) carries the same border.
    private func layoutBorderGradient() {
        guard let content = window.contentView else { return }
        let bounds = content.bounds
        borderGradientLayer.frame = bounds
        borderMaskLayer.frame = bounds
        let inset = Self.borderWidth / 2
        borderMaskLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: inset, dy: inset),
            cornerWidth: CanvasDesign.Radius.base,
            cornerHeight: CanvasDesign.Radius.base,
            transform: nil
        )

        guard !prefersReducedMotion() else {
            borderGradientLayer.removeAnimation(forKey: Self.borderRotationStartKey)
            borderGradientLayer.removeAnimation(forKey: Self.borderRotationEndKey)
            borderGradientLayer.startPoint = CGPoint(x: 0, y: 0)
            borderGradientLayer.endPoint = CGPoint(x: 1, y: 1)
            return
        }
        borderGradientLayer.add(Self.borderRotationAnimation(keyPath: "startPoint", phaseOffset: 0), forKey: Self.borderRotationStartKey)
        borderGradientLayer.add(Self.borderRotationAnimation(keyPath: "endPoint", phaseOffset: .pi), forKey: Self.borderRotationEndKey)
    }

    /// A keyframe animation over `borderGradientRotationKeyframes`, for
    /// either `startPoint` or `endPoint` -- the two ends of the gradient's
    /// axis, opposite `phaseOffset`s apart, so together they read as one
    /// gradient rotating around the badge's centre.
    private static func borderRotationAnimation(keyPath: String, phaseOffset: CGFloat) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = HostScreenBadgeState.borderGradientRotationKeyframes(
            sampleCount: 60, radius: 0.65, phaseOffset: phaseOffset
        ).map { NSValue(point: $0) }
        animation.duration = HostScreenBadgeState.borderGradientRotationDuration
        animation.repeatCount = .infinity
        animation.calculationMode = .linear
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        return animation
    }

    /// Adds or removes the collapsed pill's breathing fill, matching
    /// `state.collapsedPulses` and Reduce Motion -- never both added and
    /// already running, so a `refresh()` while already collapsed does not
    /// restart the breath from its brightest point.
    private func updateCollapsedPulse() {
        guard let layer = window.contentView?.layer else { return }
        guard state.collapsedPulses, !prefersReducedMotion() else {
            layer.removeAnimation(forKey: Self.collapsedPulseKey)
            layer.opacity = 1
            return
        }
        guard layer.animation(forKey: Self.collapsedPulseKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = HostScreenBadgeState.collapsedPulseOpacityRange.from
        pulse.toValue = HostScreenBadgeState.collapsedPulseOpacityRange.to
        pulse.duration = HostScreenBadgeState.collapsedPulseDuration
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: Self.collapsedPulseKey)
    }

    private func applyFullMetrics(_ metrics: Metrics) {
        eyebrowLabel.isHidden = false
        displayLabel.isHidden = false
        statusDot.isHidden = true
        pillDeviceMaxWidthConstraint?.isActive = false
        window.contentView?.toolTip = nil

        eyebrowLabel.attributedStringValue = CanvasDesign.eyebrow("Sensorium Host", color: CanvasDesign.muted, size: metrics.eyebrowSize)
        deviceLabel.font = CanvasDesign.font(.primary, size: metrics.deviceSize, weight: .semibold)
        deviceLabel.stringValue = state.content.deviceName
        displayLabel.font = CanvasDesign.font(.primary, size: metrics.detailSize)
        displayLabel.stringValue = "Sees and controls \(state.content.displayLabel)"
        stopButton.attributedTitle = NSAttributedString(
            string: "Stop",
            attributes: [
                .font: CanvasDesign.font(.primary, size: metrics.stopSize, weight: .semibold),
                .foregroundColor: CanvasDesign.chromeBg.nsColor
            ]
        )
        stopButton.setAccessibilityLabel("Stop sharing with \(state.content.deviceName)")

        applyShared(metrics)
    }

    /// The collapsed pill: dot, machine name, Stop -- nothing else. The
    /// full second line ("Sees and controls <display>") moves to the
    /// window's tooltip instead of disappearing, since hovering
    /// the pill must not expand it (that would make it flap while someone
    /// works near it).
    private func applyPillMetrics() {
        let metrics = Metrics.pill
        eyebrowLabel.isHidden = true
        displayLabel.isHidden = true
        statusDot.isHidden = false
        pillDeviceMaxWidthConstraint?.isActive = true
        window.contentView?.toolTip = "Sees and controls \(state.content.displayLabel)"

        deviceLabel.font = CanvasDesign.font(.primary, size: metrics.deviceSize, weight: .semibold)
        deviceLabel.stringValue = state.content.deviceName
        stopButton.attributedTitle = NSAttributedString(
            string: "Stop",
            attributes: [
                .font: CanvasDesign.font(.primary, size: metrics.stopSize, weight: .semibold),
                .foregroundColor: CanvasDesign.chromeBg.nsColor
            ]
        )
        stopButton.setAccessibilityLabel("Stop sharing with \(state.content.deviceName)")

        applyShared(metrics)
    }

    private func applyShared(_ metrics: Metrics) {
        insetConstraints[0].constant = metrics.inset
        insetConstraints[1].constant = -metrics.inset
        insetConstraints[2].constant = metrics.inset
        insetConstraints[3].constant = -metrics.inset
        stopWidthConstraint?.constant = metrics.stopButtonSize.width
        stopHeightConstraint?.constant = metrics.stopButtonSize.height
        minimumWidthConstraint?.constant = metrics.minimumWidth
        maximumWidthConstraint?.constant = metrics.maximumWidth
    }

    /// The target's geometry, falling back to the main screen while the
    /// target has no live `NSScreen`. Read on every placement pass.
    private var currentGeometry: HostScreenBadgeDisplayGeometry? {
        if let targetDisplayID, let resolved = displayGeometry(targetDisplayID) {
            return resolved
        }
        guard let main = NSScreen.main else { return nil }
        return HostScreenBadgeDisplayGeometry(frame: main.frame, visibleFrame: main.visibleFrame)
    }

    /// The target's identity for saved positions, even while it has no
    /// live `NSScreen`.
    private var currentIdentity: HostScreenDisplayIdentity? {
        if let targetDisplayID {
            return Self.identity(for: targetDisplayID)
        }
        guard let main = NSScreen.main, let id = Self.displayID(for: main) else { return nil }
        return Self.identity(for: id)
    }

    /// Resolves `state.origin` -- restoring a remembered drop or falling
    /// back to the default placement the first time this runs -- then
    /// clamps it into the current screen's full frame and applies it, so
    /// the badge's anchor point stays fixed as its own size changes
    /// (expanding, shrinking, or collapsing) rather than drifting away from
    /// where it was placed. Clamping against the full frame lets the person
    /// placing the badge drop it anywhere on the display, menu-bar and
    /// Dock strips included.
    private func layoutOrigin() {
        guard let geometry = currentGeometry else { return }
        let windowSize = window.frame.size
        if state.origin == nil {
            state.setOrigin(resolvedOrigin(geometry: geometry, windowSize: windowSize))
        }
        let clamped = HostScreenBadgeState.clampedOrigin(state.origin ?? .zero, windowSize: windowSize, in: geometry.frame)
        if clamped != state.origin {
            state.setOrigin(clamped)
        }
        window.setFrameOrigin(clamped)
    }

    /// The starting origin for a badge with no `origin` of its own yet:
    /// this display's remembered drop -- read against `geometry.frame`, the
    /// full frame -- when `restoresPersistedLayout` allows looking for one
    /// and there is one, otherwise the default top-right placement, which
    /// stays anchored to `visibleFrame` so a fresh badge still starts below
    /// the menu bar rather than flush with the top of the display.
    private func resolvedOrigin(geometry: HostScreenBadgeDisplayGeometry, windowSize: CGSize) -> CGPoint {
        if restoresPersistedLayout,
           let identity = currentIdentity,
           let saved = positionStore.position(for: identity) {
            return CGPoint(
                x: geometry.frame.minX + saved.offsetFromFrameOrigin.x,
                y: geometry.frame.minY + saved.offsetFromFrameOrigin.y
            )
        }
        return HostScreenBadgeState.defaultOrigin(windowSize: windowSize, in: geometry.visibleFrame, margin: Self.margin)
    }

    /// Called when a drag on the badge's background ends: clamps where it
    /// was released into the target display's own full frame, records it on
    /// `state`, and remembers it for that display so the next session
    /// starts here too. Not `private`, for the same reason
    /// `handleScreenParametersChange` isn't: `HostScreenIndicationTests`
    /// fires this directly, standing in for a real drag's mouse-up.
    package func commitDraggedOrigin() {
        guard let geometry = currentGeometry else { return }
        let clamped = HostScreenBadgeState.clampedOrigin(window.frame.origin, windowSize: window.frame.size, in: geometry.frame)
        state.setOrigin(clamped)
        window.setFrameOrigin(clamped)
        guard let identity = currentIdentity else { return }
        positionStore.setPosition(
            HostScreenBadgePosition(
                offsetFromFrameOrigin: CGPoint(x: clamped.x - geometry.frame.minX, y: clamped.y - geometry.frame.minY)
            ),
            for: identity
        )
    }

    /// Re-clamps the badge into the target display's own frame, whenever
    /// its geometry changes -- including a host-screen mode change
    /// mid-session -- so the badge never ends up partly or fully off it.
    /// Bounds against the full frame, so a deliberate drop into the
    /// menu-bar or Dock strip survives a geometry change too. Not
    /// `private`: `HostScreenIndicationTests` fires this directly, standing
    /// in for the real notification a screen or mode change would post.
    @objc package func handleScreenParametersChange() {
        guard let geometry = currentGeometry, let origin = state.origin else { return }
        let clamped = HostScreenBadgeState.clampedOrigin(origin, windowSize: window.frame.size, in: geometry.frame)
        guard clamped != origin else { return }
        state.setOrigin(clamped)
        window.setFrameOrigin(clamped)
    }

    /// The real geometry AppKit reports for `id`, matched via the
    /// `NSScreenNumber` device description key -- the same primitive
    /// `DisplayInventory` uses to match a screen to a `CGDirectDisplayID`.
    /// `nil` when no `NSScreen` currently represents that display.
    public static func systemDisplayGeometry(for id: CGDirectDisplayID) -> HostScreenBadgeDisplayGeometry? {
        guard let screen = NSScreen.screens.first(where: { displayID(for: $0) == id }) else {
            return nil
        }
        return HostScreenBadgeDisplayGeometry(frame: screen.frame, visibleFrame: screen.visibleFrame)
    }

    /// `NSScreen` has no `CGDirectDisplayID` of its own; the only way to
    /// match one to a screen is the `NSScreenNumber` device description key
    /// Apple documents for exactly this purpose -- the same lookup
    /// `DisplayInventory` already does.
    private static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(number.uint32Value)
    }

    private static func identity(for id: CGDirectDisplayID) -> HostScreenDisplayIdentity {
        HostScreenDisplayIdentity(vendorNumber: CGDisplayVendorNumber(id), modelNumber: CGDisplayModelNumber(id))
    }

    @objc private func stopTapped() {
        state.stopTapped()
    }
}
#endif

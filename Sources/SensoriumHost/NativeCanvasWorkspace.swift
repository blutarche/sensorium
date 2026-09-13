import AppKit
import CoreGraphics
import Foundation

public enum NativeCanvasWorkspaceError: Error, Equatable {
    case screenUnavailable
}

/// Counts the Sensorium workspace windows currently open.
///
/// The application's activation policy is process-wide but a workspace window
/// is per canvas. Without this count, closing one canvas's window would demote
/// the whole app to `.accessory` while another canvas's window is still open,
/// silently taking keyboard focus away from a live session canvas. Shared
/// rather than injected because it mirrors exactly one thing: `NSApplication`'s
/// own single activation policy.
@MainActor
public final class WorkspaceActivationPolicy {
    public static let shared = WorkspaceActivationPolicy()

    private var openWindows = 0

    private init() {}

    public func windowOpened() {
        openWindows += 1
        NSApplication.shared.setActivationPolicy(.regular)
    }

    public func windowClosed() {
        openWindows = max(0, openWindows - 1)
        guard openWindows == 0 else {
            return
        }
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

/// Tracks whether one workspace window holds this process's keyboard focus.
///
/// Observed from AppKit's notifications rather than read per key:
/// `isKeyWindow`/`isActive` are main-thread state and this is asked once per
/// keystroke from a main actor that is not guaranteed to be AppKit's thread.
/// The live read happens only in `refresh()`, called from `raise`.
@MainActor
final class WorkspaceKeyFocusTracker {
    private(set) var hasKeyFocus = false
    private weak var window: NSWindow?
    private var observers: [any NSObjectProtocol] = []

    /// Begins tracking `window`, adopting whatever focus it holds right now.
    func track(_ window: NSWindow) {
        stop()
        self.window = window
        let center = NotificationCenter.default
        // No queue, so each is delivered synchronously on the thread that
        // posts it, which for all four is AppKit's main thread.
        let names: [(Notification.Name, Any?)] = [
            (NSWindow.didBecomeKeyNotification, window),
            (NSWindow.didResignKeyNotification, window),
            (NSApplication.didBecomeActiveNotification, nil),
            (NSApplication.didResignActiveNotification, nil)
        ]
        observers = names.map { name, object in
            center.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                }
            }
        }
        refresh()
    }

    /// Reads AppKit's live focus state. Only safe from AppKit's main thread.
    func refresh() {
        hasKeyFocus = window?.isKeyWindow == true && NSApplication.shared.isActive
    }

    func stop() {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers = []
        window = nil
        hasKeyFocus = false
    }
}

/// The default session surface: the window a paired viewer sees and types
/// into.
///
/// `physicalDisplayIDs` is captured before Sensorium creates a canvas. Combined
/// with the session-owned handle check, it prevents AppKit from ever placing this
/// window on a monitor that existed before the session.
@MainActor
public final class NativeCanvasWorkspace: CanvasWorkspacePresenting {
    private static let appKitQueueKey = DispatchSpecificKey<UInt8>()
    private let physicalDisplayIDs: Set<UInt32>
    private var window: NSWindow?
    /// The connection whose window is installed right now. A reconnecting
    /// viewer races its own dropped connection here exactly as it does on the
    /// canvas display: without this, the dead connection's late teardown
    /// closes the window the live one is streaming. See `CanvasOwnerToken`.
    private var owner: CanvasOwnerToken?
    /// Identifies the window `installWindow` put up, so a caller that fronted
    /// one can tell it from the window a later `start` installed in its place.
    private var windowToken: CanvasWorkspaceWindowToken?
    /// The canvas `installWindow` placed the window on, kept so `raise` can
    /// confirm the window is still standing on it.
    private var canvasDisplayID: UInt32?
    /// The rectangle that canvas occupies, kept for the same per-key question
    /// in its geometric form: whether the window holding the keyboard right
    /// now stands inside this canvas. See `canvasBounds(owner:)`.
    private var placementBounds: CGRect?
    private let keyFocus = WorkspaceKeyFocusTracker()
    /// Watches the installed window for a close this workspace did not perform.
    /// Nothing in a session should produce one -- the window has no close
    /// button -- but a window that went away while `self.window` still pointed
    /// at it would leave `installedWindow` vending a live token for it, and
    /// every key after that silently dropped with no way back but a reconnect.
    private var windowCloseObserver: (any NSObjectProtocol)?
    /// Serialises placement so a second connection's canvas request cannot
    /// begin while the display-readiness wait below is still pumping the run
    /// loop for a first. Shared with `VirtualDisplaySession` so ownership
    /// transfer is serialised against this same in-flight window — see
    /// `CanvasCreationGate` and `VirtualDisplaySession.start(owner:)`.
    private let creationGate: CanvasCreationGate

    public init(physicalDisplayIDs: Set<UInt32>, creationGate: CanvasCreationGate = CanvasCreationGate()) {
        DispatchQueue.main.setSpecific(key: Self.appKitQueueKey, value: 1)
        self.physicalDisplayIDs = physicalDisplayIDs
        self.creationGate = creationGate
    }

    /// A freshly created virtual display can take a short, variable interval
    /// to register with WindowServer/`NSScreen.screens` after
    /// `CGDisplayBounds` already reports its real size. This bounds how long
    /// `start` waits for that registration before failing loudly instead of
    /// silently placing (or refusing) the workspace on stale display data.
    private static let readinessMaxAttempts = 40
    private static let readinessPollInterval: TimeInterval = 0.05

    public func start(canvasDisplayID: UInt32, owner: CanvasOwnerToken) throws {
        try onAppKitMainThread {
            try MainActor.assumeIsolated {
                try self.startOnAppKitThread(canvasDisplayID: canvasDisplayID, owner: owner)
            }
        }
    }

    private func startOnAppKitThread(canvasDisplayID: UInt32, owner: CanvasOwnerToken) throws {
        // Two overlapping creations sharing process-global CoreGraphics display
        // state is what corrupts the display-ID allocator; the gate makes a
        // reentrant call fail immediately. The wait below holds the main actor
        // for its whole duration, bounded at `readinessMaxAttempts` x
        // `readinessPollInterval`. See `CanvasCreationGate`.
        try creationGate.run {
            stop()
            let expected = VirtualCanvasConfiguration.remoteDefault
            // `RunLoop.main.run(mode:before:)` pumps one turn of the real AppKit
            // main run loop and always returns by the given deadline, whether or
            // not a source fired. That both lets pending CoreGraphics/AppKit
            // display-reconfiguration notifications be delivered (a blocking
            // sleep here would starve exactly the run loop that delivers them)
            // and keeps the overall wait bounded — this cannot deadlock, since
            // each call has an explicit, short-lived limit date.
            let readiness = CanvasDisplayReadiness.awaitReady(
                expectedWidth: expected.logicalWidth,
                expectedHeight: expected.logicalHeight,
                maxAttempts: Self.readinessMaxAttempts,
                probe: {
                    CanvasDisplayReadinessSample(
                        bounds: CGDisplayBounds(canvasDisplayID),
                        isRegisteredInScreens: self.screen(for: canvasDisplayID) != nil
                    )
                },
                pump: {
                    RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(Self.readinessPollInterval))
                }
            )
            let sample = readiness.sample
            print("Sensorium host: canvas readiness attempts=\(readiness.attempts) ready=\(readiness.isReady)")

            let placement = try CanvasWorkspacePlacement.resolve(
                ownedHandle: VirtualDisplayHandle(rawValue: canvasDisplayID),
                display: CanvasWorkspaceDisplay(
                    id: canvasDisplayID,
                    bounds: sample.bounds,
                    isBuiltin: CGDisplayIsBuiltin(canvasDisplayID) != 0,
                    isOnline: CGDisplayIsOnline(canvasDisplayID) != 0
                ),
                physicalDisplayIDs: physicalDisplayIDs
            )
            try installWindow(placement: placement, canvasDisplayID: canvasDisplayID)
            self.owner = owner
        }
    }

    public func stop(owner: CanvasOwnerToken) {
        guard self.owner == owner else {
            return
        }
        stop()
    }

    public func stop() {
        onAppKitMainThread {
            MainActor.assumeIsolated {
                self.discardWindow(closing: true)
            }
        }
    }

    /// The one place installed-window state is dropped, so a close this
    /// workspace performed and a close it merely observed leave exactly the
    /// same state behind -- including the process-wide activation count, which
    /// must be decremented once per window and never twice.
    private func discardWindow(closing: Bool) {
        owner = nil
        windowToken = nil
        canvasDisplayID = nil
        placementBounds = nil
        keyFocus.stop()
        if let observer = windowCloseObserver {
            NotificationCenter.default.removeObserver(observer)
            windowCloseObserver = nil
        }
        guard let window = self.window else {
            return
        }
        // Cleared before the close, not after: `close()` posts
        // `willCloseNotification` synchronously.
        self.window = nil
        if closing {
            window.orderOut(nil)
            window.close()
        }
        WorkspaceActivationPolicy.shared.windowClosed()
    }

    /// Reads only this workspace's own stored state, so a key sender can ask
    /// it per keystroke: no window, or a window another connection installed,
    /// is `nil`, and the same window keeps the same token until a `start`
    /// replaces it.
    public func installedWindow(owner: CanvasOwnerToken) -> CanvasWorkspaceWindowToken? {
        guard window != nil, self.owner == owner else {
            return nil
        }
        return windowToken
    }

    /// The canvas this window was placed on, in `CGDisplayBounds`
    /// coordinates: the rectangle a launched application's window has to be
    /// wholly inside before a key may be posted while that application, rather
    /// than this workspace, holds the keyboard.
    public func canvasBounds(owner: CanvasOwnerToken) -> CGRect? {
        guard window != nil, self.owner == owner else {
            return nil
        }
        return placementBounds
    }

    /// The other half of the per-key question, and the half window identity
    /// cannot answer: whether this window is where the machine's keys are
    /// going right now. Read from the tracker's stored `Bool`, so it costs no
    /// more than `installedWindow` does.
    public func hasKeyFocus(owner: CanvasOwnerToken) -> Bool {
        guard window != nil, self.owner == owner else {
            return false
        }
        return keyFocus.hasKeyFocus
    }

    /// The whole of the keyboard confinement this workspace can offer: the
    /// window is already fixed on the owned canvas by `installWindow`, so
    /// fronting it moves keyboard focus onto that canvas without touching any
    /// display configuration. Refuses when this workspace has no installed
    /// window, or when the caller is not the connection that installed it, so
    /// a caller cannot mistake "nothing to front" or another connection's
    /// window for a confined canvas.
    public func raise(owner: CanvasOwnerToken) -> Bool {
        var raised = false
        onAppKitMainThread {
            raised = MainActor.assumeIsolated {
                guard let window = self.window, let canvasDisplayID = self.canvasDisplayID,
                      self.owner == owner else {
                    return false
                }
                // `installWindow` resolved this window onto the owned canvas
                // and pinned it there, but nothing re-runs that resolution.
                // Fronting a window that has since ended up on another display
                // would put the keyboard onto a physical monitor, which is the
                // one thing confinement exists to prevent.
                guard CanvasWorkspacePlacement.isOnOwnedCanvas(
                    canvasDisplayID: canvasDisplayID,
                    windowScreenDisplayID: Self.displayID(of: window.screen)
                ) else {
                    return false
                }
                window.makeKeyAndOrderFront(nil)
                // The same activation `installWindow` performs, and for the
                // same reason: CoreGraphics keyboard events go to the active
                // app. It fronts this window only; the window's frame stays
                // the placement resolved against the owned canvas.
                NSApplication.shared.activate(ignoringOtherApps: true)
                // AppKit resolves both of those on its own schedule, so this
                // reads what it actually granted rather than assuming. A raise
                // whose focus change has not landed yet leaves `hasKeyFocus`
                // false and the key that prompted it is dropped; the
                // notification that lands restores typing on the next key.
                self.keyFocus.refresh()
                return true
            }
        }
        return raised
    }

    private func installWindow(
        placement: CanvasWorkspacePlacement,
        canvasDisplayID: UInt32
    ) throws {
        guard screen(for: canvasDisplayID) != nil else {
            throw NativeCanvasWorkspaceError.screenUnavailable
        }
        let application = NSApplication.shared
        WorkspaceActivationPolicy.shared.windowOpened()

        // Deliberately not `.closable`. Closing it cannot end the session, and
        // the person at the viewer could not reopen it; `stop()` closes it
        // programmatically, which the style mask does not gate.
        let window = NSWindow(
            contentRect: placement.bounds,
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sensorium Workspace"
        window.isReleasedWhenClosed = false
        // The design system is dark-only. Without this the text view, its field
        // editor and every scroller would follow whatever appearance this
        // machine is set to, which on a light-mode machine means white
        // controls on the palette's near-black surfaces.
        window.appearance = NSAppearance(named: .darkAqua)
        // Chrome is the shell's housing and is deliberately a shade below the
        // workspace surfaces the content view draws.
        window.backgroundColor = CanvasDesign.chromeBg.nsColor
        window.titlebarAppearsTransparent = true
        // Pinned to the canvas the placement resolved. Without this, anyone at
        // this machine can drag this window onto the built-in display, after which
        // `raise` fronts -- and every confined keystroke is typed into -- a
        // window standing on a physical monitor.
        window.isMovable = false
        window.isMovableByWindowBackground = false
        window.setFrame(placement.bounds, display: true)

        let content = WorkspaceContentView(frame: NSRect(origin: .zero, size: placement.bounds.size), canvas: placement)
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        // CoreGraphics keyboard events are delivered to the active app. The
        // window already targets only the owned virtual display; activation
        // gives that session workspace the keyboard focus without changing any
        // physical display configuration.
        application.activate(ignoringOtherApps: true)
        window.makeFirstResponder(content.editor)
        self.window = window
        self.canvasDisplayID = canvasDisplayID
        placementBounds = placement.bounds
        keyFocus.track(window)
        // No queue, so this is delivered synchronously on AppKit's main thread,
        // the only thread that closes a window.
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.discardWindow(closing: false)
            }
        }
        windowToken = CanvasWorkspaceWindowToken()
    }

    /// Swift's main actor does not guarantee AppKit's main *thread* once this
    /// daemon has entered `dispatchMain()`. AppKit rejects off-thread window
    /// construction, so bridge explicitly at this narrow UI boundary.
    private func onAppKitMainThread(_ work: () throws -> Void) rethrows {
        if Thread.isMainThread || DispatchQueue.getSpecific(key: Self.appKitQueueKey) != nil {
            try work()
        } else {
            try DispatchQueue.main.sync(execute: work)
        }
    }

    private func screen(for displayID: UInt32) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
    }

    /// `nil` when AppKit names no screen for the window at all, which it does
    /// for a window it has not placed and for one whose display is
    /// reconfiguring. See `CanvasWorkspacePlacement.isOnOwnedCanvas`.
    static func displayID(of screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

@MainActor
final class WorkspaceContentView: NSView, NSTextViewDelegate {
    /// How to reach the launcher and how to come back. Chrome, not editor
    /// content: the text view below is editable, and select-all followed by
    /// one keystroke would otherwise erase the only reminder of this
    /// window's keyboard, permanently and with nothing to restore it.
    private static let keyboardHint = "\u{2318}L focuses the launcher · Esc returns to the editor"
    /// The margin the whole workspace column stands in.
    private static let inset: CGFloat = 48

    let editor: NSTextView
    private let launcher: CanvasLauncherView

    init(frame frameRect: NSRect, canvas: CanvasWorkspacePlacement) {
        let inset = Self.inset
        let gap: CGFloat = 24
        let launcherWidth: CGFloat = 440
        let contentHeight = max(1, frameRect.height - inset * 2)
        let launcherFrame = NSRect(x: inset, y: inset, width: launcherWidth, height: contentHeight)
        let editorWidth = max(1, frameRect.width - inset * 2 - launcherWidth - gap)
        let panelFrame = NSRect(
            x: inset + launcherWidth + gap,
            y: inset,
            width: editorWidth,
            height: contentHeight
        )
        let panelPad = CanvasDesign.Space.md
        let hintHeight: CGFloat = 16
        let innerWidth = max(1, editorWidth - panelPad * 2)
        let scrollFrame = NSRect(
            x: panelPad,
            y: panelPad,
            width: innerWidth,
            height: max(1, panelFrame.height - panelPad * 2 - hintHeight - CanvasDesign.Space.xs)
        )
        let hintFrame = NSRect(
            x: panelPad,
            y: scrollFrame.maxY + CanvasDesign.Space.xs,
            width: innerWidth,
            height: hintHeight
        )
        let panel = NSView(frame: panelFrame)
        let scrollView = NSScrollView(frame: scrollFrame)
        let editor = NSTextView(frame: scrollFrame)
        self.editor = editor
        // The launcher is what makes this canvas a workstation rather than one
        // text view: it is the only way a remote user, who cannot walk over to
        // this machine and drag a window here, can put a real application on it.
        launcher = CanvasLauncherView(
            frame: NSRect(origin: .zero, size: launcherFrame.size),
            canvas: canvas
        )
        super.init(frame: frameRect)

        applyDesignSurface(fill: CanvasDesign.bg, radius: CanvasDesign.Radius.none)

        editor.isEditable = true
        editor.isSelectable = true
        editor.isRichText = false
        editor.allowsUndo = true
        editor.usesFindBar = true
        // Typed text is the closest thing this surface has to raw data, which is
        // what the system reserves the mono face for. 18pt so it stays legible
        // after the canvas is encoded and scaled down to the viewer's window.
        editor.font = CanvasDesign.font(.mono, size: 18)
        editor.textColor = CanvasDesign.ink.nsColor
        editor.backgroundColor = CanvasDesign.bg2.nsColor
        editor.textContainerInset = NSSize(width: 0, height: CanvasDesign.Space.md)
        editor.textContainer?.lineFragmentPadding = 0
        editor.insertionPointColor = CanvasDesign.accentHi.nsColor
        editor.selectedTextAttributes = [
            .backgroundColor: CanvasDesign.selection.nsColor,
            .foregroundColor: CanvasDesign.ink.nsColor
        ]
        editor.string = """
        Your virtual display is ready. Launch an application from the list on the left; its window opens here. Closing the session removes this display.
        """
        editor.delegate = self

        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = CanvasDesign.bg2.nsColor
        scrollView.scrollerKnobStyle = .light
        scrollView.documentView = editor
        scrollView.autoresizingMask = [.width, .height]

        panel.applyDesignSurface(fill: CanvasDesign.bg2, border: CanvasDesign.line, radius: CanvasDesign.Radius.wide)
        panel.layer?.masksToBounds = true

        let hint = NSTextField(labelWithString: Self.keyboardHint)
        hint.frame = hintFrame
        hint.autoresizingMask = [.width, .minYMargin]
        hint.font = CanvasDesign.font(.mono, size: 12)
        hint.textColor = CanvasDesign.muted.nsColor
        hint.lineBreakMode = .byTruncatingTail
        panel.addSubview(hint)
        panel.addSubview(scrollView)
        addSubview(panel)

        // The panel sizes itself to what it is showing and keeps its top edge,
        // so the column below a short list is workspace background rather than
        // an empty panel.
        launcher.maximumHeight = launcherFrame.height
        launcher.frame = NSRect(
            x: launcherFrame.minX,
            y: launcherFrame.maxY - launcher.frame.height,
            width: launcherFrame.width,
            height: launcher.frame.height
        )
        launcher.autoresizingMask = [.minYMargin]
        launcher.onDismiss = { [weak self] in
            guard let self else {
                return
            }
            self.window?.makeFirstResponder(self.editor)
        }
        addSubview(launcher)
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The launcher's own height is its business; this only tells it how much
    /// column it may take and keeps its top edge on the column's top.
    override func layout() {
        super.layout()
        let contentHeight = max(1, bounds.height - Self.inset * 2)
        launcher.maximumHeight = contentHeight
        launcher.setFrameOrigin(NSPoint(x: Self.inset, y: Self.inset + contentHeight - launcher.frame.height))
    }

    /// Command-L reaches the launcher without the pointer; the text view keeps
    /// first responder at install so a plain key lands in the editor.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers?.lowercased() == "l" {
            window?.makeFirstResponder(launcher.queryField)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

}

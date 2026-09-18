import Dispatch
import SensoriumCore

/// Whether Sensorium itself holds macOS Accessibility approval, and the one
/// way this project ever asks macOS to grant it: `requestAccessibility()`,
/// called at most once for the whole process, at the first session start.
public protocol ClientAccessibilityAuthorization: Sendable {
    var isAccessibilityGranted: Bool { get }
    /// May present macOS's own approval dialog. Returns the grant this
    /// process holds at the moment this call returns, not the outcome of the
    /// dialog: the dialog is asynchronous, so on a real device a call that
    /// shows it returns `false` here every time, and the grant only becomes
    /// true later, once the person answers it.
    func requestAccessibility() -> Bool
}

/// The process-wide policy behind the Accessibility prompt: macOS's dialog is
/// asked for at most once per run, never once per forwarder. A forwarder that
/// started granted and later lost the grant does not get a second ask either
/// — this ledger, not any one forwarder's own history, is what "once" means.
@MainActor
public final class AccessibilityPromptLedger {
    public static let shared = AccessibilityPromptLedger()

    private var hasPrompted = false

    public init() {}

    /// Returns `true` only the first time it is called on this ledger.
    public func claimPrompt() -> Bool {
        guard !hasPrompted else { return false }
        hasPrompted = true
        return true
    }
}

/// A fixed answer, for verifying routing without any TCC state at all.
/// Prompting never changes it: there is no dialog behind a fixed answer to
/// accept or decline.
public struct FixedAccessibilityAuthorization: ClientAccessibilityAuthorization {
    public let isAccessibilityGranted: Bool

    public init(granted: Bool) {
        isAccessibilityGranted = granted
    }

    public func requestAccessibility() -> Bool {
        isAccessibilityGranted
    }
}

public enum SystemShortcutInterceptorError: Error, Equatable {
    /// Refused before touching CoreGraphics: creating a tap without the grant
    /// would make macOS show its approval dialog from inside tap creation
    /// itself, bypassing `requestAccessibility()`, the one place this project
    /// asks for the permission on the user's behalf.
    case accessibilityNotGranted
    case tapCreationFailed
}

/// Why macOS disabled the tap. Kept separate from `CGEventType` so the
/// decision below never needs CoreGraphics to be verified.
public enum TapDisableReason: Equatable, Sendable {
    /// The callback took too long to return. Genuinely worth a bounded retry
    /// — a one-off hitch should not cost the session its shortcut forwarding
    /// for good.
    case timeout
    /// The user, or macOS acting for the user, turned it off. This is the
    /// user's own escape hatch off a machine-wide tap: it must never be
    /// re-armed automatically, in this session or any later disable.
    case userInput
}

/// What a disable notification should do next.
public enum TapReenableDecision: Equatable, Sendable {
    case reenable
    case stayDisabled
    /// Also stays disabled — carries the one line worth telling the user,
    /// said exactly once for the session.
    case stayDisabledAndReport(String)
}

/// Bounds how many times a tap macOS disabled for being too slow is allowed
/// back on before this session stops trying — re-enabling it forever would
/// defeat the OS's own protection against a callback that never gets fast
/// enough. Pure and CoreGraphics-free by design, so the policy is verifiable
/// without a real tap, a TCC grant, or a live run loop.
public final class TapDisableBudget {
    /// Small on purpose: this exists to survive an occasional hitch, not to
    /// paper over a callback that is reliably too slow.
    public static let maxTimeoutReenables = 3

    private var timeoutReenableCount = 0
    private var permanentlyDisabled = false

    public init() {}

    public func decide(_ reason: TapDisableReason) -> TapReenableDecision {
        guard reason == .timeout else {
            permanentlyDisabled = true
            return .stayDisabled
        }
        guard !permanentlyDisabled else {
            return .stayDisabled
        }
        guard timeoutReenableCount < Self.maxTimeoutReenables else {
            permanentlyDisabled = true
            return .stayDisabledAndReport(
                "System shortcuts: the event tap was disabled for being too slow "
                    + "\(Self.maxTimeoutReenables) times; giving up on it for this session. "
                    + "Reserved shortcuts will act on this machine until you reconnect."
            )
        }
        timeoutReenableCount += 1
        return .reenable
    }
}

/// A source of key events the viewer's own responder chain never receives,
/// because the WindowServer claims them first. The handler answers whether the
/// chord was claimed for the host, in which case it must not also reach the
/// local machine.
///
/// This protocol is the seam: every routing decision above it is verifiable
/// with a fake conformer, no TCC grant, and no window server.
@MainActor
public protocol SystemShortcutInterceptor: AnyObject {
    /// `onDegraded` is called at most a handful of times for the whole
    /// session — never per keystroke — when the tap has given up on itself
    /// and needs to say so.
    func start(_ handler: @escaping (KeyChord, Bool) -> Bool, onDegraded: @escaping (String) -> Void) throws
    func stop()
}

/// One viewer window, as shortcut forwarding needs it: what its focus and
/// fullscreen state are, which surface it owns, and how to hand it a key.
@MainActor
public protocol ShortcutForwardingTarget: AnyObject {
    var viewerWindowState: ViewerWindowState { get }
    func forwardShortcut(keyCode: UInt16, isDown: Bool, modifiers: CanvasModifierFlags)
    /// Return the user to the machine they are sitting at, and release
    /// whatever this window still has held on the canvas.
    func releaseToLocalMachine()
}

/// Joins the pure routing policy to whichever viewer window currently has
/// focus. Owns no AppKit object of its own, so its dispatch is verifiable
/// with fake targets and a fake interceptor.
@MainActor
public final class SystemShortcutForwarder {
    private let router: SystemShortcutRouter
    private let accessibility: any ClientAccessibilityAuthorization
    private let interceptor: (any SystemShortcutInterceptor)?
    private let promptLedger: AccessibilityPromptLedger
    private let scheduleGrantCheck: (@escaping @MainActor () -> Void) -> Void
    private var targets: [any ShortcutForwardingTarget] = []
    private var reportedBlockedShortcuts: Set<String> = []
    private var isIntercepting = false
    /// Invalidates any grant check still in flight: bumped by every `stop()`,
    /// so a check scheduled before a stop never starts a tap after it, and a
    /// check captured by a test never has to be found and cancelled by hand.
    private var pollingGeneration = 0

    /// Bounds how long this forwarder keeps polling for a grant the person
    /// has not yet given — five minutes at the default two-second interval —
    /// so a session that is never granted does not poll forever in silence.
    private static let maxGrantChecks = 150

    public init(
        mode: SystemShortcutMode,
        accessibility: any ClientAccessibilityAuthorization,
        interceptor: (any SystemShortcutInterceptor)?,
        promptLedger: AccessibilityPromptLedger = .shared,
        scheduleGrantCheck: @escaping (@escaping @MainActor () -> Void) -> Void = { check in
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                MainActor.assumeIsolated { check() }
            }
        }
    ) {
        router = SystemShortcutRouter(mode: mode)
        self.accessibility = accessibility
        self.interceptor = interceptor
        self.promptLedger = promptLedger
        self.scheduleGrantCheck = scheduleGrantCheck
    }

    public var mode: SystemShortcutMode { router.mode }

    /// Registered once per viewer window. Held strongly, matching this
    /// viewer's own window ownership: both windows live for the whole run.
    public func register(_ target: any ShortcutForwardingTarget) {
        guard !targets.contains(where: { $0 === target }) else { return }
        targets.append(target)
    }

    /// Starts the tap when the mode can actually use one. Asks for
    /// Accessibility at most once for the whole process if the grant is
    /// still missing — the one prompt the viewer ever shows, at the first
    /// session start, tracked by `promptLedger` rather than by this forwarder
    /// alone. macOS's dialog is asynchronous, so a decline here does not mean
    /// "never": it polls for the grant afterward and starts the tap as soon
    /// as it appears, no reconnect required. Reports what it did through
    /// `log` rather than deciding silently; a failure here degrades routing,
    /// it never stops the session.
    public func startInterceptingIfPermitted(log: @escaping (String) -> Void) {
        // Idempotent: a session start that races a still-pending stop (or a
        // caller that calls this twice) must never stack a second tap behind
        // the first — `stop()` only ever tears down the one it is tracking.
        guard !isIntercepting else { return }
        guard router.mode != .local, let interceptor else { return }
        guard accessibility.isAccessibilityGranted else {
            if promptLedger.claimPrompt() {
                if accessibility.requestAccessibility() {
                    startTap(interceptor, log: log)
                    return
                }
                log(
                    "System shortcuts: requested Accessibility approval for Sensorium. Reserved shortcuts will " +
                    "act on this machine until it is granted; forwarding will start as soon as it is."
                )
            } else {
                // Some forwarder already spent the one process-wide prompt
                // and the grant still is not there: say so on every call
                // rather than returning silently, so a session start that
                // never forwards anything is still visible in the log.
                log(
                    "System shortcuts: Accessibility is not granted for Sensorium; reserved shortcuts act on " +
                    "this machine."
                )
            }
            // Whether or not this call was the one that prompted, a grant
            // that appears while this session runs — from the dialog above,
            // or from System Settings — must not need a reconnect to be
            // noticed.
            beginPollingForGrant(interceptor: interceptor, log: log)
            return
        }
        startTap(interceptor, log: log)
    }

    private func startTap(_ interceptor: any SystemShortcutInterceptor, log: @escaping (String) -> Void) {
        do {
            try interceptor.start(
                { [weak self] chord, isDown in
                    self?.handle(chord: chord, isDown: isDown) ?? false
                },
                onDegraded: log
            )
            isIntercepting = true
        } catch {
            log("System shortcuts: could not observe macOS-reserved chords (\(error)). They will act on this machine.")
        }
    }

    private func beginPollingForGrant(interceptor: any SystemShortcutInterceptor, log: @escaping (String) -> Void) {
        pollingGeneration += 1
        enqueueGrantCheck(generation: pollingGeneration, remainingChecks: Self.maxGrantChecks, interceptor: interceptor, log: log)
    }

    private func enqueueGrantCheck(
        generation: Int,
        remainingChecks: Int,
        interceptor: any SystemShortcutInterceptor,
        log: @escaping (String) -> Void
    ) {
        scheduleGrantCheck { [weak self] in
            self?.performGrantCheck(generation: generation, remainingChecks: remainingChecks, interceptor: interceptor, log: log)
        }
    }

    private func performGrantCheck(
        generation: Int,
        remainingChecks: Int,
        interceptor: any SystemShortcutInterceptor,
        log: @escaping (String) -> Void
    ) {
        // A stop() since this check was scheduled bumps the generation, and
        // an already-running tap (started some other way) needs no help —
        // either way there is nothing left for this check to do.
        guard generation == pollingGeneration, !isIntercepting else { return }
        if accessibility.isAccessibilityGranted {
            startTap(interceptor, log: log)
            // `startTap` may itself fail (a tap creation error) and already
            // reports that case on its own; only claim success here if the
            // tap is actually the reason `isIntercepting` is now true.
            if isIntercepting {
                log("System shortcuts: Accessibility granted; reserved shortcuts now reach the host.")
            }
            return
        }
        guard remainingChecks > 1 else { return }
        enqueueGrantCheck(generation: generation, remainingChecks: remainingChecks - 1, interceptor: interceptor, log: log)
    }

    public func stop() {
        // Cancels any grant check still in flight, whether or not a tap was
        // ever actually running to tear down.
        pollingGeneration += 1
        guard isIntercepting else { return }
        interceptor?.stop()
        isIntercepting = false
    }

    /// Returns whether the chord was claimed for the host and must therefore
    /// not continue to the local machine.
    ///
    /// This is the tap's whole surface: the machine-wide tap sees every
    /// keystroke, so the first thing it does is refuse to look at any of them
    /// that are not the escape gesture or a catalog entry. Ordinary typing —
    /// everything else — is never claimed here, at any focus or fullscreen
    /// state, in any mode: it already reaches the app through the viewer's
    /// own responder chain, which has a synchronous local fallback this tap
    /// does not. A lockout needs a tap willing to swallow arbitrary keys;
    /// this one is not.
    ///
    /// Fails open by construction below this guard too: every branch that is
    /// not an explicit, deliberate claim returns `false`, including no
    /// focused target (nothing to hand it to), a `surfaceID` mismatch, and a
    /// chord accessibility cannot see.
    @discardableResult
    public func handle(chord: KeyChord, isDown: Bool) -> Bool {
        guard chord == SystemShortcutCatalog.escapeGesture || SystemShortcutCatalog.shortcut(for: chord) != nil else {
            return false
        }
        guard let target = focusedTarget() else {
            return false
        }
        switch router.decide(
            chord: chord,
            viewer: target.viewerWindowState,
            accessibilityGranted: accessibility.isAccessibilityGranted
        ) {
        case let .forwardToHost(surfaceID):
            guard surfaceID == target.viewerWindowState.surfaceID else { return false }
            target.forwardShortcut(keyCode: chord.keyCode, isDown: isDown, modifiers: chord.modifiers)
            return true
        case .releaseToLocalMachine:
            if isDown {
                target.releaseToLocalMachine()
            }
            return true
        case .notForwardedAccessibilityRequired, .deliverToLocalMachine:
            return false
        }
    }

    /// The notice for a shortcut that reached this viewer but could not be
    /// forwarded — once per shortcut, so a held key does not flood the log.
    /// Returns nil when it has already been said.
    public func unreportedBlockedNotice(for shortcut: SystemShortcut) -> String? {
        guard reportedBlockedShortcuts.insert(shortcut.name).inserted else { return nil }
        return ClientShortcutPermissionReport.blockedLine(shortcut)
    }

    private func focusedTarget() -> (any ShortcutForwardingTarget)? {
        targets.first { $0.viewerWindowState.hasKeyFocus }
    }
}

#if canImport(ApplicationServices)
@preconcurrency import ApplicationServices

/// Reads this process's Accessibility trust, and the one way this project
/// asks macOS to grant it. `AccessibilityPermissionGate` on the host is the
/// same shape for the same reason: reading never prompts, and only an
/// explicit request may present macOS's approval dialog.
public struct SystemAccessibilityAuthorization: ClientAccessibilityAuthorization {
    public init() {}

    public var isAccessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    public func requestAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}
#endif

#if canImport(CoreGraphics) && canImport(AppKit)
import CoreGraphics
import Foundation

/// Bridges the C tap callback, which carries only an opaque pointer, back to
/// the Swift handler, and holds the tap the callback may have to re-enable.
/// File-scope rather than nested so the callback below stays free of any actor
/// isolation of its own. Every access happens on the main run loop — the one
/// the tap's source is added to — which is what the unchecked conformance
/// stands on.
private final class ShortcutTapHandler: @unchecked Sendable {
    var claim: ((KeyChord, Bool) -> Bool)?
    var onDegraded: ((String) -> Void)?
    var tap: CFMachPort?
    /// Decides what a disable notification does next. Pure, so the policy
    /// itself is tested directly (`TapDisableBudget`) rather than through a
    /// real tap; this just holds the one instance for this tap's lifetime.
    let disableBudget = TapDisableBudget()
}

/// Runs on whichever run loop the tap's source was added to — the main one,
/// which is what makes `assumeIsolated` sound here. Every branch below either
/// returns immediately or does bounded, synchronous, non-blocking work: an
/// array scan and an enum switch in `handle` (`SystemShortcutForwarder`), a
/// counter increment in `TapDisableBudget`, and a fire-and-forget `Task {}`
/// launch on the two claim outcomes that need one — never a lock, an await,
/// or I/O on the keystroke path. A callback that blocks is what trips macOS's
/// own timeout disable in the first place.
private func sensoriumShortcutTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    let passThrough = Unmanaged.passUnretained(event)
    guard let userInfo else { return passThrough }
    let handler = Unmanaged<ShortcutTapHandler>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        let reason: TapDisableReason = type == .tapDisabledByTimeout ? .timeout : .userInput
        switch handler.disableBudget.decide(reason) {
        case .reenable:
            if let tap = handler.tap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        case .stayDisabledAndReport(let message):
            handler.onDegraded?(message)
        case .stayDisabled:
            // `.tapDisabledByUserInput` lands here on every occurrence: the
            // user's own escape hatch off a machine-wide tap, never re-armed.
            break
        }
        return passThrough
    }
    guard type == .keyDown || type == .keyUp else {
        return passThrough
    }
    let chord = KeyChord(
        keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
        modifiers: CanvasModifierFlags(eventFlags: event.flags)
    )
    let claimed = MainActor.assumeIsolated {
        handler.claim?(chord, type == .keyDown) ?? false
    }
    return claimed ? nil : passThrough
}

/// The thin glue behind `SystemShortcutInterceptor`: a session event tap that
/// sees the chords the WindowServer would otherwise consume. Never started
/// without an existing Accessibility grant, and never exercised by the
/// verification runners — creating a tap needs that grant and a live run loop.
///
/// `.defaultTap`, not `.listenOnly`: a system-reserved chord only stops
/// acting locally when the tap suppresses the event, and `.listenOnly`'s
/// return value is ignored. A tap cannot be escalated per event either, so
/// suppression "on demand" would always be one event late. What bounds the
/// risk is scope, not tap type: `SystemShortcutForwarder.handle` claims
/// only the escape gesture and catalog entries, never ordinary typing.
@MainActor
public final class CoreGraphicsShortcutInterceptor: SystemShortcutInterceptor {
    private let accessibility: any ClientAccessibilityAuthorization
    /// Recreated fresh in `start()`, not reused across sessions: the disable
    /// budget it carries (`TapDisableBudget`) is per tap, and re-enabling a
    /// brand-new session's tap must not inherit an old session's exhausted
    /// budget.
    private var handler = ShortcutTapHandler()
    private var runLoopSource: CFRunLoopSource?

    public init(accessibility: any ClientAccessibilityAuthorization = SystemAccessibilityAuthorization()) {
        self.accessibility = accessibility
    }

    public func start(_ claim: @escaping (KeyChord, Bool) -> Bool, onDegraded: @escaping (String) -> Void) throws {
        guard accessibility.isAccessibilityGranted else {
            throw SystemShortcutInterceptorError.accessibilityNotGranted
        }
        // Idempotent even if a caller starts twice without stopping: tears
        // down whatever tap is already running first, so the old handler is
        // never left as a dangling `userInfo` pointer behind a still-live tap.
        stop()
        handler = ShortcutTapHandler()
        handler.claim = claim
        handler.onDegraded = onDegraded
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: sensoriumShortcutTapCallback,
            userInfo: Unmanaged.passUnretained(handler).toOpaque()
        ) else {
            handler.claim = nil
            handler.onDegraded = nil
            throw SystemShortcutInterceptorError.tapCreationFailed
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        handler.tap = tap
        runLoopSource = source
    }

    public func stop() {
        if let tap = handler.tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        handler.tap = nil
        handler.claim = nil
        handler.onDegraded = nil
    }
}

extension CanvasModifierFlags {
    /// Keeps only the four modifiers the protocol forwards, matching the
    /// AppKit-side translation so a chord from the tap and the same chord from
    /// the view compare equal.
    init(eventFlags: CGEventFlags) {
        var flags: CanvasModifierFlags = []
        if eventFlags.contains(.maskShift) {
            flags.insert(.shift)
        }
        if eventFlags.contains(.maskControl) {
            flags.insert(.control)
        }
        if eventFlags.contains(.maskAlternate) {
            flags.insert(.option)
        }
        if eventFlags.contains(.maskCommand) {
            flags.insert(.command)
        }
        self = flags
    }
}
#endif

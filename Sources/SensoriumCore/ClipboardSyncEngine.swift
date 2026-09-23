import Foundation

/// An image candidate read off the pasteboard.
public struct ClipboardImage: Equatable, Sendable {
    public let format: ClipboardImageFormat
    public let data: Data

    public init(format: ClipboardImageFormat, data: Data) {
        self.format = format
        self.data = data
    }
}

/// What the local pasteboard currently holds, as far as clipboard sync is
/// concerned. A single copy can offer both a text and an image form;
/// `firstItemTypeIdentifiers` is the first item's type list in the copying
/// app's own order, which is how `ClipboardSyncEngine` picks between them.
/// `isExcludedByType` says the payload carries one of
/// `ClipboardPolicy.excludedTypeIdentifiers` and must never leave the machine
/// whatever it is.
public struct ClipboardReadout: Sendable {
    public let text: String?
    /// Produces the image form, or `nil` when there is none. Producing it can
    /// mean converting a large image, so the engine calls this only once the
    /// image is the form it is about to size and send.
    public let loadImage: @Sendable () -> ClipboardImage?
    public let firstItemTypeIdentifiers: [String]
    /// `false` for a pasteboard that was cleared and left empty, which is
    /// not a copy at all.
    public let hasItems: Bool
    public let isExcludedByType: Bool

    public init(
        text: String?,
        loadImage: @escaping @Sendable () -> ClipboardImage?,
        firstItemTypeIdentifiers: [String],
        hasItems: Bool = true,
        isExcludedByType: Bool
    ) {
        self.text = text
        self.loadImage = loadImage
        self.firstItemTypeIdentifiers = firstItemTypeIdentifiers
        self.hasItems = hasItems
        self.isExcludedByType = isExcludedByType
    }

    public init(
        text: String?,
        image: ClipboardImage?,
        firstItemTypeIdentifiers: [String],
        hasItems: Bool = true,
        isExcludedByType: Bool
    ) {
        self.init(
            text: text,
            loadImage: { image },
            firstItemTypeIdentifiers: firstItemTypeIdentifiers,
            hasItems: hasItems,
            isExcludedByType: isExcludedByType
        )
    }

    /// A pasteboard offering exactly one form, or none.
    public init(content: ClipboardContent?, isExcludedByType: Bool) {
        switch content {
        case let .text(text):
            self.init(text: text, image: nil, firstItemTypeIdentifiers: [], isExcludedByType: isExcludedByType)
        case let .image(format, data):
            self.init(
                text: nil,
                image: ClipboardImage(format: format, data: data),
                firstItemTypeIdentifiers: [],
                isExcludedByType: isExcludedByType
            )
        case nil:
            self.init(text: nil, image: nil, firstItemTypeIdentifiers: [], isExcludedByType: isExcludedByType)
        }
    }
}

/// The seam between clipboard policy and `NSPasteboard`. Everything that
/// decides what to send, what to apply, and what to refuse is written against
/// this, so all of it is testable with no AppKit and no real pasteboard.
public protocol ClipboardPasteboard: AnyObject {
    /// macOS's own monotonic counter of pasteboard writes. The whole
    /// loop-prevention design rests on it; see `ClipboardSyncEngine`.
    var changeCount: Int { get }
    func read() -> ClipboardReadout
    /// Replaces the pasteboard contents, and returns the change count observed
    /// immediately afterwards — which is what makes the write self-accounting.
    @discardableResult
    func write(_ content: ClipboardContent) -> Int
}

public enum ClipboardSendDecision: Equatable, Sendable {
    case nothingToSend
    case send(ClipboardContent)
    case refused(ClipboardRefusal)
}

/// `applied` carries the size and kind rather than the payload: this value is
/// what gets logged.
public enum ClipboardApplyDecision: Equatable, Sendable {
    case applied(description: String, byteCount: Int)
    case refused(ClipboardRefusal)
}

/// Change detection, loop prevention, and size/type policy for one machine's
/// pasteboard. No AppKit, no networking, no timers: a caller polls it and acts
/// on the decision.
///
/// **Why this cannot loop.** Both machines observe their own pasteboard and
/// apply the other's, so the danger is that applying a received clipboard
/// looks like a local copy and gets sent straight back. It cannot, because
/// every change count this engine has dealt with is recorded in
/// `lastAccountedChangeCount`, and `poll()` only ever acts on a change count
/// that differs from it. `apply()` records the change count its own write
/// produced — synchronously, in the same call, before any poll can run — so
/// the change that the apply created is already accounted for by the time
/// anything looks at it. A genuine local copy made after an apply advances
/// the counter again, does not match, and is sent — which is the behaviour
/// that matters.
public final class ClipboardSyncEngine {
    /// The viewer's starting choice. Copying on one machine and pasting on
    /// the other is what a person expects of a remote session; what must not
    /// leave a machine is handled by `ClipboardPolicy.excludedTypeIdentifiers`
    /// and the session gate, and the viewer can turn sharing off at any time.
    public static let sharingEnabledByDefault = true

    /// The host's state for a new connection, before the viewer has said
    /// what it wants. The viewer decides (docs/ux-spec.md) and sends
    /// `clipboardSharing(enabled:)` after every connect, so a host that
    /// started on could send a copy to a viewer that had turned sharing off
    /// in the moment before that message arrives.
    public static let hostSharingEnabledAtConnect = false

    private let pasteboard: any ClipboardPasteboard
    private let maximumContentBytes: Int
    /// docs/ux-spec.md's "Clipboard: on or off," live. Every change goes
    /// through `setEnabled(_:)` below, the one place that re-baselines.
    public private(set) var isEnabled: Bool
    /// Every change count this engine has already dealt with, whether it was
    /// observed by a poll or produced by its own apply. Never re-examined,
    /// which also means a refused local copy is refused once rather than on
    /// every poll for as long as it sits on the pasteboard.
    private var lastAccountedChangeCount: Int

    public init(
        pasteboard: any ClipboardPasteboard,
        isEnabled: Bool,
        maximumContentBytes: Int = ClipboardPolicy.maximumContentBytes
    ) {
        self.pasteboard = pasteboard
        self.isEnabled = isEnabled
        self.maximumContentBytes = maximumContentBytes
        // A pasteboard that already held something when the session started is
        // not a copy the user made during it, so it is accounted for up front
        // rather than shipped on the first poll.
        lastAccountedChangeCount = isEnabled ? pasteboard.changeCount : 0
    }

    /// Turning sync on takes a fresh baseline of whatever is on the
    /// pasteboard at that moment, so a copy made while it was off is never
    /// sent, only a genuinely new one. Turning it off needs no
    /// bookkeeping: every path already guards on `isEnabled`. A no-op
    /// transition changes nothing, including the baseline.
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            lastAccountedChangeCount = pasteboard.changeCount
        }
    }

    /// What, if anything, the other machine should be told about the local
    /// pasteboard.
    public func poll() -> ClipboardSendDecision {
        guard isEnabled else {
            return .nothingToSend
        }
        let changeCount = pasteboard.changeCount
        guard changeCount != lastAccountedChangeCount else {
            return .nothingToSend
        }
        lastAccountedChangeCount = changeCount
        let readout = pasteboard.read()
        guard readout.hasItems else {
            return .nothingToSend
        }
        guard !readout.isExcludedByType else {
            return .refused(.excludedType)
        }
        let text: () -> ClipboardContent? = { readout.text.map(ClipboardContent.text) }
        let image: () -> ClipboardContent? = {
            readout.loadImage().map { ClipboardContent.image(format: $0.format, data: $0.data) }
        }
        let forms = ClipboardPolicy.prefersImage(firstItemTypeIdentifiers: readout.firstItemTypeIdentifiers)
            ? [image, text]
            : [text, image]
        var preferred: ClipboardContent?
        for form in forms {
            guard let content = form() else {
                continue
            }
            if content.byteCount <= maximumContentBytes {
                return .send(content)
            }
            preferred = preferred ?? content
        }
        guard let preferred else {
            return .refused(.unsupportedContent)
        }
        return .refused(.tooLarge(byteCount: preferred.byteCount, limit: maximumContentBytes))
    }

    /// Records whatever the pasteboard holds now as already dealt with, so it
    /// is never sent. The counterpart to the baseline taken in `init` for a
    /// caller that only becomes allowed to send later: everything copied up to
    /// this call belongs to the machine rather than to the session.
    public func accountForCurrentPasteboard() {
        guard isEnabled else {
            return
        }
        lastAccountedChangeCount = pasteboard.changeCount
    }

    /// Puts a clipboard received from the other machine onto this machine's
    /// pasteboard.
    /// The size limit is enforced here as well as at decode: a payload the
    /// wire somehow admitted still does not get written.
    public func apply(_ content: ClipboardContent) -> ClipboardApplyDecision {
        guard isEnabled else {
            return .refused(.syncDisabled)
        }
        guard content.byteCount <= maximumContentBytes else {
            return .refused(.tooLarge(byteCount: content.byteCount, limit: maximumContentBytes))
        }
        lastAccountedChangeCount = pasteboard.write(content)
        return .applied(description: content.logDescription, byteCount: content.byteCount)
    }
}

/// One session's clipboard: the engine, the gate that says whether this
/// session may touch the pasteboard at all, and the only place clipboard
/// outcomes are logged.
///
/// Main-actor isolated because both ends drive it from a main-actor poll task
/// and their receive loops, and because `NSPasteboard` behind the seam is UI
/// state.
@MainActor
public final class ClipboardSyncSession {
    private let engine: ClipboardSyncEngine
    private let isSessionAdmissible: @MainActor () -> Bool
    private let log: (@MainActor (String) -> Void)?
    private let onRefusal: (@MainActor (ClipboardRefusal) -> Void)?
    /// When the last received clipboard was written to the pasteboard, which
    /// is what `ClipboardPolicy.minimumApplyIntervalSeconds` is measured from.
    private var lastApplyNanoseconds: Int64?
    /// The newest clipboard that arrived inside the floor. One slot on
    /// purpose: a burst collapses to its newest member, so sustained inbound
    /// traffic costs one pending value and one timer however fast it arrives.
    private var pendingApply: ClipboardContent?
    private var pendingApplyTask: Task<Void, Never>?
    /// Whether a poll has ever found the gate open. Until one has, everything
    /// on the pasteboard predates the session — see `poll()`.
    private var hasEverBeenAdmissible = false

    public var isEnabled: Bool { engine.isEnabled }

    /// docs/ux-spec.md's live "Clipboard: on or off." Forwards to the
    /// engine, which owns what either transition means for the baseline.
    public func setEnabled(_ enabled: Bool) {
        engine.setEnabled(enabled)
    }

    /// `isSessionAdmissible` is the host's granted-session gate.
    /// It defaults to `true` for the client, where the gate is structural:
    /// the client only builds this after `connect()` has returned a signed
    /// canvas or a granted host screen, and tears it down when the session
    /// ends, so there is no pairing-only or pre-handshake state for it to
    /// exist in.
    ///
    /// `onRefusal` hears every refusal a person could act on, in either
    /// direction, alongside the log line. `syncDisabled` and
    /// `sessionNotActive` never reach it: they describe the session, not
    /// the copy.
    public init(
        engine: ClipboardSyncEngine,
        isSessionAdmissible: @escaping @MainActor () -> Bool = { true },
        log: (@MainActor (String) -> Void)? = nil,
        onRefusal: (@MainActor (ClipboardRefusal) -> Void)? = nil
    ) {
        self.engine = engine
        self.isSessionAdmissible = isSessionAdmissible
        self.log = log
        self.onRefusal = onRefusal
    }

    /// The packet to send, or `nil` when there is nothing to say. Never logs
    /// content — only kind, size, and outcome.
    public func poll() -> SensoriumTransportPacket? {
        guard isSessionAdmissible() else {
            // Absorb rather than ignore: the engine is built when the
            // connection is accepted, and a change it has not accounted for
            // by the time the gate opens would be sent by the first poll
            // after it — a credential copied during the handshake, shipped
            // once the handshake finished.
            engine.accountForCurrentPasteboard()
            return nil
        }
        guard hasEverBeenAdmissible else {
            // The gate can also open between two polls, in which case no
            // refused poll ever ran: a handshake completing inside one poll
            // interval is the ordinary case on a LAN. The first poll that
            // finds it open therefore takes the baseline itself, so what
            // predates the session is not sent whichever way the gate opened.
            hasEverBeenAdmissible = true
            engine.accountForCurrentPasteboard()
            return nil
        }
        switch engine.poll() {
        case .nothingToSend:
            return nil
        case let .refused(reason):
            log?("clipboard not sent: \(reason.logReason)")
            reportRefusal(reason)
            return nil
        case let .send(content):
            log?("clipboard sent: \(content.logDescription)")
            return .clipboard(content)
        }
    }

    /// Applies a clipboard the other machine sent. Writing it onto this
    /// machine's pasteboard is a real side effect, so it happens only for a
    /// session the gate admits — and no more often than
    /// `ClipboardPolicy.minimumApplyIntervalSeconds`, whatever the sending
    /// machine does.
    /// One inside the floor is held rather than written, and the newest one
    /// held is what lands when the floor expires.
    public func receive(_ content: ClipboardContent) {
        guard isSessionAdmissible() else {
            log?("clipboard refused: \(ClipboardRefusal.sessionNotActive.logReason) (\(content.logDescription))")
            return
        }
        guard let waitNanoseconds = nanosecondsUntilApplyAllowed() else {
            apply(content)
            return
        }
        let isFirstDeferral = pendingApply == nil
        pendingApply = content
        guard isFirstDeferral else {
            // A flush is already scheduled and will take whatever is in the
            // slot when it fires, so a burst neither reschedules nor logs.
            return
        }
        pendingApplyTask = Task { [weak self] in
            try? await Task.sleep(for: .nanoseconds(waitNanoseconds))
            guard !Task.isCancelled else {
                return
            }
            self?.flushPendingApply()
        }
    }

    /// How long the floor still has to run, or `nil` when an apply may happen
    /// now.
    /// Drops a clipboard held by the apply floor, so it never lands. Called
    /// when the session ends, so nothing from it is written afterwards.
    public func cancelPendingApply() {
        pendingApplyTask?.cancel()
        pendingApplyTask = nil
        pendingApply = nil
    }

    private func nanosecondsUntilApplyAllowed() -> Int64? {
        guard let lastApplyNanoseconds else {
            return nil
        }
        let floor = Int64(ClipboardPolicy.minimumApplyIntervalSeconds * 1_000_000_000)
        let elapsed = MonotonicClock.nowNanoseconds() - lastApplyNanoseconds
        guard elapsed < floor else {
            return nil
        }
        return floor - elapsed
    }

    /// Writes the newest clipboard held during the floor. The gate is checked
    /// again here, not just at arrival: a session that ended while the floor
    /// was running must not have the other machine's clipboard land on it
    /// afterwards.
    private func flushPendingApply() {
        pendingApplyTask = nil
        guard let content = pendingApply else {
            return
        }
        pendingApply = nil
        guard isSessionAdmissible() else {
            log?("clipboard refused: \(ClipboardRefusal.sessionNotActive.logReason) (\(content.logDescription))")
            return
        }
        apply(content)
    }

    private func apply(_ content: ClipboardContent) {
        lastApplyNanoseconds = MonotonicClock.nowNanoseconds()
        switch engine.apply(content) {
        case let .applied(description, _):
            log?("clipboard applied: \(description)")
        case let .refused(reason):
            log?("clipboard refused: \(reason.logReason) (\(content.logDescription))")
            reportRefusal(reason)
        }
    }

    private func reportRefusal(_ refusal: ClipboardRefusal) {
        switch refusal {
        case .syncDisabled, .sessionNotActive:
            return
        case .excludedType, .tooLarge, .unsupportedContent:
            onRefusal?(refusal)
        }
    }
}

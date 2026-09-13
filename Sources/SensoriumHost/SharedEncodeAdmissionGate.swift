import Foundation

/// A per-canvas scheduling weight, derived from the viewer's `viewerFocus`
/// report by `CanvasFocusTracker`. `.elevated` is the canvas the user is
/// actually looking at; every canvas is `.normal` whenever no focus has been
/// reported, which is the state an outdated viewer, or a viewer sitting in a local
/// app, leaves the host in.
public enum EncodeAdmissionPriority: Int, Comparable, Sendable {
    case normal = 0
    case elevated = 1

    public static func < (lhs: EncodeAdmissionPriority, rhs: EncodeAdmissionPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One pipeline's registration with a shared `SharedEncodeAdmissionGate`.
/// Constructible only via `SharedEncodeAdmissionGate.makeSource()`, so a
/// caller cannot forge another pipeline's identity and jump its fairness
/// turn.
public struct EncodeAdmissionSource: Hashable, Sendable {
    private let id = UUID()
    fileprivate init() {}
}

/// The result of `SharedEncodeAdmissionGate.request`.
public enum SharedEncodeAdmission: Equatable, Sendable {
    /// A slot was free; `submit` already ran, synchronously, before this
    /// returned.
    case admittedNow
    /// No slot was free; `submit` will run later, from a future
    /// `releaseSlot()` call, once this source's turn comes around.
    case pending
    /// `source` already had a request queued that had not yet been
    /// dispatched; that older request is discarded (counted as dropped) and
    /// replaced by this one. `EncodeAdmissionGate` never produces more than
    /// one outstanding request per source, so this only fires if that
    /// contract is violated — kept as a defined, counted outcome rather than
    /// an unbounded queue, exactly like `VideoFrameAdmissionQueue` does one
    /// layer up for a stale waiting frame.
    case replacedPendingRequest
}

/// Bounds how many frames may be concurrently submitted toward the shared
/// hardware video-encode engine **across every pipeline**, not just within
/// one. `EncodeAdmissionGate` (built on `VideoFrameAdmissionQueue`) already
/// bounds a single pipeline to one frame in flight, one waiting; that is
/// exactly why a second pipeline submitting at the same moment is invisible
/// to the first one's gate and vice versa — each only ever sees its own
/// single in-flight frame and has no way to know a sibling pipeline exists.
///
/// # Two bounds, not one
/// One instance of this type is created per session and owned by that
/// session's `HostSessionController`, bounding that session's own canvases
/// against each other and dying with the session. A session gate is in turn
/// chained to `machineGate`, the one process-wide instance, because the media
/// engines the bound is really about are a property of this machine, not of a
/// connection: N sessions each admitting `sessionCapacity` frames would be
/// `N * sessionCapacity` concurrent encodes, which is not what the numbers
/// below measured. A frame therefore takes a session slot first and a machine
/// slot second, and holds both until its encode finishes.
///
/// Splitting it this way is what makes a leaked slot recoverable. Every
/// increment is attributed to the `EncodeAdmissionSource` that caused it, so
/// `unregisterSource` — which a stopping pipeline always calls — hands back
/// exactly the slots that pipeline was holding, at both levels. A slot can no
/// longer outlive the pipeline that took it, which is the one failure a
/// process-wide count with no owner could never come back from.
///
/// Measured on this host, 1920x1200, deliberately worst-case content,
/// hardware acceleration verified per session:
///
/// | sessions | aggregate fps | encode p50 | p95 | dropped pre-encode |
/// |---|---|---|---|---|
/// | 1 | 58.9 | 9.6 ms | 14.5 ms | 0.2% |
/// | 2 | 106.4 | 13.0 ms | 36.3 ms | 9.8% |
/// | 3 | 151.4 | 24.4 ms | 37.0 ms | 14.4% |
///
/// Two concurrent sessions cost 13.0 ms p50 to encode, not the ~19.2 ms two
/// serialised encodes would cost: that is real hardware parallelism worth
/// keeping, so `machineCapacity` is never 1 — a bound of 1 would
/// serialise away exactly the concurrency this data proves is real. Three
/// sessions do not carry their own weight: 151.4 fps is only 1.42x the
/// two-session number for 1.5x the sessions, and the drop rate keeps
/// climbing (9.8% -> 14.4%) while p95 stops improving. Sensorium hard-caps a
/// session at two canvases, so `machineCapacity` matches exactly the
/// concurrency this product will ever ask for and that the data shows is
/// worth having.
///
/// # Fairness vs priority
/// The focused canvas is preferred, but not absolutely. Strict priority would
/// starve the unfocused canvas to a frozen picture whenever the focused one
/// keeps requesting — and the unfocused window is still on screen, so a frozen
/// one is a worse bug than a slightly slower focused one. The higher-priority
/// source therefore wins at most `maximumConsecutivePriorityWins` turns in a
/// row while a lower-priority one is waiting; the next turn goes to the
/// longest-waiting source below that priority. The unfocused canvas is
/// guaranteed one slot in every `maximumConsecutivePriorityWins + 1`.
///
/// With no focus reported every request carries `.normal`, no source is
/// outranked, and the order is plain earliest-waiting-first.
///
/// Priority travels with the request, so a session gate forwards it to the
/// machine gate unchanged, which is where contention actually is, since a
/// session's canvases can never exceed `sessionCapacity`. Sessions are not
/// ranked against each other; cross-session order is longest-waiting-first.
// `Frame` is deliberately not constrained to `Sendable`: `CMSampleBuffer`,
// the frame type this gate actually guards in production, has its own
// `Sendable` conformance explicitly marked unavailable by Core Media, so a
// `Frame: Sendable` bound here would make `SharedEncodeAdmissionGate<
// CMSampleBuffer>` impossible to name at all. The class is `@unchecked
// Sendable` in exchange, the same trade `CaptureFrameAdmission` already
// makes for the same type one file over.
public final class SharedEncodeAdmissionGate<Frame>: @unchecked Sendable {
    /// The bound on this machine's media engines, which every session shares. See
    /// the type-level doc comment for the measured argument.
    public static var machineCapacity: Int { 2 }

    /// The bound on one session's own concurrent encodes. Sensorium hard-caps
    /// a session at two canvases, and each canvas has at most one frame in
    /// flight, so this is the most a single session can ever ask for: it
    /// bounds nothing a correct session would not already respect, and exists
    /// so a session's slots have an owner that dies with the session. The real
    /// ceiling on concurrent encodes stays `machineCapacity`, which a session
    /// gate cannot raise — chaining only ever adds a constraint.
    public static var sessionCapacity: Int { 2 }

    /// How many turns in a row a higher-priority source may take while a
    /// lower-priority one is waiting.
    public static var maximumConsecutivePriorityWins: Int { 3 }

    private struct PendingRequest {
        let sampleBuffer: Frame
        let priority: EncodeAdmissionPriority
        let submit: @Sendable (Frame) -> Void
    }

    private let lock = NSLock()
    private let capacity: Int
    /// The next gate down, or `nil` for the machine-wide gate itself, which
    /// is the bottom of the chain.
    private let machineGate: SharedEncodeAdmissionGate<Frame>?
    private var inFlightCount = 0
    /// Which source holds each in-flight slot. The whole point of the split:
    /// `inFlightCount` alone cannot say who to give a slot back to when a
    /// pipeline stops, so a slot whose frame never reports back was
    /// unrecoverable. Its values sum to `inFlightCount`.
    private var inFlightBySource: [EncodeAdmissionSource: Int] = [:]
    /// Sources registered by `makeSource` and not yet unregistered. Used to
    /// tell a caller bug (a live source releasing a slot it does not hold)
    /// from an encoder callback that simply arrived after its pipeline was
    /// torn down, which is expected and must stay silent.
    private var liveSources: Set<EncodeAdmissionSource> = []
    /// This gate's own registration with `machineGate`, one per source rather
    /// than one per gate: the machine gate allows a single pending request
    /// per source, and this gate may have `capacity` frames wanting a machine
    /// slot at once. One machine source per local source keeps that one-to-one
    /// and stops two of a session's frames from displacing each other below.
    private var machineSourceBySource: [EncodeAdmissionSource: EncodeAdmissionSource] = [:]
    private var pendingBySource: [EncodeAdmissionSource: PendingRequest] = [:]
    /// Arrival order of sources currently waiting. A source is appended the
    /// first time it gets a pending entry and removed once dispatched, so a
    /// later re-insertion always puts it back at the end of the line — the
    /// mechanism that stops one eager source from winning every race for a
    /// freed slot merely by re-requesting faster than a sibling.
    private var fairnessOrder: [EncodeAdmissionSource] = []
    private var droppedFrameCountValue = 0
    private var unbalancedReleaseCountValue = 0
    /// Turns the highest-priority waiting source has taken in a row while a
    /// lower-priority one was waiting. Bounds preference so the unfocused
    /// canvas keeps reaching the encoder instead of freezing.
    private var consecutivePriorityWins = 0

    /// `machineGate` is the shared bound every session gate defers to. It is
    /// `nil` only for the machine-wide gate itself; a session gate built
    /// without one bounds its own session and nothing else, which is what a
    /// test driving one gate in isolation wants and never what production
    /// wants.
    public init(capacity: Int, machineGate: SharedEncodeAdmissionGate<Frame>? = nil) {
        self.capacity = max(1, capacity)
        self.machineGate = machineGate
    }

    /// Hands every machine slot and registration this gate still holds back to
    /// the machine gate. A session gate is the last owner of its sources, so
    /// without this a session that ended while a frame was in flight would
    /// leave that machine slot held for the life of the process — the exact
    /// leak the per-source accounting exists to make impossible.
    deinit {
        guard let machineGate else {
            return
        }
        for machineSource in machineSourceBySource.values {
            machineGate.unregisterSource(machineSource)
        }
    }

    public var droppedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return droppedFrameCountValue
    }

    /// Slots currently held by an admitted frame. Zero once every admission
    /// has been released; a value that never returns to zero while nothing is
    /// encoding is a leaked slot.
    public var framesInFlight: Int {
        lock.lock()
        defer { lock.unlock() }
        return inFlightCount
    }

    /// Releases that arrived with no admission to match. Always zero in a
    /// correct caller; nonzero means a frame's slot was released twice, which
    /// would otherwise raise this gate's real bound above `capacity` for the
    /// life of the process.
    public var unbalancedReleaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return unbalancedReleaseCountValue
    }

    /// Registers a new pipeline with the gate. Call once per pipeline and
    /// keep the returned token for every subsequent call.
    public func makeSource() -> EncodeAdmissionSource {
        let source = EncodeAdmissionSource()
        // Minted outside the lock: the machine gate takes its own lock, and
        // nothing here needs the two held at once.
        let machineSource = machineGate?.makeSource()
        lock.lock()
        liveSources.insert(source)
        if let machineSource {
            machineSourceBySource[source] = machineSource
        }
        lock.unlock()
        return source
    }

    /// Removes `source` from the gate, giving back every slot it holds:
    /// any request of its still queued and waiting for one (dropped and
    /// counted), and any it is genuinely in flight with. Call when a pipeline
    /// stops, so neither an abandoned frame's fairness turn nor its slot
    /// outlives the output that will now never exist.
    ///
    /// The in-flight half is what a bare count could never do. The encoder may
    /// still call back for a frame that was in flight here; that release
    /// arrives for a source no longer live, and `releaseSlot` ignores it
    /// rather than double-freeing this slot.
    ///
    /// Returns whether a pending request was actually dropped — an in-flight
    /// slot handed back is not a dropped frame, because its frame may yet
    /// encode successfully.
    @discardableResult
    public func unregisterSource(_ source: EncodeAdmissionSource) -> Bool {
        lock.lock()
        fairnessOrder.removeAll { $0 == source }
        var droppedPending = false
        if pendingBySource.removeValue(forKey: source) != nil {
            droppedFrameCountValue += 1
            droppedPending = true
        }
        liveSources.remove(source)
        let machineSource = machineSourceBySource.removeValue(forKey: source)
        let held = inFlightBySource.removeValue(forKey: source) ?? 0
        inFlightCount -= held
        var dispatches: [Dispatch] = []
        for _ in 0..<held {
            guard let dispatch = claimFreedSlotLocked() else {
                break
            }
            dispatches.append(dispatch)
        }
        lock.unlock()
        if let machineSource {
            machineGate?.unregisterSource(machineSource)
        }
        for dispatch in dispatches {
            forward(dispatch)
        }
        return droppedPending
    }

    /// Requests permission for `source` to submit `sampleBuffer`. If a slot
    /// is free, `submit` runs synchronously, before this call returns. If
    /// not, `source`'s single pending slot holds this request until
    /// `releaseSlot()` dispatches it — bounded by the number of registered
    /// sources, since each source can only ever have one request pending at
    /// a time, never an unbounded backlog.
    @discardableResult
    public func request(
        source: EncodeAdmissionSource,
        sampleBuffer: Frame,
        priority: EncodeAdmissionPriority = .normal,
        submit: @escaping @Sendable (Frame) -> Void
    ) -> SharedEncodeAdmission {
        lock.lock()
        if inFlightCount < capacity {
            inFlightCount += 1
            inFlightBySource[source, default: 0] += 1
            let machineSource = machineSourceBySource[source]
            lock.unlock()
            // This gate's slot is held from here on; the machine gate decides
            // whether the frame runs now or waits for hardware. Either way
            // exactly one terminal `releaseSlot(source:)` gives both back.
            return forward(
                Dispatch(
                    source: source,
                    machineSource: machineSource,
                    request: PendingRequest(sampleBuffer: sampleBuffer, priority: priority, submit: submit)
                )
            )
        }
        let replaced = pendingBySource.updateValue(
            PendingRequest(sampleBuffer: sampleBuffer, priority: priority, submit: submit),
            forKey: source
        ) != nil
        if replaced {
            droppedFrameCountValue += 1
        } else {
            fairnessOrder.append(source)
        }
        lock.unlock()
        return replaced ? .replacedPendingRequest : .pending
    }

    /// Call once a frame admitted by `request` has actually finished —
    /// either the encoder's own completion, or an immediate synchronous
    /// submission failure treated the same way. Frees one slot and,
    /// if any source is waiting, immediately regrants it to whichever
    /// waiting source has the highest priority, breaking ties by whoever has
    /// been waiting longest.
    /// `source` must be the one that was admitted: a slot belongs to a
    /// pipeline, and only a release that names it can be told from a stray
    /// one.
    ///
    /// An unmatched release is clamped and counted rather than allowed
    /// through: an unclamped decrement raises the real bound above `capacity`
    /// for as long as the gate lives, silently. It is clamped and reported
    /// rather than a `precondition`, because a live remote session is the one
    /// thing the operator cannot get back by restarting, and a clamped count
    /// still streams correctly — the frames already encoding finish, the
    /// bound still holds, and `unbalancedReleaseCount` names the bug loudly
    /// enough to find it.
    ///
    /// A release from a source that has already been unregistered is neither:
    /// it is the encoder answering for a frame whose pipeline stopped
    /// underneath it, `unregisterSource` already returned that slot, and there
    /// is nothing left to do but ignore it. That is a routine consequence of
    /// tearing a session down, not a caller bug, so it is not counted as one.
    public func releaseSlot(source: EncodeAdmissionSource) {
        lock.lock()
        let held = inFlightBySource[source] ?? 0
        let released = held > 0
        let unbalanced = !released && liveSources.contains(source)
        if released {
            if held == 1 {
                inFlightBySource.removeValue(forKey: source)
            } else {
                inFlightBySource[source] = held - 1
            }
            inFlightCount -= 1
        } else if unbalanced {
            unbalancedReleaseCountValue += 1
        }
        let machineSource = machineSourceBySource[source]
        let dispatch = released ? claimFreedSlotLocked() : nil
        lock.unlock()
        if unbalanced {
            print("Sensorium host: encode admission slot released without a matching admission -- clamped at zero")
        }
        if released, let machineSource {
            // The machine slot this frame was holding, freed before the next
            // waiting frame of this gate's asks for one: the hardware is idle
            // either way, and this order lets a sibling session that has been
            // waiting longer take it rather than always losing to whichever
            // gate happened to free it.
            machineGate?.releaseSlot(source: machineSource)
        }
        if let dispatch {
            forward(dispatch)
        }
    }

    private struct Dispatch {
        let source: EncodeAdmissionSource
        let machineSource: EncodeAdmissionSource?
        let request: PendingRequest
    }

    /// Gives the slot just freed to whichever waiting source should have it,
    /// marking that slot held by the new source before it is handed out so no
    /// other caller can take it in between. Must be called with `lock` held.
    private func claimFreedSlotLocked() -> Dispatch? {
        guard let index = nextPendingIndexLocked() else {
            return nil
        }
        let source = fairnessOrder.remove(at: index)
        guard let entry = pendingBySource.removeValue(forKey: source) else {
            return nil
        }
        inFlightCount += 1
        inFlightBySource[source, default: 0] += 1
        return Dispatch(source: source, machineSource: machineSourceBySource[source], request: entry)
    }

    /// Takes a frame that already holds a slot here down to the machine gate,
    /// or straight to the encoder when this gate is the machine gate. Never
    /// called with `lock` held: everything below runs the caller's `submit`.
    @discardableResult
    private func forward(_ dispatch: Dispatch) -> SharedEncodeAdmission {
        guard let machineGate, let machineSource = dispatch.machineSource else {
            dispatch.request.submit(dispatch.request.sampleBuffer)
            return .admittedNow
        }
        let admission = machineGate.request(
            source: machineSource,
            sampleBuffer: dispatch.request.sampleBuffer,
            priority: dispatch.request.priority,
            submit: dispatch.request.submit
        )
        if admission == .replacedPendingRequest {
            // One machine source per local source means the machine gate can
            // only see a second pending request from this frame's source if
            // the one-outstanding-request contract was broken above. The
            // displaced frame will never reach an encoder and so will never
            // report back, so its slot here has to be given back now.
            releaseSlot(source: dispatch.source)
        }
        return admission
    }

    private func nextPendingIndexLocked() -> Int? {
        var bestIndex: Int?
        var bestPriority: EncodeAdmissionPriority?
        for (index, source) in fairnessOrder.enumerated() {
            guard let entry = pendingBySource[source] else { continue }
            if bestPriority == nil || entry.priority > bestPriority! {
                bestPriority = entry.priority
                bestIndex = index
            }
        }
        guard let bestIndex, let bestPriority else {
            return nil
        }
        // Nothing is being displaced: either one source is waiting, or every
        // waiting source carries the same priority, which is the state a host
        // that never received a focus report is permanently in. `bestIndex`
        // is then the earliest waiting source, exactly as plain fair share.
        guard let floorIndex = longestWaitingIndexLocked(below: bestPriority) else {
            consecutivePriorityWins = 0
            return bestIndex
        }
        guard consecutivePriorityWins < Self.maximumConsecutivePriorityWins else {
            consecutivePriorityWins = 0
            return floorIndex
        }
        consecutivePriorityWins += 1
        return bestIndex
    }

    /// The earliest-waiting source ranked below `priority`, or `nil` when no
    /// source is being outranked at all. Must be called with `lock` held.
    private func longestWaitingIndexLocked(below priority: EncodeAdmissionPriority) -> Int? {
        for (index, source) in fairnessOrder.enumerated() {
            guard let entry = pendingBySource[source], entry.priority < priority else { continue }
            return index
        }
        return nil
    }
}

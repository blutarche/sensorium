import CoreMedia
import SensoriumCore

/// Wraps a raw capture sample buffer for `VideoFrameAdmissionQueue`. Nothing
/// pre-encode is a recovery point yet — `VTCompressionSessionEncodeFrame`
/// decides what kind of frame this becomes — so `isKeyFrame` is always
/// `false` and the newest capture always displaces a stale waiting one.
@available(macOS 13.0, *)
struct CaptureFrameAdmission: VideoFrameAdmissible, @unchecked Sendable {
    let sampleBuffer: CMSampleBuffer
    var isKeyFrame: Bool { false }
}

/// A dropped frame here never reached the encoder, so nothing downstream
/// can depend on it.
@available(macOS 13.0, *)
public final class EncodeAdmissionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var queue = VideoFrameAdmissionQueue<CaptureFrameAdmission>()
    private let latencyRecorder: HostMediaLatencyRecorder?
    /// This session's admission gate, which in turn defers to the machine-wide
    /// one. Bounds total frames in flight toward the encoder across every
    /// pipeline, not just this one — see `SharedEncodeAdmissionGate` for why a
    /// per-pipeline bound alone is not enough once a second canvas exists, and
    /// why the session's gate is not the whole bound either.
    private let sessionGate: SharedEncodeAdmissionGate<CMSampleBuffer>
    /// Set by `shutDown`. After it, this gate holds no registration with the
    /// session gate, so nothing more may be submitted through it: a frame
    /// admitted against a slot nothing will ever release is precisely the leak
    /// the teardown exists to prevent.
    private var isShutDown = false
    private let sessionSource: EncodeAdmissionSource
    /// Which canvas this pipeline serves, and the session's shared view of
    /// which canvas the viewer is looking at. Together they decide whether
    /// this pipeline's frames are preferred when both canvases contend for
    /// the one hardware encoder.
    private let surface: CanvasSurfaceID
    private let focus: CanvasFocusTracker
    /// Set once the encoder exists, after this gate is constructed: the
    /// encoder's own compressed-output callback is created before the
    /// encoder instance it belongs to, so it cannot capture `encoder`
    /// directly. It calls back into this gate instead.
    public weak var encoder: (any VideoFrameEncoding)?
    /// Where a successfully encoded frame goes next. Owned here, rather than
    /// wired straight into the encoder by the caller, so the slot release
    /// below sits on the one path every outcome takes and cannot be left out
    /// of some future caller's own output handler.
    private let encodedFrameHandler: @Sendable (CMSampleBuffer) -> Void

    public init(
        latencyRecorder: HostMediaLatencyRecorder?,
        sessionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
        surface: CanvasSurfaceID = CanvasSurfaceID.allCases[0],
        focus: CanvasFocusTracker = CanvasFocusTracker(),
        encodedFrameHandler: @escaping @Sendable (CMSampleBuffer) -> Void
    ) {
        self.latencyRecorder = latencyRecorder
        self.encodedFrameHandler = encodedFrameHandler
        self.sessionGate = sessionGate
        self.sessionSource = sessionGate.makeSource()
        self.surface = surface
        self.focus = focus
    }

    /// Ends this pipeline's use of the session gate, handing back the slot it
    /// holds and refusing anything further. Call from the pipeline's own stop;
    /// `deinit` calls it too, for a pipeline dropped without one, but a stop
    /// is the predictable point — ARC frees this object whenever the encoder's
    /// last callback happens to let go of it, which may be well after the
    /// session ended.
    ///
    /// Idempotent, and safe to race with a callback still on its way in: a
    /// later `frameFinished` releases against a source the gate no longer
    /// knows, which it ignores.
    public func shutDown() {
        lock.lock()
        let wasShutDown = isShutDown
        isShutDown = true
        lock.unlock()
        guard !wasShutDown else {
            return
        }
        if sessionGate.unregisterSource(sessionSource) {
            latencyRecorder?.recordGlobalEncoderInputDrop(surface: surface)
        }
    }

    deinit {
        shutDown()
    }

    public var droppedFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queue.droppedFrameCount
    }

    /// Call from the capture callback for every admitted frame (not only
    /// `.complete` status — the caller already filters that).
    ///
    /// `false` when this frame was not taken: the gate has shut down, or a
    /// newer frame is already waiting and this one is worth less than it.
    /// Capture itself has nothing to do about either, which is why the result
    /// is discardable.
    @discardableResult
    public func admit(_ sampleBuffer: CMSampleBuffer) -> Bool {
        lock.lock()
        guard !isShutDown else {
            lock.unlock()
            // Capture stops asynchronously, so a frame or two can still arrive
            // after teardown. Counted, not silently dropped, and never
            // submitted: this pipeline has no slot to hold it with any more.
            latencyRecorder?.recordEncoderInputDrop(surface: surface)
            return false
        }
        let admission = queue.enqueue(CaptureFrameAdmission(sampleBuffer: sampleBuffer))
        lock.unlock()
        switch admission {
        case .sendNow:
            submit(sampleBuffer)
            return true
        case .replacedStaleFrame:
            // This frame is the one now waiting; the older one it displaced is
            // what was dropped.
            latencyRecorder?.recordEncoderInputDrop(surface: surface)
            return true
        case .droppedIncoming:
            latencyRecorder?.recordEncoderInputDrop(surface: surface)
            return false
        case .queued:
            return true
        }
    }

    /// The encoder's single terminal callback for a frame this gate
    /// submitted. Every outcome releases the slot, a dropped or failed frame
    /// included: the slot is shared with this session's other canvas and
    /// with the whole machine, so a missed release retires it until this
    /// pipeline stops, with no error anywhere. Hence the `defer`.
    public func frameFinished(_ outcome: VideoEncodeOutcome) {
        defer { encodeCompleted() }
        switch outcome {
        case .encoded(let sampleBuffer):
            encodedFrameHandler(sampleBuffer)
        case .dropped:
            latencyRecorder?.recordEncoderOutputDrop(surface: surface)
        case .failed(let status):
            latencyRecorder?.recordEncodeSubmissionFailure(status: status, surface: surface)
            print("Sensorium host: video encode failed status=\(status)")
        }
    }

    /// The frame holding this pipeline's in-flight slot has finished, so
    /// whatever capture is waiting may now go in. Also releases that frame's
    /// session slot — `releaseSlot()` runs first so an already-waiting
    /// sibling pipeline gets first refusal at it, before this pipeline's own
    /// next frame (if any) re-requests one.
    private func encodeCompleted() {
        lock.lock()
        let next = queue.completeSend()
        let isShutDown = isShutDown
        lock.unlock()
        sessionGate.releaseSlot(source: sessionSource)
        guard let next else {
            return
        }
        guard !isShutDown else {
            latencyRecorder?.recordEncoderInputDrop(surface: surface)
            return
        }
        submit(next.sampleBuffer)
    }

    /// Asks the session gate for permission to actually submit
    /// `sampleBuffer` to the encoder. `encodeNow` runs synchronously if a
    /// session slot is free now, or later, from a sibling pipeline's
    /// `releaseSlot()`, once this pipeline's turn comes around.
    private func submit(_ sampleBuffer: CMSampleBuffer) {
        let admission = sessionGate.request(
            source: sessionSource,
            sampleBuffer: sampleBuffer,
            priority: focus.encodePriority(for: surface)
        ) { [weak self] admitted in
            self?.encodeNow(admitted)
        }
        if admission == .replacedPendingRequest {
            latencyRecorder?.recordGlobalEncoderInputDrop(surface: surface)
        }
    }

    /// Every exit from here either hands the frame to an encoder that will
    /// answer with exactly one `frameFinished`, or releases the slot itself:
    /// no path leaves a slot held by a frame nothing will ever report on.
    private func encodeNow(_ sampleBuffer: CMSampleBuffer) {
        guard let encoder else {
            // The encoder is held weakly and is already gone, so no callback
            // will ever arrive for this frame. Releasing here is the only
            // chance this slot gets.
            latencyRecorder?.recordEncoderOutputDrop(surface: surface)
            encodeCompleted()
            return
        }
        if let presentationTime = CMSampleBufferPresentationTiming.nanoseconds(sampleBuffer) {
            latencyRecorder?.recordEncodeSubmit(
                surface: surface,
                presentationTimeNanoseconds: presentationTime,
                atNanoseconds: MonotonicClock.nowNanoseconds()
            )
        }
        do {
            try encoder.encode(sampleBuffer)
        } catch let VideoEncoderError.frameSubmissionFailed(status) {
            latencyRecorder?.recordEncodeSubmissionFailure(status: status, surface: surface)
            print("Sensorium host: video encode submission failed status=\(status)")
            // VideoToolbox will never call the output callback for a frame it
            // refused synchronously, so this slot must be released here or the
            // gate would stall forever.
            encodeCompleted()
        } catch {
            print("Sensorium host: video encode submission failed \(error)")
            encodeCompleted()
        }
    }
}

/// Swift does not allow a generic type's extension to add a stored property
/// — even one constrained to a single concrete `Frame` — so the actual
/// process-wide instance lives at file scope; `machineWide` below only exposes
/// it. A top-level `let` is initialised at most once, lazily, the first time
/// anything reads it, and that initialisation is already thread-safe.
private let machineWideCMSampleBufferGate = SharedEncodeAdmissionGate<CMSampleBuffer>(
    capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.machineCapacity
)

extension SharedEncodeAdmissionGate where Frame == CMSampleBuffer {
    /// The bound on this machine's media engines. Process-wide on purpose, and
    /// the one gate that legitimately is: the hardware it stands for belongs
    /// to the machine, so sessions must contend for it rather than each
    /// getting their own copy of it. Every *session* gate is per session and
    /// supplied by its owner instead — see `HostSessionController`. Tests that
    /// need to observe a bound in isolation construct their own instances.
    public static var machineWide: SharedEncodeAdmissionGate<CMSampleBuffer> { machineWideCMSampleBufferGate }
}

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Split out of main.swift, mechanically -- see docs/testing.md.
@MainActor
func runCoreSessionTestsPart3(_ fixtures: CoreSessionSharedFixtures) async {
    let surfaceZero = fixtures.surfaceZero!
    let surfaceOne = fixtures.surfaceOne!
    let tlsIdentity = fixtures.tlsIdentity!
        // Requirement: two pipelines sharing one gate never exceed the
        // global in-flight bound, and the bound genuinely allows real
        // concurrency rather than accidentally serialising two encoders the
        // benchmark proves run concurrently -- driven with real, concurrently
        // running threads, not sequential calls that merely touch a shared
        // counter.
        do {
            final class ConcurrencyObserver: @unchecked Sendable {
                private let lock = NSLock()
                private var active = 0
                private(set) var peakActive = 0
                private(set) var observedConcurrency = false

                func enter() {
                    lock.lock()
                    active += 1
                    if active > peakActive { peakActive = active }
                    if active > 1 { observedConcurrency = true }
                    lock.unlock()
                }

                func exit() {
                    lock.lock()
                    active -= 1
                    lock.unlock()
                }
            }

            func driveSharedGateSource(
                _ gate: SharedEncodeAdmissionGate<Int>,
                source: EncodeAdmissionSource,
                frameCount: Int,
                observer: ConcurrencyObserver,
                group: DispatchGroup
            ) {
                group.enter()
                DispatchQueue.global().async {
                    for frame in 0..<frameCount {
                        let done = DispatchSemaphore(value: 0)
                        _ = gate.request(source: source, sampleBuffer: frame) { _ in
                            observer.enter()
                            // Holds the slot briefly so a genuinely
                            // concurrent sibling submission has time to land
                            // while this one is still "in flight" -- a real
                            // VTCompressionSessionEncodeFrame call, not an
                            // instantaneous one, is exactly what the
                            // benchmark's 13.0ms/36.3ms p50/p95 measured.
                            Thread.sleep(forTimeInterval: 0.002)
                            observer.exit()
                            gate.releaseSlot(source: source)
                            done.signal()
                        }
                        done.wait()
                    }
                    group.leave()
                }
            }

            let capacity = SharedEncodeAdmissionGate<Int>.machineCapacity
            expect(capacity == 2, "the machine-wide bound matches Sensorium's hard two-canvas cap")
            let gate = SharedEncodeAdmissionGate<Int>(capacity: capacity)
            let sourceA = gate.makeSource()
            let sourceB = gate.makeSource()
            let observer = ConcurrencyObserver()
            let group = DispatchGroup()

            driveSharedGateSource(gate, source: sourceA, frameCount: 40, observer: observer, group: group)
            driveSharedGateSource(gate, source: sourceB, frameCount: 40, observer: observer, group: group)
            // `DispatchGroup.wait()` is unavailable directly inside an
            // `async` function; a plain synchronous helper is allowed to
            // call it, and this really does need to block until both real
            // background threads finish, not yield to other async work.
            func waitSynchronously(_ group: DispatchGroup) {
                group.wait()
            }
            waitSynchronously(group)

            expect(observer.peakActive <= capacity, "the shared gate never let more submissions run concurrently than the global bound")
            expect(observer.observedConcurrency, "two sources sharing the gate really did overlap -- the bound is not accidentally serialising them down to one")
            expect(
                gate.droppedFrameCount == 0,
                "well-behaved sources -- one outstanding request each, as EncodeAdmissionGate guarantees -- never trigger a global drop"
            )
        }

        // A release with no matching admission must never drive the shared
        // in-flight count below zero. The count is process-wide and nothing
        // recovers a corrupt value, so a stray release silently raising the
        // real bound above `capacity` -- or a leaked admission silently
        // lowering it to nothing -- wedges every future session instead of
        // failing where it happened.
        do {
            let gate = SharedEncodeAdmissionGate<Int>(capacity: 1)
            let first = gate.makeSource()
            let second = gate.makeSource()
            nonisolated(unsafe) var admitted: [Int] = []
            gate.releaseSlot(source: first)
            expect(gate.framesInFlight == 0, "an unmatched release is clamped at zero rather than going negative")
            expect(gate.unbalancedReleaseCount == 1, "the unmatched release is reported, not silently absorbed")
            expect(
                gate.request(source: first, sampleBuffer: 1, submit: { admitted.append($0) }) == .admittedNow,
                "a gate that took a stray release still admits the first real frame"
            )
            expect(
                gate.request(source: second, sampleBuffer: 2, submit: { admitted.append($0) }) == .pending,
                "a stray release must not raise the real bound above the gate's capacity"
            )
            expect(admitted == [1], "only the one frame the capacity allows actually ran")
        }

        // Every frame submitted to the encoder must release its global
        // admission slot exactly once, whatever terminal outcome VideoToolbox
        // produces for it. The slot is process-wide and nothing recovers a
        // leaked one, so an outcome that skips the release does not slow the
        // picture down -- it stops every session on this host, permanently,
        // with no error anywhere. These drive `EncodeAdmissionGate` itself,
        // against a fake encoder standing in at the one seam the real
        // `VideoToolboxEncoder` occupies, since no runner may create a real
        // `VTCompressionSession`.
        do {
            let surface = CanvasSurfaceID.allCases[0]

            func makeGate(
                _ sessionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
                recorder: HostMediaLatencyRecorder,
                encoder: FakeFrameEncoder?,
                encodedFrameHandler: @escaping @Sendable (CMSampleBuffer) -> Void = { _ in }
            ) -> EncodeAdmissionGate {
                let gate = EncodeAdmissionGate(
                    latencyRecorder: recorder,
                    sessionGate: sessionGate,
                    surface: surface,
                    encodedFrameHandler: encodedFrameHandler
                )
                gate.encoder = encoder
                return gate
            }

            // A frame VideoToolbox reports with a failing status.
            do {
                let sessionGate = SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 1)
                let recorder = HostMediaLatencyRecorder()
                let encoder = FakeFrameEncoder()
                let gate = makeGate(sessionGate, recorder: recorder, encoder: encoder)
                for _ in 0..<5 {
                    gate.admit(makeCaptureSampleBuffer())
                    gate.frameFinished(.failed(-12902))
                }
                expect(encoder.submissionCount == 5, "an errored frame releases its slot, so the frames after it still reach the encoder")
                expect(sessionGate.framesInFlight == 0, "no slot is left in flight once every errored frame has finished")
                expect(
                    recorder.frameCounts(for: surface).encodeSubmissionFailures == 5,
                    "a frame the encoder failed is counted, not silently discarded"
                )
            }

            // A frame VideoToolbox drops: `noErr`, no sample buffer.
            do {
                let sessionGate = SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 1)
                let recorder = HostMediaLatencyRecorder()
                let encoder = FakeFrameEncoder()
                let gate = makeGate(sessionGate, recorder: recorder, encoder: encoder)
                for _ in 0..<5 {
                    gate.admit(makeCaptureSampleBuffer())
                    gate.frameFinished(.dropped)
                }
                expect(encoder.submissionCount == 5, "a dropped frame releases its slot, so the frames after it still reach the encoder")
                expect(sessionGate.framesInFlight == 0, "no slot is left in flight once every dropped frame has finished")
                expect(
                    recorder.frameCounts(for: surface).encoderOutputDropped == 5,
                    "a frame the encoder dropped is counted rather than vanishing between capture and output"
                )
            }

            // A frame VideoToolbox refuses synchronously never produces a
            // callback at all, so the submission path itself has to release.
            do {
                let sessionGate = SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 1)
                let recorder = HostMediaLatencyRecorder()
                let encoder = FakeFrameEncoder()
                encoder.submissionFailureStatus = -12902
                let gate = makeGate(sessionGate, recorder: recorder, encoder: encoder)
                for _ in 0..<5 {
                    gate.admit(makeCaptureSampleBuffer())
                }
                expect(encoder.submissionCount == 5, "a synchronous refusal releases its slot, so later frames are still submitted")
                expect(sessionGate.framesInFlight == 0, "a refused submission leaves nothing in flight")
                expect(
                    recorder.frameCounts(for: surface).encodeSubmissionFailures == 5,
                    "every refused submission is counted"
                )
            }

            // The encoder is held weakly: a pipeline torn down between
            // admission and submission produces no callback either.
            do {
                let sessionGate = SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 1)
                let recorder = HostMediaLatencyRecorder()
                let gate = makeGate(sessionGate, recorder: recorder, encoder: nil)
                gate.admit(makeCaptureSampleBuffer())
                expect(sessionGate.framesInFlight == 0, "a frame with no encoder left to submit to releases its slot instead of leaking it")
                expect(
                    recorder.frameCounts(for: surface).encoderOutputDropped == 1,
                    "a frame that can never produce output is counted as an encoder-side drop"
                )
            }

            // Successes interleaved with drops and errors: the count must
            // quiesce at exactly zero, not merely stay under capacity.
            do {
                let sessionGate = SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 1)
                let recorder = HostMediaLatencyRecorder()
                let encoder = FakeFrameEncoder()
                nonisolated(unsafe) var encodedFrames = 0
                let gate = makeGate(sessionGate, recorder: recorder, encoder: encoder, encodedFrameHandler: { _ in encodedFrames += 1 })
                for index in 0..<12 {
                    let sampleBuffer = makeCaptureSampleBuffer(presentationTimeNanoseconds: Int64(index) * 16_000_000)
                    gate.admit(sampleBuffer)
                    switch index % 3 {
                    case 0: gate.frameFinished(.encoded(sampleBuffer))
                    case 1: gate.frameFinished(.dropped)
                    default: gate.frameFinished(.failed(-12902))
                    }
                }
                expect(encoder.submissionCount == 12, "every mixed-outcome frame reached the encoder")
                expect(encodedFrames == 4, "only the successfully encoded frames were handed onward")
                expect(sessionGate.framesInFlight == 0, "a mixed run of successes, drops and errors quiesces at exactly zero in flight")
                expect(sessionGate.unbalancedReleaseCount == 0, "no outcome released a slot it did not hold")
                let counts = recorder.frameCounts(for: surface)
                expect(
                    counts.encoderOutputDropped == 4 && counts.encodeSubmissionFailures == 4,
                    "both failure kinds stay visible in the counters: 4 dropped, 4 failed"
                )
            }

            // Reporting a second terminal outcome for one frame is a caller
            // bug that must be detected where it happens rather than raising
            // the process-wide bound for good.
            do {
                let sessionGate = SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 1)
                let recorder = HostMediaLatencyRecorder()
                let encoder = FakeFrameEncoder()
                let gate = makeGate(sessionGate, recorder: recorder, encoder: encoder)
                let sampleBuffer = makeCaptureSampleBuffer()
                gate.admit(sampleBuffer)
                gate.frameFinished(.encoded(sampleBuffer))
                gate.frameFinished(.encoded(sampleBuffer))
                expect(sessionGate.framesInFlight == 0, "a double release is clamped at zero rather than driving the count negative")
                expect(sessionGate.unbalancedReleaseCount == 1, "the double release is reported")
            }

            // The production bound: two pipelines encode concurrently, a
            // third waits -- unchanged by the release fix above.
            do {
                let capacity = SharedEncodeAdmissionGate<CMSampleBuffer>.machineCapacity
                let sessionGate = SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: capacity)
                let recorder = HostMediaLatencyRecorder()
                let encoders = [FakeFrameEncoder(), FakeFrameEncoder(), FakeFrameEncoder()]
                let gates = encoders.map { makeGate(sessionGate, recorder: recorder, encoder: $0) }
                let buffers = (0..<3).map { _ in makeCaptureSampleBuffer() }
                for (index, gate) in gates.enumerated() {
                    gate.admit(buffers[index])
                }
                expect(
                    encoders.map(\.submissionCount) == [1, 1, 0],
                    "exactly two frames encode concurrently under the production bound; the third waits its turn"
                )
                expect(sessionGate.framesInFlight == capacity, "both slots are held while two frames are in flight")
                gates[0].frameFinished(.dropped)
                expect(
                    encoders.map(\.submissionCount) == [1, 1, 1],
                    "the freed slot goes to the waiting pipeline, even though the frame that freed it was dropped"
                )
            }

            // An admission gate belongs to a session now, not to the process.
            // Two of them chain to the one machine-wide gate, which is what
            // the measured bound is actually about: the Mini's media engines
            // are shared however many sessions exist, but their *accounting*
            // must not be, or a slot leaked by one session is a slot every
            // later session has permanently lost.
            func makeSessionGate(
                _ machineGate: SharedEncodeAdmissionGate<CMSampleBuffer>
            ) -> SharedEncodeAdmissionGate<CMSampleBuffer> {
                SharedEncodeAdmissionGate(
                    capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity,
                    machineGate: machineGate
                )
            }

            // Two sessions do not share admission state: neither one's frame
            // is queued behind the other's while the hardware has room.
            do {
                let machineGate = SharedEncodeAdmissionGate<CMSampleBuffer>(
                    capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.machineCapacity
                )
                let firstSession = makeSessionGate(machineGate)
                let secondSession = makeSessionGate(machineGate)
                let recorder = HostMediaLatencyRecorder()
                let firstEncoder = FakeFrameEncoder()
                let secondEncoder = FakeFrameEncoder()
                let first = makeGate(firstSession, recorder: recorder, encoder: firstEncoder)
                let second = makeGate(secondSession, recorder: recorder, encoder: secondEncoder)
                first.admit(makeCaptureSampleBuffer())
                second.admit(makeCaptureSampleBuffer())
                // A slot is held by a live pipeline, so it may only be
                // observed while one is live: `EncodeAdmissionGate.deinit`
                // hands its slots back, and once the last strong reference to
                // a pipeline is the one this scope has already finished using,
                // ARC is free to run that `deinit` before the next line. A
                // release build does exactly that and reads an empty gate; a
                // debug build keeps every binding to end of scope and hides
                // it.
                withExtendedLifetime((first, second, firstSession, secondSession)) {
                    expect(
                        firstEncoder.submissionCount == 1 && secondEncoder.submissionCount == 1,
                        "a second session's frame is not held up by a first session's in-flight one while the machine has a slot free"
                    )
                    expect(
                        firstSession.framesInFlight == 1 && secondSession.framesInFlight == 1,
                        "each session accounts for its own frame and only its own"
                    )
                    expect(machineGate.framesInFlight == 2, "the machine gate is the only place the two sessions meet")
                }
            }

            // The machine-wide bound is still enforced across sessions: per-
            // session gates must not add up to more concurrent encodes than
            // the hardware was measured to carry.
            do {
                let machineGate = SharedEncodeAdmissionGate<CMSampleBuffer>(
                    capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.machineCapacity
                )
                let firstSession = makeSessionGate(machineGate)
                let secondSession = makeSessionGate(machineGate)
                let recorder = HostMediaLatencyRecorder()
                let encoders = [FakeFrameEncoder(), FakeFrameEncoder(), FakeFrameEncoder()]
                // Two canvases of one session, one canvas of another.
                let gates = [
                    makeGate(firstSession, recorder: recorder, encoder: encoders[0]),
                    makeGate(firstSession, recorder: recorder, encoder: encoders[1]),
                    makeGate(secondSession, recorder: recorder, encoder: encoders[2])
                ]
                for gate in gates {
                    gate.admit(makeCaptureSampleBuffer())
                }
                // Held live for the same reason as above: every count below
                // belongs to a pipeline that is still supposed to exist.
                withExtendedLifetime((gates, firstSession, secondSession)) {
                    expect(
                        encoders.map(\.submissionCount) == [1, 1, 0],
                        "two sessions cannot encode 2 + 2 frames at once: the machine bound holds across sessions, so the second session waits for hardware"
                    )
                    expect(machineGate.framesInFlight == 2, "never more than the machine bound is in flight at the hardware")
                    expect(
                        secondSession.framesInFlight == 1,
                        "the waiting session holds its own slot while its frame queues below -- its accounting is its own"
                    )
                    gates[0].frameFinished(.dropped)
                    expect(encoders.map(\.submissionCount) == [1, 1, 1], "the freed machine slot goes to the other session's waiting frame")
                    expect(machineGate.framesInFlight == 2, "and the bound is still exactly full, never exceeded")
                }
            }

            // The point of the change: a session that ends while a frame is
            // genuinely in flight gives that slot back. `deinit` cannot be
            // relied on for this -- the encoder's callback holds the gate --
            // so teardown is explicit.
            do {
                let machineGate = SharedEncodeAdmissionGate<CMSampleBuffer>(
                    capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.machineCapacity
                )
                let ending = makeSessionGate(machineGate)
                let recorder = HostMediaLatencyRecorder()
                let endingEncoder = FakeFrameEncoder()
                let endingGate = makeGate(ending, recorder: recorder, encoder: endingEncoder)
                endingGate.admit(makeCaptureSampleBuffer())
                expect(
                    ending.framesInFlight == 1 && machineGate.framesInFlight == 1,
                    "the frame is genuinely in flight: submitted to the encoder, no outcome reported yet"
                )
                endingGate.shutDown()
                expect(ending.framesInFlight == 0, "ending the session releases the slot its in-flight frame was holding")
                expect(machineGate.framesInFlight == 0, "and the machine slot underneath it, which no later session could have reclaimed")

                let next = makeSessionGate(machineGate)
                let nextEncoders = [FakeFrameEncoder(), FakeFrameEncoder()]
                let nextGates = nextEncoders.map { makeGate(next, recorder: recorder, encoder: $0) }
                for gate in nextGates {
                    gate.admit(makeCaptureSampleBuffer())
                }
                expect(
                    nextEncoders.map(\.submissionCount) == [1, 1],
                    "the session after it gets the whole bound back rather than a machine permanently one slot short"
                )
            }

            // What the encoder does after a teardown it never heard about:
            // the callback still arrives, possibly twice if something above
            // leaked, and must not touch a live session's accounting or
            // crash.
            do {
                let machineGate = SharedEncodeAdmissionGate<CMSampleBuffer>(
                    capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.machineCapacity
                )
                let dead = makeSessionGate(machineGate)
                let live = makeSessionGate(machineGate)
                let recorder = HostMediaLatencyRecorder()
                let deadEncoder = FakeFrameEncoder()
                let liveEncoder = FakeFrameEncoder()
                let deadGate = makeGate(dead, recorder: recorder, encoder: deadEncoder)
                let liveGate = makeGate(live, recorder: recorder, encoder: liveEncoder)
                let strandedFrame = makeCaptureSampleBuffer()
                deadGate.admit(strandedFrame)
                liveGate.admit(makeCaptureSampleBuffer())
                deadGate.shutDown()
                // The live pipeline is never touched again below, so it is
                // held explicitly: the slot it holds is the whole subject of
                // these assertions, and its `deinit` would give that slot
                // back.
                withExtendedLifetime((deadGate, liveGate, dead, live)) {
                    expect(machineGate.framesInFlight == 1, "only the live session's frame is still holding hardware")

                    deadGate.frameFinished(.encoded(strandedFrame))
                    deadGate.frameFinished(.dropped)
                    expect(
                        machineGate.framesInFlight == 1,
                        "a dead session's late callback -- twice over -- never frees the slot a live session is holding"
                    )
                    expect(live.framesInFlight == 1, "the live session's own accounting is untouched by it")
                    expect(
                        dead.framesInFlight == 0,
                        "and the dead session's own count is not driven below zero by releases its teardown already made good"
                    )
                    expect(
                        machineGate.unbalancedReleaseCount == 0
                            && dead.unbalancedReleaseCount == 0
                            && live.unbalancedReleaseCount == 0,
                        "a callback arriving after teardown is an expected consequence of stopping, not a caller bug to report"
                    )
                    deadGate.admit(makeCaptureSampleBuffer())
                    expect(
                        deadEncoder.submissionCount == 1 && machineGate.framesInFlight == 1,
                        "a frame captured after teardown is refused rather than admitted against a slot nothing will release"
                    )
                }
            }

            // Cross-surface preference is a property of the request, so it
            // survives the chain and is decided where the contention is. With
            // the shipped bounds one session's two canvases never contend at
            // all -- two canvases, two machine slots -- so this pins the
            // policy with a machine gate narrowed to one slot.
            do {
                let machineGate = SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 1)
                let holderSession = SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 1, machineGate: machineGate)
                let session = makeSessionGate(machineGate)
                let recorder = HostMediaLatencyRecorder()
                let focus = CanvasFocusTracker()
                focus.setFocusedSurface(CanvasSurfaceID.allCases[1])
                let holderEncoder = FakeFrameEncoder()
                let backgroundEncoder = FakeFrameEncoder()
                let focusedEncoder = FakeFrameEncoder()

                func pipelineGate(
                    _ sessionGate: SharedEncodeAdmissionGate<CMSampleBuffer>,
                    _ pipelineSurface: CanvasSurfaceID,
                    _ encoder: FakeFrameEncoder
                ) -> EncodeAdmissionGate {
                    let gate = EncodeAdmissionGate(
                        latencyRecorder: recorder,
                        sessionGate: sessionGate,
                        surface: pipelineSurface,
                        focus: focus,
                        encodedFrameHandler: { _ in }
                    )
                    gate.encoder = encoder
                    return gate
                }

                // Another session holds the one machine slot, so both of this
                // session's canvases are genuinely waiting on hardware.
                let holder = pipelineGate(holderSession, CanvasSurfaceID.allCases[0], holderEncoder)
                let background = pipelineGate(session, CanvasSurfaceID.allCases[0], backgroundEncoder)
                let focused = pipelineGate(session, CanvasSurfaceID.allCases[1], focusedEncoder)
                holder.admit(makeCaptureSampleBuffer())
                background.admit(makeCaptureSampleBuffer())
                focused.admit(makeCaptureSampleBuffer())
                expect(
                    backgroundEncoder.submissionCount == 0 && focusedEncoder.submissionCount == 0,
                    "both of the session's canvases wait while the hardware is busy"
                )
                holder.frameFinished(.dropped)
                expect(
                    focusedEncoder.submissionCount == 1 && backgroundEncoder.submissionCount == 0,
                    "the canvas the viewer is looking at is served first, even though the other one asked first"
                )
                focused.frameFinished(.dropped)
                expect(
                    backgroundEncoder.submissionCount == 1,
                    "the unfocused canvas still reaches the encoder rather than freezing behind the focused one"
                )
            }

            // For the shipped shape -- one session, one machine gate --
            // capacity, queueing, and counters behave exactly as a single
            // process-wide gate would on its own.
            do {
                let machineGate = SharedEncodeAdmissionGate<CMSampleBuffer>(
                    capacity: SharedEncodeAdmissionGate<CMSampleBuffer>.machineCapacity
                )
                let session = makeSessionGate(machineGate)
                let recorder = HostMediaLatencyRecorder()
                let encoders = [FakeFrameEncoder(), FakeFrameEncoder(), FakeFrameEncoder()]
                let gates = encoders.map { makeGate(session, recorder: recorder, encoder: $0) }
                for gate in gates {
                    gate.admit(makeCaptureSampleBuffer())
                }
                expect(
                    encoders.map(\.submissionCount) == [1, 1, 0],
                    "one session still encodes two canvases at once and no more; a third pipeline -- a rebuild overlapping its predecessor -- waits at the session's own bound"
                )
                expect(
                    session.framesInFlight == SharedEncodeAdmissionGate<CMSampleBuffer>.sessionCapacity,
                    "both of the session's slots are held"
                )
                gates[0].frameFinished(.dropped)
                expect(encoders.map(\.submissionCount) == [1, 1, 1], "the freed session slot goes to the waiting pipeline")
                gates[1].frameFinished(.dropped)
                gates[2].frameFinished(.dropped)
                expect(
                    session.framesInFlight == 0 && machineGate.framesInFlight == 0,
                    "both levels quiesce at exactly zero once every frame has reported"
                )
                expect(
                    session.unbalancedReleaseCount == 0 && machineGate.unbalancedReleaseCount == 0,
                    "no frame released a slot it did not hold at either level"
                )
                expect(
                    session.droppedFrameCount == 0 && machineGate.droppedFrameCount == 0,
                    "a pipeline that merely waited its turn is never counted as a drop"
                )
            }
        }

        // The classification the real `VTCompressionOutputCallback` feeds the
        // gate: no runner may create a `VTCompressionSession`, so this pins
        // the mapping from that callback's raw arguments to the outcome the
        // gate acts on.
        do {
            let sampleBuffer = makeCaptureSampleBuffer()
            switch VideoEncodeOutcome.callbackOutcome(status: noErr, sampleBuffer: sampleBuffer) {
            case .encoded:
                break
            default:
                expect(false, "a successful status with a sample buffer is an encoded frame")
            }
            switch VideoEncodeOutcome.callbackOutcome(status: noErr, sampleBuffer: nil) {
            case .dropped:
                break
            default:
                expect(false, "a successful status with no sample buffer is the encoder dropping the frame")
            }
            switch VideoEncodeOutcome.callbackOutcome(status: -12902, sampleBuffer: nil) {
            case .failed(let status):
                expect(status == -12902, "a failing status carries the status the encoder reported")
            default:
                expect(false, "a failing status is a failed frame, not a drop")
            }
            switch VideoEncodeOutcome.callbackOutcome(status: -12902, sampleBuffer: sampleBuffer) {
            case .failed:
                break
            default:
                expect(false, "a failing status is a failure even when a sample buffer came with it")
            }
        }

        // Bitrate must scale with pixel count, not stay pinned to whatever
        // resolution was tuned first: 4x the pixels (1920x1200 -> 3840x2400)
        // gets 4x the bits, so a resolution change cannot silently wreck
        // image quality.
        let baselineBitRate = VideoEncoderConfiguration.averageBitRate(encodeWidth: 1920, encodeHeight: 1200)
        let hiDPIBitRate = VideoEncoderConfiguration.averageBitRate(encodeWidth: 3840, encodeHeight: 2400)
        expect(baselineBitRate == 12_000_000, "the derived bitrate matches the tuned 1920x1200 baseline")
        expect(hiDPIBitRate == baselineBitRate * 4, "4x the pixels derives 4x the bitrate")
        expect(
            VideoEncoderConfiguration.dataRateLimitBytes(averageBitRate: baselineBitRate) == 15_000_000,
            "the derived data-rate limit matches the tuned 1920x1200 baseline"
        )
        expect(
            VideoEncoderConfiguration.dataRateLimitBytes(averageBitRate: hiDPIBitRate)
                == VideoEncoderConfiguration.dataRateLimitBytes(averageBitRate: baselineBitRate) * 4,
            "the data-rate limit scales with the bitrate it was derived from"
        )
        expect(
            VideoEncoderConfiguration.remoteDefault.averageBitRate == baselineBitRate,
            "the default configuration's bitrate is the derived value, not an independent hardcoded one"
        )
        expect(
            VideoEncoderConfiguration.fullHiDPI.encodeWidth == 3840 && VideoEncoderConfiguration.fullHiDPI.encodeHeight == 2400,
            "the full-HiDPI configuration encodes at the canvas's real physical pixel size"
        )
        expect(
            VideoEncoderConfiguration.fullHiDPI.averageBitRate == hiDPIBitRate,
            "the full-HiDPI configuration's bitrate is derived from its own resolution"
        )


        // The host must never ask macOS to present its Accessibility approval
        // UI. An untrusted host still serves: video and control do not need
        // Accessibility, and only input injection is withheld.
        let untrusted = RecordingAccessibilityChecker(isTrusted: false)
        expect(
            HostInputAvailability.resolve(gate: AccessibilityPermissionGate(checker: untrusted))
                == .unavailableAccessibilityNotGranted,
            "an untrusted host reports input unavailable rather than exiting"
        )
        expect(
            untrusted.promptArguments == [false],
            "resolving availability consulted Accessibility exactly once, without prompting"
        )

        let trusted = RecordingAccessibilityChecker(isTrusted: true)
        expect(
            HostInputAvailability.resolve(gate: AccessibilityPermissionGate(checker: trusted)) == .available,
            "a trusted host may inject input"
        )
        expect(trusted.promptArguments == [false], "the trusted path does not prompt either")

        // A session whose host has no injector must survive the input it cannot
        // deliver: video keeps flowing and the canvas stays up.
        let noInjectorAdapter = FakeVirtualDisplayAdapter()
        let noInjectorSession = VirtualDisplaySession(adapter: noInjectorAdapter)
        let noInjectorController = HostSessionController(
            sessions: surfaceZeroOnly(noInjectorSession), keyConfinement: .unconfined, privateDesktopOffered: { true }
        )
        _ = try! noInjectorController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expectThrows(
            HostSessionControllerError.inputInjectionUnavailable,
            { _ = try noInjectorController.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: nil)) },
            "input without an injector is refused"
        )
        expect(
            !HostSessionControllerError.inputInjectionUnavailable.isSessionFatal,
            "that refusal does not end the session"
        )
        expect(noInjectorSession.isActive, "the canvas survives input the host cannot inject")


        // Local-verification transport: a single machine cannot hairpin QUIC
        // through the tailnet interface, so the live session check runs over
        // TCP on the same bound address. Explicit, never the default.
        let tcpParameters = try! HostNetworkListener.parameters(
            boundToTailnetAddress: "100.100.0.4",
            port: 7777,
            tlsIdentity: tlsIdentity,
            transport: .tcpLocalVerification
        )
        expect(
            !(tcpParameters.defaultProtocolStack.transportProtocol is NWProtocolQUIC.Options),
            "the TCP verification transport is not QUIC"
        )
        guard case let .hostPort(tcpHost, tcpPort)? = tcpParameters.requiredLocalEndpoint else {
            expect(false, "the TCP verification listener still binds the tailnet address")
            return
        }
        expect("\(tcpHost)".contains("100.100.0.4"), "the TCP verification listener binds only the tailnet address")
        expect(tcpPort.rawValue == 7777, "the TCP verification listener binds the Sensorium port")
        do {
            _ = try HostNetworkListener.parameters(
                boundToTailnetAddress: "192.0.2.45",
                port: 7777,
                tlsIdentity: tlsIdentity,
                transport: .tcpLocalVerification
            )
            expect(false, "the TCP verification transport refuses a LAN address too")
        } catch HostNetworkListenerError.nonTailnetBindAddress {
        } catch {
            expect(false, "the TCP verification transport reports the expected error")
        }


        // The BSD-socket verification listener refuses any non-tailnet bind
        // address before touching a socket, like the QUIC listener does.
        do {
            _ = try PosixTailnetListener(tailnetAddress: "192.0.2.45", port: 7777)
            expect(false, "the posix listener refuses a LAN bind address")
        } catch PosixTailnetListenerError.nonTailnetBindAddress {
        } catch {
            expect(false, "the posix listener reports the expected LAN-bind error")
        }
        do {
            _ = try PosixTailnetListener(tailnetAddress: "0.0.0.0", port: 7777)
            expect(false, "the posix listener refuses binding every interface")
        } catch PosixTailnetListenerError.nonTailnetBindAddress {
        } catch {
            expect(false, "the posix listener reports the expected any-bind error")
        }

        // Framed bytes cross a connected socket pair intact. socketpair(2) is
        // plain IPC: no port, no listener, nothing reachable from any network.
        var pairFDs: [Int32] = [0, 0]
        expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pairFDs) == 0, "socketpair created")
        let leftChannel = PosixByteChannel(ownedFileDescriptor: pairFDs[0])
        let rightChannel = PosixByteChannel(ownedFileDescriptor: pairFDs[1])
        // The payload exceeds the kernel socket buffer, so the send only
        // completes while the other side drains it — run them concurrently.
        let sentPayload = Data((0..<70_000).map { UInt8($0 % 251) })
        let sendTask = Task { try await leftChannel.send(sentPayload) }
        let firstHalf = try! await rightChannel.receive(count: 1_000)
        let secondHalf = try! await rightChannel.receive(count: sentPayload.count - 1_000)
        try! await sendTask.value
        expect(firstHalf + secondHalf == sentPayload, "a 70KB payload crosses the channel intact and in order")
        try! await rightChannel.send(Data("reply".utf8))
        expect(
            (try! await leftChannel.receive(count: 5)) == Data("reply".utf8),
            "the channel is bidirectional"
        )
        rightChannel.cancel()
        do {
            _ = try await leftChannel.receive(count: 1)
            expect(false, "reading a closed channel throws")
        } catch {
        }
        leftChannel.cancel()
        leftChannel.cancel()

        // Concurrent `send` calls sharing one fd must never interleave: the
        // video path and the control path both write to the same
        // PosixByteChannel from independent Tasks, and an unserialized
        // partial-write loop can splice two writers' bytes into one corrupt
        // frame. Payloads are chosen well past the kernel socket buffer, so
        // each send's partial-write loop is forced across multiple write(2)
        // calls -- a payload small enough to write in one syscall would pass
        // even with the bug present.
        var interleavePairFDs: [Int32] = [0, 0]
        expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &interleavePairFDs) == 0, "socketpair created for the interleaving test")
        let interleaveSender = PosixByteChannel(ownedFileDescriptor: interleavePairFDs[0])
        let interleaveReceiver = PosixByteChannel(ownedFileDescriptor: interleavePairFDs[1])

        func framedPayload(tag: UInt8, size: Int) -> Data {
            var frame = Data([tag])
            let length = UInt32(size)
            frame.append(UInt8((length >> 24) & 0xFF))
            frame.append(UInt8((length >> 16) & 0xFF))
            frame.append(UInt8((length >> 8) & 0xFF))
            frame.append(UInt8(length & 0xFF))
            frame.append(Data(repeating: tag, count: size))
            return frame
        }

        let concurrentSenderTags: [UInt8] = Array(0..<8)
        let framePayloadSize = 700_000
        let interleaveFrameSize = 1 + 4 + framePayloadSize
        let totalInterleaveBytes = concurrentSenderTags.count * interleaveFrameSize

        let interleaveReceiveTask = Task { try await interleaveReceiver.receive(count: totalInterleaveBytes) }
        let interleaveSendTasks = concurrentSenderTags.map { tag in
            Task { try await interleaveSender.send(framedPayload(tag: tag, size: framePayloadSize)) }
        }
        for task in interleaveSendTasks { try! await task.value }
        let interleavedBytes = [UInt8](try! await interleaveReceiveTask.value)

        var interleaveOffset = 0
        var observedTags: Set<UInt8> = []
        while interleaveOffset < interleavedBytes.count {
            let tag = interleavedBytes[interleaveOffset]
            let length = (UInt32(interleavedBytes[interleaveOffset + 1]) << 24)
                | (UInt32(interleavedBytes[interleaveOffset + 2]) << 16)
                | (UInt32(interleavedBytes[interleaveOffset + 3]) << 8)
                | UInt32(interleavedBytes[interleaveOffset + 4])
            interleaveOffset += 5
            expect(Int(length) == framePayloadSize, "a frame's length header matches exactly one sender's payload, not a value spliced from two writers")
            let payload = interleavedBytes[interleaveOffset..<(interleaveOffset + Int(length))]
            expect(payload.allSatisfy { $0 == tag }, "frame \(tag)'s payload is entirely its own tag byte -- no other sender's bytes interleaved into it")
            expect(!observedTags.contains(tag), "sender \(tag)'s frame arrived exactly once, not fragmented by an interleaved write")
            observedTags.insert(tag)
            interleaveOffset += Int(length)
        }
        expect(observedTags == Set(concurrentSenderTags), "every concurrent sender's frame arrived complete and intact")

        interleaveSender.cancel()
        interleaveReceiver.cancel()


        // The QUIC local-verification mode exists because a same-machine dial
        // cannot traverse the tailnet interface: it admits loopback sources at
        // accept time, and only it does. LAN stays refused in every mode.
        let quicVerifyParameters = try! HostNetworkListener.parameters(
            boundToTailnetAddress: "100.100.0.4",
            port: 7777,
            tlsIdentity: tlsIdentity,
            transport: .quicLocalVerification
        )
        expect(
            quicVerifyParameters.defaultProtocolStack.transportProtocol is NWProtocolQUIC.Options,
            "the QUIC verification transport is still QUIC"
        )
        expect(
            quicVerifyParameters.requiredLocalEndpoint == nil,
            "the QUIC verification listener pins no local endpoint for accepted connections to re-bind"
        )
        expect(
            quicVerifyParameters.requiredInterface == nil,
            "the QUIC verification listener is unscoped so a loopback dial can complete"
        )
        expect(
            HostConnectionAdmission.admits(sourceHost: "100.100.0.4", transport: .quic),
            "the product transport admits tailnet sources"
        )
        expect(
            !HostConnectionAdmission.admits(sourceHost: "127.0.0.1", transport: .quic),
            "the product transport refuses loopback"
        )
        expect(
            HostConnectionAdmission.admits(sourceHost: "127.0.0.1", transport: .quicLocalVerification),
            "the verification transport admits loopback"
        )
        expect(
            HostConnectionAdmission.admits(sourceHost: "100.100.0.4", transport: .quicLocalVerification),
            "the verification transport still admits tailnet sources"
        )
        expect(
            !HostConnectionAdmission.admits(sourceHost: "192.0.2.45", transport: .quicLocalVerification),
            "the verification transport still refuses LAN sources"
        )
        expect(
            !HostConnectionAdmission.admits(sourceHost: "8.8.8.8", transport: .quicLocalVerification),
            "the verification transport still refuses public sources"
        )


        // A dead peer over UDP is silence, not an error. The QUIC idle timeout
        // is what turns that silence into a failed connection while the 10s
        // clock-sync traffic keeps a live session from ever looking idle.
        for kind in [HostTransportKind.quic, .quicLocalVerification] {
            let idleParameters = try! HostNetworkListener.parameters(
                boundToTailnetAddress: "100.100.0.4",
                port: 7777,
                tlsIdentity: tlsIdentity,
                transport: kind
            )
            let quicOptions = idleParameters.defaultProtocolStack.transportProtocol as? NWProtocolQUIC.Options
            expect(
                quicOptions?.idleTimeout == 30_000,
                "\(kind) fails a silent connection after 30s instead of hanging for good"
            )
        }

        // Host per-frame stage latency, matched by presentation timestamp
        // across capture, submit, encode, and send. The four stages partition
        // a frame's host lifetime end to end and never overlap, so no stage's
        // number silently contains another's.
        let latencyRecorder = HostMediaLatencyRecorder()
        latencyRecorder.recordCapture(surface: surfaceZero, presentationTimeNanoseconds: 1_000, atNanoseconds: 1_000_500)
        latencyRecorder.recordEncodeSubmit(surface: surfaceZero, presentationTimeNanoseconds: 1_000, atNanoseconds: 1_002_000)
        latencyRecorder.recordEncodeOutput(surface: surfaceZero, presentationTimeNanoseconds: 1_000, atNanoseconds: 1_003_000)
        latencyRecorder.recordSendCompleted(surface: surfaceZero, presentationTimeNanoseconds: 1_000, atNanoseconds: 1_010_000)
        let latencyMetrics = latencyRecorder.metrics
        expect(latencyMetrics.samples(for: .capture).p50 == 999_500, "capture stage measures presentation timestamp to callback entry")
        expect(latencyMetrics.samples(for: .admit).p50 == 1_500, "admit stage measures capture entry to encoder submission -- the queue and gate wait alone")
        expect(latencyMetrics.samples(for: .encode).p50 == 1_000, "encode stage measures encoder submission to encoder output, excluding the wait ahead of it")
        expect(latencyMetrics.samples(for: .send).p50 == 7_000, "send stage measures encoder output to send completion")

        // Both canvases feed one recorder, and two independent captures can
        // legitimately carry the same presentation timestamp. Keyed by
        // timestamp alone, one surface's capture entry overwrites the other's
        // and the stage intervals are attributed to the wrong frame — silently
        // wrong telemetry, which is worse than none.
        let twoSurfaceRecorder = HostMediaLatencyRecorder()
        twoSurfaceRecorder.recordCapture(surface: surfaceZero, presentationTimeNanoseconds: 5_000, atNanoseconds: 5_000_500)
        twoSurfaceRecorder.recordCapture(surface: surfaceOne, presentationTimeNanoseconds: 5_000, atNanoseconds: 5_002_000)
        twoSurfaceRecorder.recordEncodeSubmit(surface: surfaceZero, presentationTimeNanoseconds: 5_000, atNanoseconds: 5_000_500)
        twoSurfaceRecorder.recordEncodeSubmit(surface: surfaceOne, presentationTimeNanoseconds: 5_000, atNanoseconds: 5_002_000)
        twoSurfaceRecorder.recordEncodeOutput(surface: surfaceZero, presentationTimeNanoseconds: 5_000, atNanoseconds: 5_001_000)
        twoSurfaceRecorder.recordEncodeOutput(surface: surfaceOne, presentationTimeNanoseconds: 5_000, atNanoseconds: 5_003_000)
        twoSurfaceRecorder.recordSendCompleted(surface: surfaceOne, presentationTimeNanoseconds: 5_000, atNanoseconds: 5_004_000)
        let twoSurfaceMetrics = twoSurfaceRecorder.metrics
        expect(
            twoSurfaceMetrics.samples(for: .encode).count == 2,
            "each surface's encode is measured against its own submission, so neither sample is lost to the other's timestamp"
        )
        expect(
            twoSurfaceMetrics.samples(for: .encode).p50 == 500 && twoSurfaceMetrics.samples(for: .encode).p95 == 1_000,
            "surface 0 measures 500ns and surface 1 measures 1000ns, not one surface's submission against the other's encode output"
        )
        expect(
            twoSurfaceMetrics.samples(for: .send).count == 1 && twoSurfaceMetrics.samples(for: .send).p50 == 1_000,
            "surface 1's send is measured from surface 1's own encode output"
        )
        expect(
            twoSurfaceRecorder.frameCounts.captured == 2 && twoSurfaceRecorder.frameCounts.encoded == 2,
            "the ground-truth counters stay session-wide across both surfaces"
        )

        // Telemetry needs each surface's own numbers, never blended into the
        // other's -- the session-wide accessors above must stay exactly as
        // they are, and this is the second, per-surface view alongside them.
        expect(
            twoSurfaceRecorder.metrics(for: surfaceZero).samples(for: .encode).count == 1
                && twoSurfaceRecorder.metrics(for: surfaceZero).samples(for: .encode).p50 == 500,
            "surface 0's own metrics carry only its own encode sample"
        )
        expect(
            twoSurfaceRecorder.metrics(for: surfaceOne).samples(for: .encode).count == 1
                && twoSurfaceRecorder.metrics(for: surfaceOne).samples(for: .encode).p50 == 1_000,
            "surface 1's own metrics carry only its own encode sample, not surface 0's"
        )
        expect(
            twoSurfaceRecorder.metrics(for: surfaceZero).samples(for: .send).count == 0,
            "surface 0's own metrics report no send sample: only surface 1 ever completed a send"
        )
        expect(
            twoSurfaceRecorder.frameCounts(for: surfaceZero).captured == 1
                && twoSurfaceRecorder.frameCounts(for: surfaceZero).encoded == 1,
            "surface 0's own ground-truth counts are its own, not the session total"
        )
        expect(
            twoSurfaceRecorder.frameCounts(for: surfaceOne).captured == 1
                && twoSurfaceRecorder.frameCounts(for: surfaceOne).encoded == 1,
            "surface 1's own ground-truth counts are its own, not the session total"
        )

        let dropRecorder = HostMediaLatencyRecorder()
        dropRecorder.recordEncoderInputDrop(surface: surfaceZero)
        dropRecorder.recordEncoderInputDrop(surface: surfaceZero)
        dropRecorder.recordEncoderInputDrop(surface: surfaceOne)
        dropRecorder.recordGlobalEncoderInputDrop(surface: surfaceOne)
        dropRecorder.recordEncodeSubmissionFailure(status: -1, surface: surfaceZero)
        dropRecorder.recordEncoderInputDrop()
        expect(
            dropRecorder.frameCounts(for: surfaceZero).encoderInputDropped == 2
                && dropRecorder.frameCounts(for: surfaceZero).encodeSubmissionFailures == 1
                && dropRecorder.frameCounts(for: surfaceZero).globalAdmissionDropped == 0,
            "surface 0 attributes only the drops and failures its own calls named"
        )
        expect(
            dropRecorder.frameCounts(for: surfaceOne).encoderInputDropped == 1
                && dropRecorder.frameCounts(for: surfaceOne).globalAdmissionDropped == 1,
            "surface 1 attributes only the drops its own calls named, not surface 0's"
        )
        expect(
            dropRecorder.frameCounts.encoderInputDropped == 4,
            "a drop recorded with no surface (the pre-surface call shape) still counts toward the session-wide total, unattributed to either surface"
        )

        // `HostTelemetrySnapshotBuilder` is the pure seam behind the periodic
        // wire send: no socket, no recorder, just closures a test can hand-build.
        var telemetryBuilder = HostTelemetrySnapshotBuilder()
        func countsForSurfaceZero(captured: Int, encoded: Int) -> (CanvasSurfaceID) -> HostFrameCounts {
            { surface in
                surface == surfaceZero
                    ? HostFrameCounts(captured: captured, encoded: encoded, encodeSubmissionFailures: 0)
                    : HostFrameCounts(captured: 0, encoded: 0, encodeSubmissionFailures: 0)
            }
        }
        var firstTickMetrics = SessionMetrics()
        _ = firstTickMetrics.record(stage: .capture, startedAtNanoseconds: 0, endedAtNanoseconds: 2_000_000)
        let firstTick = telemetryBuilder.snapshot(
            metrics: { $0 == surfaceZero ? firstTickMetrics : SessionMetrics() },
            frameCounts: countsForSurfaceZero(captured: 60, encoded: 60),
            sendQueueDropped: { _ in 0 },
            appliedStreamScale: { _ in nil },
            sustainableScaleCeiling: { _ in nil },
            clampedFromUserChoice: { _ in nil },
            appliedFramesPerSecond: { _ in nil },
            qualityScale: { _ in nil },
            fidelityLimitReason: { _ in nil },
            atNanoseconds: 1_000_000_000
        )
        expect(
            firstTick.count == 1 && firstTick[0].surfaceID == surfaceZero.wireValue,
            "a surface with no captured or encoded frames yet is omitted from the snapshot entirely"
        )
        expect(
            firstTick[0].framesPerSecond == nil,
            "the first-ever snapshot has no prior tick to measure a rate against, so it reports no fps rather than a fabricated one"
        )
        expect(
            firstTick[0].capture?.p50Nanoseconds == 2_000_000,
            "a surface's own stage samples reach the snapshot"
        )

        let secondTick = telemetryBuilder.snapshot(
            metrics: { $0 == surfaceZero ? firstTickMetrics : SessionMetrics() },
            frameCounts: countsForSurfaceZero(captured: 120, encoded: 120),
            sendQueueDropped: { surface in surface == surfaceZero ? 3 : 0 },
            appliedStreamScale: { _ in nil },
            sustainableScaleCeiling: { _ in nil },
            clampedFromUserChoice: { _ in nil },
            appliedFramesPerSecond: { _ in nil },
            qualityScale: { _ in nil },
            fidelityLimitReason: { _ in nil },
            atNanoseconds: 2_000_000_000
        )
        expect(
            secondTick[0].framesPerSecond == 60,
            "fps is the encoded-frame delta since the previous tick divided by the elapsed seconds"
        )
        expect(
            secondTick[0].sendQueueDropped == 3,
            "the send-queue drop count the caller supplies reaches the snapshot unchanged"
        )
        expect(
            secondTick[0].appliedStreamScale == nil && secondTick[0].sustainableScaleCeiling == nil,
            "a session that has learned nothing reports no scale rather than a fabricated default"
        )

        // The whole point of the two fields: the viewer asked for 2.00x, the
        // encoder could not hold it, and the only place that fact can reach
        // the viewer is this snapshot.
        let backedOffTick = telemetryBuilder.snapshot(
            metrics: { $0 == surfaceZero ? firstTickMetrics : SessionMetrics() },
            frameCounts: countsForSurfaceZero(captured: 180, encoded: 180),
            sendQueueDropped: { _ in 0 },
            appliedStreamScale: { $0 == surfaceZero ? 1.5 : nil },
            sustainableScaleCeiling: { $0 == surfaceZero ? 1.5 : nil },
            clampedFromUserChoice: { $0 == surfaceZero ? 2.0 : nil },
            appliedFramesPerSecond: { $0 == surfaceZero ? 30 : nil },
            qualityScale: { $0 == surfaceZero ? 0.75 : nil },
            fidelityLimitReason: { $0 == surfaceZero ? FidelityLimitReason.link : nil },
            atNanoseconds: 3_000_000_000
        )
        expect(
            backedOffTick[0].appliedStreamScale == 1.5 && backedOffTick[0].sustainableScaleCeiling == 1.5,
            "the scale actually applied and the ceiling learned for it both reach the snapshot"
        )
        expect(
            backedOffTick[0].clampedFromUserChoice == 2.0,
            "the scale a person explicitly asked for, when a ceiling held it back, also reaches the snapshot"
        )
        expect(
            secondTick[0].clampedFromUserChoice == nil,
            "a tick with no clamped user choice reports none, never a fabricated one"
        )

        let unmatchedRecorder = HostMediaLatencyRecorder()
        unmatchedRecorder.recordEncodeOutput(surface: surfaceZero, presentationTimeNanoseconds: 42, atNanoseconds: 5_000)
        expect(unmatchedRecorder.metrics.samples(for: .encode).count == 0, "an encode callback with no matching submit entry records no sample")
        unmatchedRecorder.recordSendCompleted(surface: surfaceZero, presentationTimeNanoseconds: 999, atNanoseconds: 6_000)
        expect(unmatchedRecorder.metrics.samples(for: .send).count == 0, "a send completion with no matching encode entry records no sample")

        let negativeRecorder = HostMediaLatencyRecorder()
        negativeRecorder.recordCapture(surface: surfaceZero, presentationTimeNanoseconds: 10, atNanoseconds: 5_000)
        negativeRecorder.recordEncodeSubmit(surface: surfaceZero, presentationTimeNanoseconds: 10, atNanoseconds: 5_000)
        negativeRecorder.recordEncodeOutput(surface: surfaceZero, presentationTimeNanoseconds: 10, atNanoseconds: 4_000)
        expect(negativeRecorder.metrics.samples(for: .encode).count == 0, "a negative encode interval is refused rather than recorded as fast")

        let futurePTSRecorder = HostMediaLatencyRecorder()
        futurePTSRecorder.recordCapture(surface: surfaceZero, presentationTimeNanoseconds: 10_000, atNanoseconds: 1_000)
        expect(futurePTSRecorder.metrics.samples(for: .capture).count == 0, "a presentation timestamp after the callback entry is refused rather than recorded as fast")

        // A ground-truth counter records every callback, independent of the
        // percentile guard above: a run whose capture presentation timestamps
        // are consistently at or after their own callback's wall-clock entry
        // rejects every percentile capture sample while every matching encode
        // output (keyed on the *callback's* wall-clock entry, not the frame's
        // presentation timestamp) still records fine. That reproduces the
        // otherwise-impossible "encode_count > capture_count" a live run
        // observed -- and shows the ground-truth counters are not fooled by it.
        let inversionRecorder = HostMediaLatencyRecorder()
        inversionRecorder.recordCapture(surface: surfaceZero, presentationTimeNanoseconds: 50_000, atNanoseconds: 1_000)
        inversionRecorder.recordEncodeSubmit(surface: surfaceZero, presentationTimeNanoseconds: 50_000, atNanoseconds: 1_000)
        inversionRecorder.recordEncodeOutput(surface: surfaceZero, presentationTimeNanoseconds: 50_000, atNanoseconds: 2_000)
        inversionRecorder.recordCapture(surface: surfaceZero, presentationTimeNanoseconds: 60_000, atNanoseconds: 1_500)
        inversionRecorder.recordEncodeSubmit(surface: surfaceZero, presentationTimeNanoseconds: 60_000, atNanoseconds: 1_500)
        inversionRecorder.recordEncodeOutput(surface: surfaceZero, presentationTimeNanoseconds: 60_000, atNanoseconds: 2_500)
        expect(inversionRecorder.metrics.samples(for: .capture).count == 0, "both captures used a presentation timestamp after the callback entry, so the percentile guard rejected them")
        expect(inversionRecorder.metrics.samples(for: .encode).count == 2, "each encode output still matched its stored submit entry, so the percentile encode count exceeds the percentile capture count")
        expect(inversionRecorder.frameCounts.captured == 2, "the ground-truth counter counted both capture callbacks the percentile stage silently dropped")
        expect(inversionRecorder.frameCounts.encoded == 2, "the ground-truth counters agree with each other, unlike the percentile counts")

        // Both the encode checkpoint and the session-wide `.encode`
        // stage measure encoder-only cost: submit (immediately before
        // VTCompressionSessionEncodeFrame) to output, not capture (before the
        // admission queue, the session gate, and the machine-wide gate) to
        // output. They differ only in their window -- the checkpoint is reset
        // per fidelity change, `.encode` runs for the session -- so the same recorded
        // calls must produce the same interval in both.
        let checkpointRecorder = HostMediaLatencyRecorder()
        checkpointRecorder.resetEncodeCheckpoint(for: surfaceZero)
        checkpointRecorder.recordCapture(surface: surfaceZero, presentationTimeNanoseconds: 1_000, atNanoseconds: 1_000_000)
        checkpointRecorder.recordEncodeSubmit(surface: surfaceZero, presentationTimeNanoseconds: 1_000, atNanoseconds: 1_050_000)
        checkpointRecorder.recordEncodeOutput(surface: surfaceZero, presentationTimeNanoseconds: 1_000, atNanoseconds: 1_060_000)
        expect(
            checkpointRecorder.metrics.samples(for: .encode).p50 == 10_000,
            "the session-wide encode stage measures submit to output (10_000ns), not capture to output (60_000ns), which would charge the encoder for the queue and gate wait ahead of it"
        )
        expect(
            checkpointRecorder.encodeLatencySinceCheckpoint(for: surfaceZero).count == 0,
            "the first sample after a checkpoint reset is the encoder's opening IDR and is excluded, not recorded"
        )
        checkpointRecorder.recordCapture(surface: surfaceZero, presentationTimeNanoseconds: 2_000, atNanoseconds: 2_000_000)
        checkpointRecorder.recordEncodeSubmit(surface: surfaceZero, presentationTimeNanoseconds: 2_000, atNanoseconds: 2_050_000)
        checkpointRecorder.recordEncodeOutput(surface: surfaceZero, presentationTimeNanoseconds: 2_000, atNanoseconds: 2_060_000)
        let checkpointSamples = checkpointRecorder.encodeLatencySinceCheckpoint(for: surfaceZero)
        expect(
            checkpointSamples.count == 1 && checkpointSamples.p50 == 10_000,
            "the second frame after the reset is measured submit-to-output (10_000ns), not capture-to-output (60_000ns), which would fold in the admission-queue and gate wait ahead of the encoder"
        )
        // The same submit call also feeds a durable `.admit` stage (capture
        // to submit, 50_000ns for both frames above), distinct from the
        // ephemeral per-checkpoint samples just asserted on: this is what
        // reaches `traceLines()` and a cross-machine run's written trace,
        // never reset by `resetEncodeCheckpoint`.
        expect(
            checkpointRecorder.metrics.samples(for: .admit).count == 2
                && checkpointRecorder.metrics.samples(for: .admit).p50 == 50_000,
            "the session-wide admit stage records the queue/gate wait ahead of the encoder for both frames"
        )
        expect(
            checkpointRecorder.metrics(for: surfaceZero).samples(for: .admit).p50 == 50_000,
            "the per-surface admit stage matches the session-wide one for a single-surface run"
        )
        expect(
            checkpointRecorder.metrics.traceLines(session: "test").contains {
                $0.contains(#""stage":"admit""#)
            },
            "admit reaches the written trace alongside capture/encode/send, so a cross-machine run can tell queue wait apart from encode compute"
        )

        // A frame dropped between capture and its later stages never
        // produces the call that would remove its entry, so without an age
        // bound it would orphan that entry forever -- checked here by
        // advancing recorded time well past the staleness threshold and
        // confirming a much-later match for the stale presentation
        // timestamp finds nothing, while a recent one still matches
        // normally.
        let staleRecorder = HostMediaLatencyRecorder()
        staleRecorder.recordCapture(surface: surfaceZero, presentationTimeNanoseconds: 1, atNanoseconds: 0)
        staleRecorder.recordEncodeSubmit(surface: surfaceZero, presentationTimeNanoseconds: 1, atNanoseconds: 0)
        staleRecorder.recordCapture(surface: surfaceZero, presentationTimeNanoseconds: 2, atNanoseconds: 6_000_000_000)
        staleRecorder.recordEncodeSubmit(surface: surfaceZero, presentationTimeNanoseconds: 2, atNanoseconds: 6_000_000_000)
        staleRecorder.recordEncodeOutput(surface: surfaceZero, presentationTimeNanoseconds: 1, atNanoseconds: 6_000_000_100)
        expect(
            staleRecorder.metrics.samples(for: .encode).count == 0,
            "a submit entry older than the staleness threshold is evicted before this encode output could match it"
        )
        staleRecorder.recordEncodeOutput(surface: surfaceZero, presentationTimeNanoseconds: 2, atNanoseconds: 6_000_000_200)
        expect(
            staleRecorder.metrics.samples(for: .encode).count == 1,
            "the recent submit entry, not yet stale, still matches normally"
        )

        // ScreenCaptureKit's output callback fires for every frame-status
        // update, not only new frames: `.idle`/`.blank`/`.suspended`/etc.
        // carry no new pixel buffer, so submitting them to the encoder always
        // fails. Only a `.complete` frame is real capture output. What that
        // frame's dirty-rect list decides on top of the status is covered by
        // `runScreenChangeAdmissionTests`.
        let redrawn = [CGRect(x: 0, y: 0, width: 8, height: 8)]
        expect(ScreenCaptureFrameAdmission.shouldEncode(status: .complete, dirtyRects: redrawn), "a complete frame is submitted to the encoder")
        expect(!ScreenCaptureFrameAdmission.shouldEncode(status: .idle, dirtyRects: nil), "an idle no-change notification is never submitted to the encoder")
        expect(!ScreenCaptureFrameAdmission.shouldEncode(status: .blank, dirtyRects: redrawn), "a blank status is never submitted to the encoder")
        expect(!ScreenCaptureFrameAdmission.shouldEncode(status: .suspended, dirtyRects: redrawn), "a suspended status is never submitted to the encoder")
        expect(!ScreenCaptureFrameAdmission.shouldEncode(status: .started, dirtyRects: redrawn), "a stream-started marker carries no frame and is never submitted")
        expect(!ScreenCaptureFrameAdmission.shouldEncode(status: .stopped, dirtyRects: redrawn), "a stream-stopped marker carries no frame and is never submitted")
        expect(!ScreenCaptureFrameAdmission.shouldEncode(status: nil, dirtyRects: redrawn), "a sample buffer with no status attachment is never submitted to the encoder")

        let failureRecorder = HostMediaLatencyRecorder()
        expect(failureRecorder.frameCounts.encodeSubmissionFailures == 0, "a recorder with no failures reports zero rather than nil-like ambiguity")
        failureRecorder.recordEncodeSubmissionFailure(status: -12909)
        failureRecorder.recordEncodeSubmissionFailure(status: -12909)
        expect(failureRecorder.frameCounts.encodeSubmissionFailures == 2, "encode submission failures are counted rather than silently discarded by `try?`")

        var summaryMetrics = SessionMetrics()
        _ = summaryMetrics.record(stage: .capture, startedAtNanoseconds: 0, endedAtNanoseconds: 2_000_000)
        _ = summaryMetrics.record(stage: .admit, startedAtNanoseconds: 0, endedAtNanoseconds: 3_000_000)
        _ = summaryMetrics.record(stage: .encode, startedAtNanoseconds: 0, endedAtNanoseconds: 4_000_000)
        _ = summaryMetrics.record(stage: .send, startedAtNanoseconds: 0, endedAtNanoseconds: 1_000_000)
        guard let summary = HostLatencySummary.line(metrics: summaryMetrics, droppedFrameCount: 3) else {
            expect(false, "a session with samples produces a host stage summary line")
            return
        }
        expect(summary.contains("capture p50 2.0ms"), "the summary reports capture latency")
        expect(summary.contains("admit p50 3.0ms"), "the summary reports admit latency -- the queue/gate wait ahead of the encoder, distinct from encode")
        expect(summary.contains("encode p50 4.0ms"), "the summary reports encode latency")
        expect(summary.contains("send p50 1.0ms"), "the summary reports send latency")
        expect(summary.contains("3 dropped"), "the summary reports the dropped frame count")
        expect(
            HostLatencySummary.line(metrics: SessionMetrics(), droppedFrameCount: 0) == nil,
            "a session with no measured stages reports nothing rather than a false zero"
        )

        guard let groundTruthSummary = HostLatencySummary.line(
            metrics: summaryMetrics,
            droppedFrameCount: 3,
            frameCounts: HostFrameCounts(captured: 10, encoded: 4, encodeSubmissionFailures: 1)
        ) else {
            expect(false, "a session with samples and frame counts still produces a summary line")
            return
        }
        expect(groundTruthSummary.contains("ground truth frames captured=10 encoded=4"), "the summary surfaces the ground-truth frame counts next to the percentile latency, so the two can be reconciled by eye")
        expect(groundTruthSummary.contains("encodeSubmissionFailures=1"), "the summary surfaces encode submission failures when any occurred")
        expect(
            HostLatencySummary.line(metrics: summaryMetrics, droppedFrameCount: 3, frameCounts: HostFrameCounts(captured: 5, encoded: 5, encodeSubmissionFailures: 0))?.contains("encodeSubmissionFailures") == false,
            "the summary omits the submission-failure count when there were none"
        )

        // The coordinator must signal session end exactly once, at the point
        // it actually stops streaming, so a caller can write a latency trace.
        let sessionEndAdapter = FakeVirtualDisplayAdapter()
        let sessionEndSession = VirtualDisplaySession(adapter: sessionEndAdapter)
        let sessionEndMedia = FakeCanvasMedia()
        let sessionEndEvents = DiagnosticsRecorder()
        let sessionEndCoordinator = HostSessionCoordinator(
            controller: HostSessionController(
                sessions: surfaceZeroOnly(sessionEndSession), keyConfinement: .unconfined, privateDesktopOffered: { true }
            ),
            media: onlyOnSurfaceZero(sessionEndMedia),
            videoSink: FakeVideoSink(),
            onSessionEnded: { sessionEndEvents.record("ended") }
        )
        _ = try! await sessionEndCoordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expect(sessionEndEvents.messages.isEmpty, "no session-end callback before the session actually ends")
        _ = try! await sessionEndCoordinator.handleWritingResponse(.goodbye(reason: "client-disconnected"))
        expect(sessionEndEvents.messages == ["ended"], "goodbye fires the session-end callback exactly once")
        _ = try? await sessionEndCoordinator.handleWritingResponse(.goodbye(reason: "client-disconnected"))
        expect(sessionEndEvents.messages == ["ended"], "a repeated goodbye does not fire the session-end callback again")


        // --- Streamed resolution follows the viewer's drawable ---

        let baseEncoder = VideoEncoderConfiguration.remoteDefault
        expect(baseEncoder.streamScale == 1.0, "today's default configuration is the 1x stream scale")
        expect(
            VideoEncoderConfiguration.fullHiDPI.streamScale == 2.0,
            "the full-HiDPI configuration is the canvas's native 2x stream scale"
        )
        for scale in [1.0, 1.25, 1.5, 1.75, 2.0] {
            let scaled = baseEncoder.scaled(toStreamScale: scale)
            expect(
                scaled.encodeWidth == Int((1920.0 * scale).rounded())
                    && scaled.encodeHeight == Int((1200.0 * scale).rounded()),
                "stream scale \(scale) encodes the canvas logical size multiplied by it"
            )
            expect(
                scaled.captureWidth == scaled.encodeWidth && scaled.captureHeight == scaled.encodeHeight,
                "capture and encode stay the same size: nothing is resampled between them"
            )
            expect(
                Double(scaled.encodeWidth) * 1200.0 == Double(scaled.encodeHeight) * 1920.0,
                "every stream scale preserves the canvas aspect ratio exactly"
            )
            expect(
                scaled.encodeWidth % 2 == 0 && scaled.encodeHeight % 2 == 0,
                "every stream scale yields dimensions H.264 can actually encode"
            )
            expect(
                scaled.averageBitRate == VideoEncoderConfiguration.averageBitRate(
                    encodeWidth: scaled.encodeWidth,
                    encodeHeight: scaled.encodeHeight
                ),
                "the bitrate follows the new pixel count rather than staying at the old resolution's"
            )
            expect(
                scaled.dataRateLimitBytes == VideoEncoderConfiguration.dataRateLimitBytes(
                    averageBitRate: scaled.averageBitRate
                ),
                "the burst ceiling follows the new bitrate"
            )
            expect(scaled.streamScale == scale, "a scaled configuration reports the scale it was built for")
            expect(
                scaled.width == 1920 && scaled.height == 1200,
                "the canvas's own logical size never changes with the stream scale"
            )
        }
        expect(
            VideoEncoderConfiguration.fullHiDPI.scaled(toStreamScale: 1.0).encodeWidth == 1920,
            "scaling is expressed against the canvas logical size, not the previous encode size"
        )

        var debouncer = StreamScaleDebouncer(appliedScale: 1.0, settleSeconds: 0.3)
        debouncer.request(scale: 1.25, atSeconds: 0)
        expect(debouncer.takeSettledScale(atSeconds: 0.1) == nil, "an unsettled request never rebuilds the encoder")
        debouncer.request(scale: 1.5, atSeconds: 0.1)
        debouncer.request(scale: 1.75, atSeconds: 0.2)
        debouncer.request(scale: 2.0, atSeconds: 0.25)
        expect(debouncer.takeSettledScale(atSeconds: 0.5) == nil, "a live drag keeps resetting the settle window")
        expect(debouncer.takeSettledScale(atSeconds: 0.56) == 2.0, "a burst of sizes yields exactly the last settled scale")
        expect(debouncer.takeSettledScale(atSeconds: 1.0) == nil, "a settled scale is taken exactly once")
        debouncer.markApplied(2.0)
        debouncer.request(scale: 2.0, atSeconds: 1.0)
        expect(
            debouncer.takeSettledScale(atSeconds: 2.0) == nil,
            "a request for the scale already streaming never rebuilds the encoder"
        )
        debouncer.request(scale: 1.5, atSeconds: 2.0)
        expect(debouncer.takeSettledScale(atSeconds: 2.4) == 1.5, "a settled change away from the applied scale is applied")
        expect(
            debouncer.appliedScale == 2.0,
            "a scale that has not been confirmed applied does not move the applied scale"
        )

        var generation = EncoderGenerationGate()
        expect(!generation.admits(keyFrame: false), "a delta before the stream's first keyframe is refused")
        expect(generation.admits(keyFrame: true), "the first keyframe opens the stream")
        expect(generation.admits(keyFrame: false), "deltas follow the keyframe that made them decodable")
        generation.beginNewGeneration()
        expect(
            !generation.admits(keyFrame: false),
            "after a resolution change a delta is refused: the client still holds the old parameter sets"
        )
        expect(!generation.admits(keyFrame: false), "and stays refused until the new keyframe actually arrives")
        expect(generation.admits(keyFrame: true), "the new generation's keyframe carries the new SPS/PPS and reopens the stream")
        expect(generation.admits(keyFrame: false), "deltas at the new resolution follow their own keyframe")

        let scaleAdapter = FakeVirtualDisplayAdapter()
        let scaleSession = VirtualDisplaySession(adapter: scaleAdapter)
        let scaleController = HostSessionController(
            sessions: surfaceZeroOnly(scaleSession), keyConfinement: .unconfined, privateDesktopOffered: { true }
        )
        expectThrows(
            HostSessionControllerError.inputSessionUnavailable,
            { _ = try scaleController.handle(.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil)) },
            "a viewer drawable size before the canvas exists is refused"
        )
        _ = try! scaleController.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        _ = try! scaleController.handle(.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil))
        expect(scaleController.requestedStreamScale(for: CanvasSurfaceID.allCases[0]) == 2.0, "a full-native viewer drawable asks for the canvas's own 2x")
        _ = try! scaleController.handle(.viewerDrawableSize(pixelWidth: 2880, pixelHeight: 1800, surfaceID: nil, maximumScale: nil))
        expect(scaleController.requestedStreamScale(for: CanvasSurfaceID.allCases[0]) == 1.5, "a smaller viewer drawable asks for the matching smaller scale")
        for hostile in [(0.0, 2400.0), (-3840.0, 2400.0), (3840.0, 0.0), (3840.0, -2400.0), (1e9, 1e9), (Double.nan, 2400.0)] {
            expectThrows(
                HostSessionControllerError.invalidViewerDrawableSize,
                { _ = try scaleController.handle(.viewerDrawableSize(pixelWidth: hostile.0, pixelHeight: hostile.1, surfaceID: nil, maximumScale: nil)) },
                "a degenerate viewer drawable size is refused rather than sizing the encoder"
            )
        }
        expect(
            scaleController.requestedStreamScale(for: CanvasSurfaceID.allCases[0]) == 1.5,
            "a refused viewer drawable size leaves the last valid one alone"
        )
        expect(
            !HostSessionControllerError.invalidViewerDrawableSize.isSessionFatal,
            "one bad viewer drawable size is survivable, not a reason to drop an authenticated session"
        )
        let unauthenticatedScaleController = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            keyConfinement: .unconfined
        )
        expectThrows(
            HostSessionControllerError.authenticationRequired,
            { _ = try unauthenticatedScaleController.handle(.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil)) },
            "an unauthenticated peer cannot size the host's encoder"
        )

        let burstMedia = FakeScalableCanvasMedia()
        let burstEvents = DiagnosticsRecorder()
        let burstCoordinator = HostSessionCoordinator(
            controller: HostSessionController(sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())), keyConfinement: .unconfined, privateDesktopOffered: { true }),
            media: onlyOnSurfaceZero(burstMedia),
            videoSink: FakeVideoSink(),
            streamScaleSettleSeconds: 0.2,
            onEvent: { burstEvents.record($0) }
        )
        _ = try! await burstCoordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        for size in [(2400.0, 1500.0), (2880.0, 1800.0), (3360.0, 2100.0), (3840.0, 2400.0)] {
            _ = try! await burstCoordinator.handleWritingResponse(.viewerDrawableSize(pixelWidth: size.0, pixelHeight: size.1, surfaceID: nil, maximumScale: nil))
        }
        expect(burstMedia.reconfiguredScales.isEmpty, "no rebuild while the viewer window is still being dragged")
        try! await Task.sleep(for: .milliseconds(700))
        expect(
            burstMedia.reconfiguredScales == [2.0],
            "a burst of viewer sizes yields exactly one reconfiguration, at the settled scale"
        )
        _ = try! await burstCoordinator.handleWritingResponse(.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil))
        try! await Task.sleep(for: .milliseconds(500))
        expect(
            burstMedia.reconfiguredScales == [2.0],
            "a viewer size that derives the scale already streaming never rebuilds the encoder again"
        )
        expect(burstMedia.stopCount == 0, "a successful reconfiguration never stops the session")

        let recoveredMedia = FakeScalableCanvasMedia()
        recoveredMedia.reconfigurationFailure = CanvasMediaReconfigurationError.recoveredToPreviousScale(1.0)
        let recoveredEvents = DiagnosticsRecorder()
        let recoveredSession = VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())
        let recoveredCoordinator = HostSessionCoordinator(
            controller: HostSessionController(sessions: surfaceZeroOnly(recoveredSession), keyConfinement: .unconfined, privateDesktopOffered: { true }),
            media: onlyOnSurfaceZero(recoveredMedia),
            videoSink: FakeVideoSink(),
            streamScaleSettleSeconds: 0.05,
            onEvent: { recoveredEvents.record($0) }
        )
        _ = try! await recoveredCoordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        _ = try! await recoveredCoordinator.handleWritingResponse(.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil))
        try! await Task.sleep(for: .milliseconds(400))
        expect(recoveredMedia.reconfiguredScales == [2.0], "the settled scale is attempted once")
        expect(recoveredMedia.stopCount == 0, "a reconfiguration that recovered to the previous scale keeps streaming")
        expect(recoveredSession.isActive, "a reconfiguration that recovered to the previous scale keeps the canvas")
        expect(
            recoveredEvents.messages.contains { $0.contains("stream scale") },
            "a reconfiguration that could not take effect is reported, never silently dropped"
        )

        let brokenMedia = FakeScalableCanvasMedia()
        brokenMedia.reconfigurationFailure = FakeMediaFailure.captureUnavailable
        let brokenEvents = DiagnosticsRecorder()
        let brokenSession = VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())
        let brokenWorkspace = FakeCanvasWorkspace()
        let brokenTeardowns = DiagnosticsRecorder()
        let brokenCoordinator = HostSessionCoordinator(
            controller: HostSessionController(sessions: surfaceZeroOnly(brokenSession), keyConfinement: .unconfined, privateDesktopOffered: { true }),
            media: onlyOnSurfaceZero(brokenMedia),
            videoSink: FakeVideoSink(),
            workspaces: onlyOnSurfaceZero(brokenWorkspace),
            streamScaleSettleSeconds: 0.05,
            onEvent: { brokenEvents.record($0) },
            onStreamUnrecoverable: { brokenTeardowns.record($0) }
        )
        _ = try! await brokenCoordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        _ = try! await brokenCoordinator.handleWritingResponse(.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil))
        try! await Task.sleep(for: .milliseconds(400))
        expect(brokenMedia.stopCount == 1, "a stream that could not be restored is torn down, never left dead or black")
        expect(brokenWorkspace.stopCount == 1, "the workspace comes down with the stream it could not restore")
        expect(!brokenSession.isActive, "an unrecoverable reconfiguration releases the canvas rather than orphaning it")
        expect(
            brokenEvents.messages.contains { $0.contains("stream scale") },
            "an unrecoverable reconfiguration fails loudly"
        )
        expect(
            brokenTeardowns.messages == ["stream-reconfiguration-failed"],
            "the connection is dropped so the client redials instead of holding a frozen picture forever"
        )

        // The viewer's own cap is the second ceiling: the viewer's geometry
        // justifies 2.0x and the encoder can hold it, and the stream still
        // lands at 1.25x because that is the scale the viewer asked for.
        // Lifting the cap must give the resolution back without a resize.
        do {
            let cappedMedia = FakeScalableCanvasMedia()
            let cappedEvents = DiagnosticsRecorder()
            let cappedCoordinator = HostSessionCoordinator(
                controller: HostSessionController(sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())), keyConfinement: .unconfined, privateDesktopOffered: { true }),
                media: onlyOnSurfaceZero(cappedMedia),
                videoSink: FakeVideoSink(),
                streamScaleSettleSeconds: 0.05,
                onEvent: { cappedEvents.record($0) }
            )
            _ = try! await cappedCoordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
            _ = try! await cappedCoordinator.handleWritingResponse(
                .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: 1.25)
            )
            expect(
                await waitUntil(timeoutSeconds: 2) { cappedMedia.reconfiguredScales == [1.25] },
                "a viewer that caps itself at 1.25x is streamed 1.25x, not the 2.0x its window would otherwise justify"
            )
            expect(
                cappedEvents.messages.contains { $0.contains("clamped") && $0.contains("viewer\u{2019}s own maximum") },
                "the cap is reported as the viewer's own choice, not as a measured limit of this machine"
            )
            expect(
                await cappedCoordinator.appliedStreamScale(for: surfaceZero) == 1.25
                    && cappedCoordinator.sustainableScaleCeiling(for: surfaceZero) == nil,
                "a user cap is not a measured fidelity limit: telemetry reports the applied scale with no ceiling"
            )

            _ = try! await cappedCoordinator.handleWritingResponse(
                .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil)
            )
            expect(
                await waitUntil(timeoutSeconds: 2) { cappedMedia.reconfiguredScales == [1.25, 2.0] },
                "lifting the cap restores the scale the window justifies, with no resize needed"
            )
        }
        print("PASS: a viewer's own maximum scale caps the stream and lifting it gives the resolution back")

        // A pipeline rebuild is a real, visible gap -- a window enumeration,
        // a torn-down and recreated VTCompressionSession -- so a
        // viewer-geometry request within one quantum of what is already
        // streaming is not worth it. The very first request is exempt: there
        // is no real applied scale yet to measure a small delta against,
        // only the arbitrary startup default, so it always goes through.
        do {
            let smallDeltaMedia = FakeScalableCanvasMedia()
            let smallDeltaCoordinator = HostSessionCoordinator(
                controller: HostSessionController(sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())), keyConfinement: .unconfined, privateDesktopOffered: { true }),
                media: onlyOnSurfaceZero(smallDeltaMedia),
                videoSink: FakeVideoSink(),
                streamScaleSettleSeconds: 0.05
            )
            _ = try! await smallDeltaCoordinator.handleWritingResponse(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
            // First-ever request: 1.25x, a single quantum away from the
            // 1.0x startup default, still goes through.
            _ = try! await smallDeltaCoordinator.handleWritingResponse(.viewerDrawableSize(pixelWidth: 2400, pixelHeight: 1500, surfaceID: nil, maximumScale: nil))
            expect(
                await waitUntil(timeoutSeconds: 2) { smallDeltaMedia.reconfiguredScales == [1.25] },
                "the first-ever geometry-derived request is never suppressed, however small its distance from the arbitrary startup default"
            )
            // A later request one quantum away from what is now actually
            // applied (1.25 -> 1.5) is not worth a rebuild.
            _ = try! await smallDeltaCoordinator.handleWritingResponse(.viewerDrawableSize(pixelWidth: 2880, pixelHeight: 1800, surfaceID: nil, maximumScale: nil))
            try! await Task.sleep(for: .milliseconds(300))
            expect(
                smallDeltaMedia.reconfiguredScales == [1.25],
                "a later request only one quantum away from what is already applied never reaches reconfigure"
            )
            // The next request lands two quanta away from what is still
            // actually applied (1.25 -> 2.0, since the nudge above never
            // took effect) -- worth the rebuild, and it catches up to the
            // latest request, not to the skipped intermediate one.
            _ = try! await smallDeltaCoordinator.handleWritingResponse(.viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: nil, maximumScale: nil))
            expect(
                await waitUntil(timeoutSeconds: 2) { smallDeltaMedia.reconfiguredScales == [1.25, 2.0] },
                "a request two or more quanta away from what is actually applied still reconfigures, landing on the latest request"
            )
        }
        print("PASS: a viewer-geometry request within one quantum of what is already applied is never worth a rebuild, except the first")

        // Two session-owned canvases
        //
        // A second canvasRequest must get its own display, its own stream and
        // its own workspace window. Without per-surface state,
        // `VirtualDisplaySession.start` would hand back canvas 0's handle,
        // `startStreaming`'s session-wide `isStreaming` guard would skip the
        // second stream, and the single workspace would close canvas A's
        // window to open canvas B's -- so surface 1 would get a
        // correctly-signed canvasReady and show nothing.
        do {
            let dualAdapter = FakeVirtualDisplayAdapter()
            dualAdapter.handleValuesToVend = [7, 8]
            // One gate for both canvases, exactly as `sensoriumd` wires it:
            // creating a canvas while another creation is in flight is what
            // corrupts the display-ID allocator.
            let dualGate = CanvasCreationGate()
            let dualSessions = CanvasSurfaceSlots { _ in
                VirtualDisplaySession(adapter: dualAdapter, creationGate: dualGate)
            }
            let dualMediaA = FakeScalableCanvasMedia()
            let dualMediaB = FakeScalableCanvasMedia()
            let dualWorkspaceA = InterleavingCanvasWorkspace(gate: dualGate)
            let dualWorkspaceB = InterleavingCanvasWorkspace(gate: dualGate)
            let creationOrder = DiagnosticsRecorder()
            dualAdapter.onAcquire = { creationOrder.record("acquire") }
            dualWorkspaceA.pump = { creationOrder.record("workspace-0-placement-in-flight") }
            dualWorkspaceB.pump = { creationOrder.record("workspace-1-placement-in-flight") }
            let dualEnded = DiagnosticsRecorder()
            let dualCoordinator = HostSessionCoordinator(
                controller: HostSessionController(sessions: dualSessions, keyConfinement: .unconfined, privateDesktopOffered: { true }),
                media: CanvasSurfaceSlots(surface0: dualMediaA, surface1: dualMediaB),
                videoSink: FakeVideoSink(),
                workspaces: CanvasSurfaceSlots(surface0: dualWorkspaceA, surface1: dualWorkspaceB),
                streamScaleSettleSeconds: 0.05,
                onSessionEnded: { dualEnded.record("session-ended") }
            )

            let readyA = try! await dualCoordinator.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 0)
            )
            let readyB = try! await dualCoordinator.handleWritingResponse(
                .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 1)
            )
            guard case let .canvasReady(displayA, _, _, _, surfaceA, _) = readyA,
                  case let .canvasReady(displayB, _, _, _, surfaceB, _) = readyB else {
                expect(false, "both canvas requests are answered with a canvasReady")
                return
            }
            expect(surfaceA == 0 && surfaceB == 1, "each canvasReady names the surface it answers")
            expect(displayA == 7 && displayB == 8, "surface 1 gets its own display, never surface 0's")
            expect(
                dualMediaA.startedDisplayIDs == [displayA] && dualMediaB.startedDisplayIDs == [displayB],
                "both surfaces actually stream, each on its own canvas: the second is not skipped by a session-wide isStreaming guard"
            )
            expect(
                dualWorkspaceA.startedDisplayIDs == [displayA] && dualWorkspaceB.startedDisplayIDs == [displayB],
                "each surface gets its own workspace window on its own canvas"
            )
            // Creation is strictly sequential: surface 1's acquire begins only
            // after surface 0's placement -- the whole span the shared gate
            // holds -- has finished. Overlap here is the interleaving that
            // permanently corrupts this process's display-ID allocator, and
            // the gate would have rejected the second request outright.
            expect(
                creationOrder.messages == [
                    "acquire",
                    "workspace-0-placement-in-flight",
                    "acquire",
                    "workspace-1-placement-in-flight",
                ],
                "the two canvas creations run one after the other, neither overlapping nor rejected by the shared single-flight gate"
            )

            // Resizing one viewer window must rebuild only that surface's
            // encoder. A session-wide debouncer and a media pipeline with no
            // surface of its own would rebuild the other canvas at this
            // canvas's scale.
            _ = try! await dualCoordinator.handleWritingResponse(
                .viewerDrawableSize(pixelWidth: 3840, pixelHeight: 2400, surfaceID: 1, maximumScale: nil)
            )
            try! await Task.sleep(for: .milliseconds(400))
            expect(
                dualMediaB.reconfiguredScales == [2.0],
                "a viewerDrawableSize for surface 1 reconfigures surface 1's encoder"
            )
            expect(
                dualMediaA.reconfiguredScales.isEmpty,
                "and leaves surface 0's stream scale untouched"
            )

            // A third surface is still refused: the cap is a property of the
            // host's storage, not a bounds check a later change can forget.
            do {
                _ = try await dualCoordinator.handleWritingResponse(
                    .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: 2)
                )
                expect(false, "a third surface is rejected")
            } catch let error as HostSessionControllerError {
                expect(error == .invalidCanvasRequest, "a third surface is rejected as an invalid canvas request")
            } catch {
                expect(false, "a third surface is rejected with the canvas-request error, not something else")
            }

            // A differently sized canvas fails loudly. Silently substituting a
            // default-sized display would leave the client rendering a canvas
            // that is not the size it asked for, and every input event inside
            // it would be dropped as out of bounds.
            let sizeMismatchAdapter = FakeVirtualDisplayAdapter()
            let sizeMismatchSessions = CanvasSurfaceSlots { _ in
                VirtualDisplaySession(adapter: sizeMismatchAdapter)
            }
            let sizeMismatchController = HostSessionController(sessions: sizeMismatchSessions, keyConfinement: .unconfined, privateDesktopOffered: { true })
            expectThrows(
                HostSessionControllerError.invalidCanvasRequest,
                { _ = try sizeMismatchController.handle(.canvasRequest(logicalWidth: 1280, logicalHeight: 800, scale: 2, surfaceID: 1)) },
                "a differently sized canvas request is refused outright"
            )
            expect(
                sizeMismatchAdapter.acquiredConfigurations.isEmpty,
                "and never silently receives a default-sized display instead"
            )

            // Teardown: every surface's workspace window must be gone before
            // any canvas display is released, or AppKit may move a surviving
            // window onto a physical monitor.
            let teardownOrder = DiagnosticsRecorder()
            dualWorkspaceA.onStop = { teardownOrder.record("workspace-stop-0") }
            dualWorkspaceB.onStop = { teardownOrder.record("workspace-stop-1") }
            dualAdapter.onRelease = { teardownOrder.record("display-release-\($0.rawValue)") }

            _ = try! await dualCoordinator.handleWritingResponse(.goodbye(reason: "client-disconnected"))

            expect(
                teardownOrder.messages == [
                    "workspace-stop-0",
                    "workspace-stop-1",
                    "display-release-7",
                    "display-release-8",
                ],
                "both workspace windows come down before either canvas display is released"
            )
            expect(
                dualMediaA.stopCount == 1 && dualMediaB.stopCount == 1,
                "both surfaces stop capturing exactly once"
            )
            expect(
                dualSessions[CanvasSurfaceID.allCases[0]].isActive == false
                    && dualSessions[CanvasSurfaceID.allCases[1]].isActive == false,
                "neither canvas is left orphaned"
            )
            expect(
                dualEnded.messages == ["session-ended"],
                "session end is signalled exactly once per session, not once per surface"
            )

            await dualCoordinator.sessionDidEnd(reason: "transport-closed")
            expect(
                teardownOrder.messages.count == 4,
                "a transport teardown arriving after a goodbye does not run the ordered teardown a second time"
            )
            expect(dualEnded.messages == ["session-ended"], "and does not signal session end again")
        }
}

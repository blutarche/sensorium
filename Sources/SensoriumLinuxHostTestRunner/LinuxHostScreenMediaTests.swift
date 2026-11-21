#if os(Linux)
import Foundation
import SensoriumClient
import SensoriumCore
import SensoriumHost
import SensoriumLinuxHost

/// What the media handed the session's sender, and whether it was taken.
final class SentPackets: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [EncodedVideoFramePacket] = []
    private var accepting = true

    var packets: [EncodedVideoFramePacket] { lock.withLock { stored } }
    var count: Int { lock.withLock { stored.count } }

    func refuse() { lock.withLock { accepting = false } }

    func take(_ packet: EncodedVideoFramePacket) -> Bool {
        lock.withLock {
            stored.append(packet)
            return accepting
        }
    }
}

/// The picture sizes the viewer's own decoder gets out of `packets`.
func decodedSizes(_ packets: [EncodedVideoFramePacket]) throws -> [String] {
    final class Sizes: @unchecked Sendable {
        let lock = NSLock()
        var stored: [String] = []
    }
    let sizes = Sizes()
    let decoder = AVCodecVideoDecoder(renderNodePath: nil, outputHandler: { frame in
        sizes.lock.withLock { sizes.stored.append("\(frame.width)x\(frame.height)") }
    })
    for packet in packets {
        try decoder.decode(packet)
    }
    return sizes.lock.withLock { sizes.stored }
}

/// Waits up to `seconds` for `condition`.
@MainActor
func eventually(_ seconds: TimeInterval = 5, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Fails the run unless `condition` holds within five seconds.
@MainActor
func expectEventually(_ message: String, _ condition: () async -> Bool) async {
    let held = await eventually(5, condition)
    expect(held, message)
}

@MainActor
private struct MediaRig {
    let source = ScriptedFrameSource()
    let grantState = PortalGrantState()
    let feed: LinuxScreenFeed
    let recorder = HostMediaLatencyRecorder()
    let sendFeedback = VideoSendFeedback()
    let sent = SentPackets()
    let media: LinuxHostScreenMedia

    init(logicalWidth: Int = 128, logicalHeight: Int = 64, backingScale: Double = 2, heartbeat: TimeInterval = 0.5) async {
        grantState.install(grant: liveGrant(), sink: RecordingSink())
        feed = LinuxScreenFeed(source: source, grantState: grantState)
        try? await feed.start()
        let configuration = HostScreenEncoderSizing.resolve(
            for: SessionSurfaceGeometry(logicalWidth: logicalWidth, logicalHeight: logicalHeight, backingScale: backingScale)
        ).configuration
        media = LinuxHostScreenMedia(
            configuration: configuration,
            sequencer: VideoPacketSequencer(),
            feed: feed,
            latencyRecorder: recorder,
            sendFeedback: sendFeedback,
            backendPreference: .openH264,
            heartbeatInterval: heartbeat
        )
    }

    func start() async {
        let sent = sent
        do {
            try await media.start(canvasDisplayID: 1, onPacket: { sent.take($0) })
        } catch {
            expect(false, "the media starts, threw \(error)")
        }
    }

    func push(width: Int = 256, height: Int = 128, level: UInt8 = 128) {
        source.push(flatCapturedFrame(width: width, height: height, level: level, padding: 16))
    }
}

@MainActor
private func testTheScreenIsEncodedAtItsLogicalSizeFromTheFrameAlreadyOnScreen() async {
    let rig = await MediaRig()
    rig.source.report(.streaming)
    rig.push()
    await rig.start()
    await expectEventually("the frame on screen when the session began was encoded without waiting for a change") { rig.sent.count >= 1 }
    let first = rig.sent.packets[0]
    expect(first.isKeyFrame && first.codecConfiguration != nil, "the first packet is a key frame with parameter sets")
    let sizes = (try? decodedSizes([first])) ?? []
    expect(sizes == ["128x64"], "a 2x buffer is encoded at the logical size, saw \(sizes)")
    let counts = await rig.media.frameCounts
    expect(counts.captured >= 1 && counts.encoded >= 1, "the capture and the encode are counted, saw \(counts)")
    await rig.media.stop()
}

@MainActor
private func testTheLastFrameOfABurstIsAlwaysEncoded() async {
    let rig = await MediaRig()
    await rig.start()
    let pushed = FeedLog()
    let watching = rig.feed.subscribe(onFrame: pushed.frame, onState: pushed.state)
    for level in stride(from: UInt8(10), through: 70, by: 10) {
        rig.push(level: level)
    }
    await expectEventually("the burst produced packets") { rig.sent.count >= 1 }
    try? await Task.sleep(for: .milliseconds(300))
    watching.cancel()
    let packets = rig.sent.packets
    let sequences = packets.map(\.sequence)
    expect(sequences == Array(0..<UInt64(packets.count)), "packets count up without a gap, saw \(sequences)")
    expect(packets.count < 7, "frames that arrived while one was encoding were folded into the newest, saw \(packets.count)")
    let lastStamp = pushed.frames.last.map { UInt64($0.presentationTimeNanoseconds) }
    expect(packets.last?.presentationTimeNanoseconds == lastStamp, "the burst's last frame is the last one sent")
    let counts = await rig.media.frameCounts
    expect(counts.captured == 7, "every frame of the burst was counted as captured, saw \(counts.captured)")
    expect(counts.encoded == packets.count, "and each packet as encoded")
    await rig.media.stop()
}

@MainActor
private func testFramesWaitWhileTheSendSlotIsFullAndTheNewestGoesWhenItEmpties() async {
    let rig = await MediaRig()
    await rig.start()
    rig.push(level: 10)
    await expectEventually("the first frame went out") { rig.sent.count == 1 }
    let surface = CanvasSurfaceID.allCases[0]
    rig.sendFeedback.setWaitingSlotOccupied(true, on: surface)
    rig.push(level: 20)
    rig.push(level: 30)
    try? await Task.sleep(for: .milliseconds(300))
    expect(rig.sent.count == 1, "nothing is encoded while the send queue's waiting slot is full")
    expect(rig.sendFeedback.capturesDroppedForTheLink(on: surface) == 1, "the frame the newer one replaced is counted against the link")
    rig.sendFeedback.setWaitingSlotOccupied(false, on: surface)
    rig.sendFeedback.waitingSlotEmptied(on: surface)
    await expectEventually("the newest frame went out once the slot emptied") { rig.sent.count == 2 }
    try? await Task.sleep(for: .milliseconds(200))
    expect(rig.sent.count == 2, "only the newest frame, not the one it replaced")
    await rig.media.stop()
}

@MainActor
private func testAKeyFrameRequestFromTheSendQueueMakesTheNextFrameAKeyFrame() async {
    let rig = await MediaRig()
    try? await rig.media.apply(framesPerSecond: 1000)
    await rig.start()
    rig.push(level: 10)
    await expectEventually("first frame") { rig.sent.count == 1 }
    rig.push(level: 20)
    await expectEventually("second frame") { rig.sent.count == 2 }
    expect(!rig.sent.packets[1].isKeyFrame, "a plain change is a delta")
    rig.sendFeedback.requestKeyFrame(on: CanvasSurfaceID.allCases[0])
    try? await Task.sleep(for: .milliseconds(50))
    rig.push(level: 30)
    await expectEventually("third frame") { rig.sent.count == 3 }
    expect(rig.sent.packets[2].isKeyFrame, "after the send queue lost a frame the next one is a key frame")
    await rig.media.stop()
}

@MainActor
private func testAStreamScaleChangeRebuildsAtTheNewSizeAndKeepsTheSequence() async {
    let rig = await MediaRig()
    await rig.start()
    rig.push()
    await expectEventually("first frame") { rig.sent.count == 1 }
    do {
        try await rig.media.reconfigure(streamScale: 0.5)
    } catch {
        expect(false, "the rebuild at half scale works, threw \(error)")
    }
    expect(rig.media.currentStreamScale == 0.5, "the media reports the scale it now streams")
    await expectEventually("the picture on screen was sent again at the new size without waiting for a change") { rig.sent.count == 2 }
    let packets = rig.sent.packets
    expect(packets[1].sequence == 1 && packets[1].isKeyFrame, "the rebuilt encoder continues the sequence with a key frame")
    let sizes = (try? decodedSizes(packets)) ?? []
    expect(sizes == ["128x64", "64x32"], "the viewer's decoder sees the new size, saw \(sizes)")
    await rig.media.stop()
}

@MainActor
private func testAnOddLogicalSizeIsEncodedAtTheEvenSizeBelowIt() async {
    let rig = await MediaRig(logicalWidth: 179, logicalHeight: 99, backingScale: 1)
    await rig.start()
    rig.push(width: 179, height: 99)
    await expectEventually("an odd-sized screen still streams") { rig.sent.count == 1 }
    let sizes = (try? decodedSizes(rig.sent.packets)) ?? []
    expect(sizes == ["178x98"], "it is encoded one pixel smaller on each odd side, saw \(sizes)")
    await rig.media.stop()
}

@MainActor
private func testAStillScreenOnALiveStreamIsCountedAsNoChange() async {
    let rig = await MediaRig(heartbeat: 0.1)
    rig.source.report(.streaming)
    await rig.start()
    rig.push()
    await expectEventually("first frame") { rig.sent.count == 1 }
    await expectEventually("a still screen on a live stream is counted as delivering no change") { await rig.media.frameCounts.noChangeNotices >= 3 }
    rig.source.report(.paused)
    try? await Task.sleep(for: .milliseconds(150))
    let paused = await rig.media.frameCounts.noChangeNotices
    try? await Task.sleep(for: .milliseconds(400))
    let stillPaused = await rig.media.frameCounts.noChangeNotices
    expect(stillPaused == paused, "a stream that is not live counts nothing, so a dead capture still reads as silent")
    await rig.media.stop()
}

@MainActor
private func testAStillRefreshSendsTheLastFrameAgainAsAKeyFrame() async {
    let rig = await MediaRig()
    try? await rig.media.apply(framesPerSecond: 1000)
    await rig.start()
    let nothing = try? await rig.media.refreshStillPicture()
    expect(nothing == .some(nil), "before any frame there is nothing to refresh")
    rig.push(level: 10)
    rig.push(level: 20)
    await expectEventually("frames went out") { rig.sent.count >= 1 }
    try? await Task.sleep(for: .milliseconds(200))
    let before = rig.sent.count
    let size = try? await rig.media.refreshStillPicture()
    expect((size ?? nil).map { $0 > 0 } == true, "the refresh reports the size of the frame that went out")
    expect(rig.sent.count == before + 1 && rig.sent.packets.last?.isKeyFrame == true, "the refresh is one key frame")
    let hostRequested = await rig.media.frameCounts.hostRequested
    expect(hostRequested == 1, "it is counted as the host's own frame, not the screen changing")
    rig.sent.refuse()
    do {
        _ = try await rig.media.refreshStillPicture()
        expect(false, "a refresh the transport refused is not reported as sent")
    } catch {}
    await rig.media.stop()
}

@MainActor
private func testAFailedStreamReportsTheCaptureStoppedOnce() async {
    let rig = await MediaRig()
    final class Count: @unchecked Sendable {
        let lock = NSLock()
        var value = 0
    }
    let stops = Count()
    rig.media.setCaptureStoppedHandler { stops.lock.withLock { stops.value += 1 } }
    await rig.start()
    rig.source.report(.failed("gone"))
    rig.source.report(.failed("gone again"))
    expect(stops.lock.withLock { stops.value } == 1, "a failed stream tells the coordinator once")
    await rig.media.stop()
}

@MainActor
private func testStopEndsEncoding() async {
    let rig = await MediaRig()
    await rig.start()
    rig.push()
    await expectEventually("first frame") { rig.sent.count == 1 }
    await rig.media.stop()
    rig.push(level: 99)
    try? await Task.sleep(for: .milliseconds(200))
    expect(rig.sent.count == 1, "a stopped media sends nothing")
}

func linuxHostScreenMediaTests() -> [NamedTest] { [
    ("the screen is encoded at its logical size from the frame already on screen", testTheScreenIsEncodedAtItsLogicalSizeFromTheFrameAlreadyOnScreen),
    ("the last frame of a burst is always encoded", testTheLastFrameOfABurstIsAlwaysEncoded),
    ("frames wait while the send slot is full and the newest goes when it empties", testFramesWaitWhileTheSendSlotIsFullAndTheNewestGoesWhenItEmpties),
    ("a key frame request from the send queue makes the next frame a key frame", testAKeyFrameRequestFromTheSendQueueMakesTheNextFrameAKeyFrame),
    ("a stream scale change rebuilds at the new size and keeps the sequence", testAStreamScaleChangeRebuildsAtTheNewSizeAndKeepsTheSequence),
    ("an odd logical size is encoded at the even size below it", testAnOddLogicalSizeIsEncodedAtTheEvenSizeBelowIt),
    ("a still screen on a live stream is counted as no change", testAStillScreenOnALiveStreamIsCountedAsNoChange),
    ("a still refresh sends the last frame again as a key frame", testAStillRefreshSendsTheLastFrameAgainAsAKeyFrame),
    ("a failed stream reports the capture stopped once", testAFailedStreamReportsTheCaptureStoppedOnce),
    ("stop ends encoding", testStopEndsEncoding)
] }
#endif

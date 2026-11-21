#if os(Linux)
import Foundation
import SensoriumLinuxHost

/// A frame source a test pushes frames and states through by hand.
final class ScriptedFrameSource: LinuxFrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var onFrame: (@Sendable (CapturedFrame) -> Void)?
    private var onState: (@Sendable (CaptureState) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func start(
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onState: @escaping @Sendable (CaptureState) -> Void
    ) async throws {
        lock.withLock {
            self.onFrame = onFrame
            self.onState = onState
            startCount += 1
        }
    }

    func stop() {
        lock.withLock {
            onFrame = nil
            onState = nil
            stopCount += 1
        }
    }

    func push(_ frame: CapturedFrame) {
        lock.withLock { onFrame }?(frame)
    }

    func report(_ state: CaptureState) {
        lock.withLock { onState }?(state)
    }
}

/// A flat BGRx frame of `width` by `height` in one gray level.
func flatCapturedFrame(width: Int, height: Int, level: UInt8 = 128, padding: Int = 0) -> CapturedFrame {
    let stride = width * 4 + padding
    return CapturedFrame(
        pixels: Data(repeating: level, count: stride * height),
        width: width,
        height: height,
        stride: stride,
        format: .bgrx,
        presentationTimeNanoseconds: 5,
        cursor: nil
    )
}

/// Collects a feed subscriber's deliveries.
final class FeedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storedFrames: [ScreenFeedFrame] = []
    private var storedStates: [CaptureState] = []

    var frames: [ScreenFeedFrame] { lock.withLock { storedFrames } }
    var states: [CaptureState] { lock.withLock { storedStates } }

    func frame(_ frame: ScreenFeedFrame) { lock.withLock { storedFrames.append(frame) } }
    func state(_ state: CaptureState) { lock.withLock { storedStates.append(state) } }
}

private final class Ticker: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int64 = 1_000

    func next() -> Int64 {
        lock.withLock {
            value += 1_000
            return value
        }
    }
}

private func liveFeed(_ source: ScriptedFrameSource, grantState: PortalGrantState, clock: Ticker = Ticker()) async -> LinuxScreenFeed {
    grantState.install(grant: liveGrant(), sink: RecordingSink())
    let feed = LinuxScreenFeed(source: source, grantState: grantState, nowNanoseconds: { clock.next() })
    do {
        try await feed.start()
    } catch {
        expect(false, "the scripted source starts, threw \(error)")
    }
    return feed
}

private func testANewSubscriberGetsTheLatestFrameAgainStampedNow() async {
    let source = ScriptedFrameSource()
    let grantState = PortalGrantState()
    let feed = await liveFeed(source, grantState: grantState)
    source.report(.streaming)
    source.push(flatCapturedFrame(width: 64, height: 32, level: 10))
    source.push(flatCapturedFrame(width: 64, height: 32, level: 20))
    let log = FeedLog()
    let subscription = feed.subscribe(onFrame: log.frame, onState: log.state)
    expect(log.frames.count == 1, "the subscriber was handed the frame on screen now, saw \(log.frames.count)")
    expect(log.frames.first?.pixels.first == 20, "it is the latest frame")
    expect(log.states == [.streaming], "and the stream's current state")
    let replayStamp = log.frames.first?.presentationTimeNanoseconds ?? 0
    source.push(flatCapturedFrame(width: 64, height: 32, level: 30))
    expect(log.frames.count == 2, "later frames follow")
    let liveStamp = log.frames.last?.presentationTimeNanoseconds ?? 0
    expect(replayStamp > 0 && liveStamp > replayStamp, "stamps come from the host's clock and never go back, saw \(replayStamp) then \(liveStamp)")
    subscription.cancel()
    source.push(flatCapturedFrame(width: 64, height: 32, level: 40))
    expect(log.frames.count == 2, "a cancelled subscription gets nothing more")
    feed.stop()
}

private func testFramesRecordTheirSizeAndOnlyPicturesAreDelivered() async {
    let source = ScriptedFrameSource()
    let grantState = PortalGrantState()
    let feed = await liveFeed(source, grantState: grantState)
    let log = FeedLog()
    let subscription = feed.subscribe(onFrame: log.frame, onState: log.state)
    source.push(CapturedFrame(pixels: nil, width: 0, height: 0, stride: 0, format: .bgrx, presentationTimeNanoseconds: nil, cursor: nil))
    expect(log.frames.isEmpty, "a cursor-only update carries no picture and is not a frame")
    source.push(flatCapturedFrame(width: 3840, height: 2160, padding: 64))
    expect(log.frames.count == 1, "a picture is a frame")
    let size = grantState.live?.frameSize
    expect(size?.width == 3840 && size?.height == 2160, "the frame's size is recorded for the display inventory")
    subscription.cancel()
    feed.stop()
}

private func testStoppingTheFeedStopsTheSourceAndTellsEverySubscriber() async {
    let source = ScriptedFrameSource()
    let grantState = PortalGrantState()
    let feed = await liveFeed(source, grantState: grantState)
    let log = FeedLog()
    _ = feed.subscribe(onFrame: log.frame, onState: log.state)
    source.report(.failed("the compositor went away"))
    expect(log.states.last == .failed("the compositor went away"), "a failed stream is passed on")
    feed.stop()
    expect(source.stopCount == 1, "the source was stopped")
    if case .failed? = log.states.last {} else {
        expect(false, "a stopped feed reads as failed to whoever still listens, saw \(log.states)")
    }
    let late = FeedLog()
    _ = feed.subscribe(onFrame: late.frame, onState: late.state)
    expect(late.frames.isEmpty, "a stopped feed replays no frame")
}

func screenFeedTests() -> [NamedTest] { [
    ("a new feed subscriber gets the latest frame again, stamped now", testANewSubscriberGetsTheLatestFrameAgainStampedNow),
    ("feed frames record their size and only pictures are delivered", testFramesRecordTheirSizeAndOnlyPicturesAreDelivered),
    ("stopping the feed stops the source and tells every subscriber", testStoppingTheFeedStopsTheSourceAndTellsEverySubscriber)
] }
#endif

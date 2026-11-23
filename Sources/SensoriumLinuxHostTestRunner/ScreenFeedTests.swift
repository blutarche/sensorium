#if os(Linux)
import Foundation
import SensoriumLinuxHost

/// A frame source a test pushes frames and states through by hand. Like a
/// screencast producer it sends the picture on screen as soon as it starts,
/// and a pushed frame becomes that picture even while the source is stopped.
final class ScriptedFrameSource: LinuxFrameSource, @unchecked Sendable {
    private let lock = NSLock()
    private var onFrame: (@Sendable (CapturedFrame) -> Void)?
    private var onState: (@Sendable (CaptureState) -> Void)?
    private var screen: CapturedFrame?
    private var holdsStarts = false
    private var waitingStart: CheckedContinuation<Void, Never>?
    private var starts = 0
    private var stops = 0

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    var isRunning: Bool { lock.withLock { onFrame != nil } }
    var isStartWaiting: Bool { lock.withLock { waitingStart != nil } }

    /// Makes every later start wait until `releaseStart()`, as a start
    /// waiting on the portal does.
    func holdStarts() {
        lock.withLock { holdsStarts = true }
    }

    func releaseStart() {
        let waiting = lock.withLock {
            holdsStarts = false
            defer { waitingStart = nil }
            return waitingStart
        }
        waiting?.resume()
    }

    func start(
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onState: @escaping @Sendable (CaptureState) -> Void
    ) async throws {
        let waits = lock.withLock {
            starts += 1
            return holdsStarts
        }
        if waits {
            await withCheckedContinuation { continuation in
                lock.withLock { waitingStart = continuation }
            }
        }
        let current = lock.withLock {
            self.onFrame = onFrame
            self.onState = onState
            return screen
        }
        if let current {
            onFrame(current)
        }
    }

    func stop() {
        lock.withLock {
            if onFrame != nil { stops += 1 }
            onFrame = nil
            onState = nil
        }
    }

    func push(_ frame: CapturedFrame) {
        let handler = lock.withLock {
            if frame.pixels != nil { screen = frame }
            return onFrame
        }
        handler?(frame)
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
    let generation = grantState.install(grant: liveGrant(), sink: RecordingSink())
    let feed = LinuxScreenFeed(
        source: source, grantState: grantState, streamNodeID: grantedMonitor.nodeID,
        generation: generation, nowNanoseconds: { clock.next() }
    )
    do {
        try await feed.start()
    } catch {
        expect(false, "the scripted source starts, threw \(error)")
    }
    return feed
}

/// Waits up to five seconds for `condition`, off the main actor.
private func settles(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// Lets any pending start or stop of the source run, then reads the counts.
private func settled(_ source: ScriptedFrameSource) async -> (starts: Int, stops: Int) {
    try? await Task.sleep(for: .milliseconds(100))
    return (source.startCount, source.stopCount)
}

/// A started feed whose grant-time probe has seen its first frame.
private func probedFeed(_ source: ScriptedFrameSource, grantState: PortalGrantState, clock: Ticker = Ticker()) async -> LinuxScreenFeed {
    let feed = await liveFeed(source, grantState: grantState, clock: clock)
    source.report(.streaming)
    source.push(flatCapturedFrame(width: 64, height: 32, level: 10))
    let stopped = await settles { !source.isRunning }
    expect(stopped, "the probe stops the source after its first frame")
    return feed
}

private func testTheGrantProbeStopsTheSourceAfterItsFirstFrame() async {
    let source = ScriptedFrameSource()
    let grantState = PortalGrantState()
    let feed = await liveFeed(source, grantState: grantState)
    expect(source.startCount == 1 && source.isRunning, "the grant starts the source to learn the monitor's size")
    source.report(.streaming)
    source.push(flatCapturedFrame(width: 2560, height: 1440))
    let stopped = await settles { !source.isRunning }
    expect(stopped && source.stopCount == 1, "with nobody watching, the source stops after the first frame")
    let size = grantState.live?.routableMonitors.first?.monitor.frameSize
    expect(size?.width == 2560 && size?.height == 1440, "the frame's size is recorded for the display inventory")
    let counts = await settled(source)
    expect(counts == (1, 1), "and nothing starts it again, saw \(counts)")
    feed.stop()
}

private func testTheFirstSubscriberStartsTheSourceAndGetsTheFirstFrame() async {
    let source = ScriptedFrameSource()
    let grantState = PortalGrantState()
    let feed = await probedFeed(source, grantState: grantState)
    source.push(flatCapturedFrame(width: 64, height: 32, level: 20))
    source.holdStarts()
    let log = FeedLog()
    let subscription = feed.subscribe(onFrame: log.frame, onState: log.state)
    expect(log.states == [.connecting] && log.frames.isEmpty, "a subscriber waits on a stopped source, saw \(log.states) and \(log.frames.count) frames")
    _ = await settles { source.isStartWaiting }
    source.releaseStart()
    let started = await settles { source.isRunning }
    expect(started && source.startCount == 2, "the first subscriber starts the source")
    let first = await settles { log.frames.count == 1 }
    expect(first && log.frames.first?.pixels.first == 20, "and gets the picture the stream starts with")
    source.report(.streaming)
    source.push(flatCapturedFrame(width: 64, height: 32, level: 30))
    expect(log.frames.map { $0.pixels.first ?? 0 } == [20, 30], "later frames follow, saw \(log.frames.count)")
    expect(log.states == [.connecting, .streaming], "the state follows the stream, saw \(log.states)")
    subscription.cancel()
    feed.stop()
}

private func testASecondSubscriberGetsTheLatestFrameStampedNow() async {
    let source = ScriptedFrameSource()
    let grantState = PortalGrantState()
    let feed = await probedFeed(source, grantState: grantState)
    let first = FeedLog()
    let firstSubscription = feed.subscribe(onFrame: first.frame, onState: first.state)
    _ = await settles { first.frames.count == 1 }
    source.push(flatCapturedFrame(width: 64, height: 32, level: 20))
    let log = FeedLog()
    let subscription = feed.subscribe(onFrame: log.frame, onState: log.state)
    expect(log.frames.count == 1 && log.frames.first?.pixels.first == 20, "a subscriber joining a running stream is handed the latest frame")
    let replayStamp = log.frames.first?.presentationTimeNanoseconds ?? 0
    let liveStamp = first.frames.last?.presentationTimeNanoseconds ?? 0
    expect(replayStamp > liveStamp, "stamped when it was handed over, saw \(replayStamp) after \(liveStamp)")
    subscription.cancel()
    firstSubscription.cancel()
    feed.stop()
}

private func testTheLastSubscriberLeavingStopsTheSource() async {
    let source = ScriptedFrameSource()
    let grantState = PortalGrantState()
    let feed = await probedFeed(source, grantState: grantState)
    let first = FeedLog()
    let second = FeedLog()
    let firstSubscription = feed.subscribe(onFrame: first.frame, onState: first.state)
    let secondSubscription = feed.subscribe(onFrame: second.frame, onState: second.state)
    _ = await settles { source.isRunning }
    firstSubscription.cancel()
    let stillWatched = await settled(source)
    expect(source.isRunning && stillWatched == (2, 1), "one subscriber leaving keeps the source running for the other, saw \(stillWatched)")
    source.push(flatCapturedFrame(width: 64, height: 32, level: 40))
    expect(second.frames.last?.pixels.first == 40, "and frames keep reaching it")
    secondSubscription.cancel()
    let stopped = await settles { !source.isRunning }
    expect(stopped && source.stopCount == 2, "the last one leaving stops the source")
    source.holdStarts()
    let late = FeedLog()
    let lateSubscription = feed.subscribe(onFrame: late.frame, onState: late.state)
    expect(late.frames.isEmpty && late.states == [.connecting], "no picture from the stopped stream is kept, saw \(late.frames.count) frames")
    lateSubscription.cancel()
    source.releaseStart()
    feed.stop()
}

private func testASubscriberLeavingDuringAStartEndsWithTheSourceStopped() async {
    let source = ScriptedFrameSource()
    let grantState = PortalGrantState()
    let feed = await probedFeed(source, grantState: grantState)
    source.holdStarts()
    let log = FeedLog()
    let subscription = feed.subscribe(onFrame: log.frame, onState: log.state)
    let waiting = await settles { source.isStartWaiting }
    expect(waiting, "the subscriber's start is in flight")
    subscription.cancel()
    source.releaseStart()
    let stopped = await settles { !source.isRunning && source.stopCount == 2 }
    expect(stopped, "the start that finished after the subscriber left is stopped, saw \(source.startCount) starts \(source.stopCount) stops")
    let counts = await settled(source)
    expect(counts == (2, 2) && !source.isRunning, "and stays stopped, saw \(counts)")
    expect(log.frames.isEmpty, "a cancelled subscription gets no frame")
    feed.stop()
}

private func testAStoppedFeedCallsNobodyAndNeverRestarts() async {
    let source = ScriptedFrameSource()
    let grantState = PortalGrantState()
    let feed = await probedFeed(source, grantState: grantState)
    let log = FeedLog()
    _ = feed.subscribe(onFrame: log.frame, onState: log.state)
    _ = await settles { log.frames.count == 1 }
    feed.stop()
    expect(!source.isRunning, "stopping the feed stops the source")
    if case .failed? = log.states.last {} else {
        expect(false, "a stopped feed reads as failed to whoever still listens, saw \(log.states)")
    }
    let heard = (log.frames.count, log.states.count)
    source.push(flatCapturedFrame(width: 64, height: 32, level: 50))
    source.report(.streaming)
    let late = FeedLog()
    let lateSubscription = feed.subscribe(onFrame: late.frame, onState: late.state)
    let counts = await settled(source)
    expect(counts.starts == 2 && !source.isRunning, "a stopped feed never starts its source again, saw \(counts)")
    expect((log.frames.count, log.states.count) == heard, "nobody hears anything after the feed stops")
    expect(late.frames.isEmpty && late.states.count == 1, "a late subscriber is told the stream failed, and nothing else")
    lateSubscription.cancel()
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
    let size = grantState.live?.routableMonitors.first?.monitor.frameSize
    expect(size?.width == 3840 && size?.height == 2160, "the frame's size is recorded for the display inventory")
    subscription.cancel()
    feed.stop()
}

private func testAFailedStreamIsPassedOnAndStopsTheSource() async {
    let source = ScriptedFrameSource()
    let grantState = PortalGrantState()
    let feed = await liveFeed(source, grantState: grantState)
    let log = FeedLog()
    _ = feed.subscribe(onFrame: log.frame, onState: log.state)
    source.report(.failed("the compositor went away"))
    expect(log.states.last == .failed("the compositor went away"), "a failed stream is passed on")
    let stopped = await settles { !source.isRunning }
    expect(stopped, "and its source is stopped")
    feed.stop()
    let late = FeedLog()
    _ = feed.subscribe(onFrame: late.frame, onState: late.state)
    expect(late.frames.isEmpty, "a stopped feed replays no frame")
}

private func testAFailedFeedMakesOnlyItsOwnMonitorUnavailable() async throws {
    let state = PortalGrantState()
    let inventory = PortalDisplayInventory(grantState: state)
    let secondMonitor = PortalStream(
        nodeID: 59, id: "monitor-b", position: PortalPoint(x: 1920, y: 0), size: PortalSize(width: 1280, height: 720)
    )
    let generation = state.install(grant: liveGrant(streams: [grantedMonitor, secondMonitor]), sink: RecordingSink())
    let first = ScriptedFrameSource()
    let second = ScriptedFrameSource()
    let firstFeed = LinuxScreenFeed(source: first, grantState: state, streamNodeID: grantedMonitor.nodeID, generation: generation)
    let secondFeed = LinuxScreenFeed(source: second, grantState: state, streamNodeID: secondMonitor.nodeID, generation: generation)
    defer {
        firstFeed.stop()
        secondFeed.stop()
    }
    try await firstFeed.start()
    try await secondFeed.start()
    first.push(flatCapturedFrame(width: 1920, height: 1080))
    second.push(flatCapturedFrame(width: 1280, height: 720))
    expect(inventory.displays().count == 2, "both monitors are initially ready")
    let watching = FeedLog()
    let watchingSubscription = secondFeed.subscribe(onFrame: watching.frame, onState: watching.state)
    _ = await settles { watching.frames.count == 1 }
    second.report(.failed("the monitor disconnected"))
    second.report(.streaming)
    second.push(flatCapturedFrame(width: 1280, height: 720))
    expect(inventory.displays().map(\.modePixelWidth) == [1920], "only the failed monitor is removed from new offers")
    let log = FeedLog()
    let subscription = secondFeed.subscribe(onFrame: log.frame, onState: log.state)
    expect(log.frames.isEmpty && log.states == [.failed("the monitor disconnected")], "new subscribers receive failure without stale pixels")
    subscription.cancel()
    watchingSubscription.cancel()
}

func screenFeedTests() -> [NamedTest] { [
    ("the grant probe stops the source after its first frame", testTheGrantProbeStopsTheSourceAfterItsFirstFrame),
    ("the first subscriber starts the source and gets the first frame", testTheFirstSubscriberStartsTheSourceAndGetsTheFirstFrame),
    ("a second subscriber gets the latest frame, stamped now", testASecondSubscriberGetsTheLatestFrameStampedNow),
    ("the last subscriber leaving stops the source", testTheLastSubscriberLeavingStopsTheSource),
    ("a subscriber leaving during a start ends with the source stopped", testASubscriberLeavingDuringAStartEndsWithTheSourceStopped),
    ("a stopped feed calls nobody and never restarts", testAStoppedFeedCallsNobodyAndNeverRestarts),
    ("feed frames record their size and only pictures are delivered", testFramesRecordTheirSizeAndOnlyPicturesAreDelivered),
    ("a failed stream is passed on and stops the source", testAFailedStreamIsPassedOnAndStopsTheSource),
    ("a failed feed makes only its own monitor unavailable", { try! await testAFailedFeedMakesOnlyItsOwnMonitorUnavailable() })
] }
#endif

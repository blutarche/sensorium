import CoreMedia
import Foundation
import SensoriumClient
import SensoriumCore
import SensoriumHost

/// `SensoriumBenchHost motion-bench`: the host media pipeline and the macOS
/// viewer's decoder in one process, with no network and no permission. A
/// synthetic page scrolls and rests on a fixed plan, every packet the
/// pipeline produces is decoded as the viewer would decode it, and one line
/// of figures is printed for the run.
///
/// It measures what happens between the host's capture and the viewer's
/// decoder only. The link, the viewer's presentation and the host's fidelity
/// controller are not in it, so its numbers compare one pipeline build with
/// another on the same machine and say nothing about a real session's
/// end-to-end delay.
struct MotionBenchOptions: Equatable {
    static let usage = """
    usage: SensoriumBenchHost motion-bench [--size <width>x<height>] [--plan <plan>] [--speed <pixels>] [--interaction] [--repeat N]

      --size         logical size of the synthetic screen, encoded at twice that (default 1773x997)
      --plan         comma-separated scroll:<seconds> and still:<seconds> steps (default scroll:2,still:1.5,scroll:0.4,still:0.6,scroll:1,still:2)
      --speed        pixels the page moves per 1/60 s while scrolling (default 12)
      --interaction  tells the pipeline about viewer scroll input while the page scrolls
      --repeat N     runs the plan N times in one session (default 3)
    """

    enum Step: Equatable {
        case scroll(Double)
        case still(Double)

        var seconds: Double {
            switch self {
            case let .scroll(seconds), let .still(seconds):
                return seconds
            }
        }
    }

    var logicalWidth = 1773
    var logicalHeight = 997
    var plan: [Step] = [.scroll(2), .still(1.5), .scroll(0.4), .still(0.6), .scroll(1), .still(2)]
    var speed = 12.0
    var reportsInteraction = false
    var repeatCount = 3

    static func parse(_ arguments: [String]) -> Result<MotionBenchOptions, BenchHostOptions.ParseError> {
        var options = MotionBenchOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--interaction" {
                options.reportsInteraction = true
                index += 1
                continue
            }
            guard index + 1 < arguments.count else {
                return .failure(.message("\(argument) needs a value"))
            }
            let value = arguments[index + 1]
            index += 2
            switch argument {
            case "--size":
                let parts = value.split(separator: "x").compactMap { Int($0) }
                guard parts.count == 2, parts.allSatisfy({ $0 > 0 && $0 <= 2048 }) else {
                    return .failure(.message("--size needs <width>x<height>, each 1-2048"))
                }
                options.logicalWidth = parts[0]
                options.logicalHeight = parts[1]
            case "--plan":
                var steps: [Step] = []
                for item in value.split(separator: ",") {
                    let fields = item.split(separator: ":")
                    guard fields.count == 2, let seconds = Double(fields[1]), seconds > 0 else {
                        return .failure(.message("--plan step \(item) is not <kind>:<seconds>"))
                    }
                    switch fields[0] {
                    case "scroll": steps.append(.scroll(seconds))
                    case "still": steps.append(.still(seconds))
                    default: return .failure(.message("--plan step kind must be scroll or still"))
                    }
                }
                guard !steps.isEmpty else {
                    return .failure(.message("--plan needs at least one step"))
                }
                options.plan = steps
            case "--speed":
                guard let speed = Double(value), speed > 0 else {
                    return .failure(.message("--speed needs a number above zero"))
                }
                options.speed = speed
            case "--repeat":
                guard let count = Int(value), count > 0 else {
                    return .failure(.message("--repeat needs a whole number above zero"))
                }
                options.repeatCount = count
            default:
                return .failure(.message("unknown option \(argument)"))
            }
        }
        return .success(options)
    }
}

/// Everything the run records, from whichever thread saw it.
private final class MotionBenchLedger: @unchecked Sendable {
    struct Packet {
        let presentationTime: Int64
        let isKeyFrame: Bool
        let bytes: Int
    }

    struct Decoded {
        let presentationTime: Int64
        let decodedAt: Int64
        let width: Int
        let height: Int
    }

    private let lock = NSLock()
    private(set) var packets: [Packet] = []
    private(set) var decoded: [Decoded] = []
    private(set) var decodeFailures = 0

    func record(_ packet: Packet) {
        lock.lock()
        packets.append(packet)
        lock.unlock()
    }

    func record(_ frame: Decoded) {
        lock.lock()
        decoded.append(frame)
        lock.unlock()
    }

    func recordDecodeFailure() {
        lock.lock()
        decodeFailures += 1
        lock.unlock()
    }

    func snapshot() -> (packets: [Packet], decoded: [Decoded], decodeFailures: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (packets, decoded, decodeFailures)
    }
}

@MainActor
enum MotionBench {
    static func run(_ options: MotionBenchOptions) async throws {
        let base = VideoEncoderConfiguration.remoteDefault
        let logical = VideoEncoderConfiguration(
            width: options.logicalWidth,
            height: options.logicalHeight,
            framesPerSecond: base.framesPerSecond,
            codec: base.codec,
            maxQueueDepth: base.maxQueueDepth,
            captureWidth: options.logicalWidth,
            captureHeight: options.logicalHeight,
            encodeWidth: options.logicalWidth,
            encodeHeight: options.logicalHeight,
            averageBitRate: base.averageBitRate,
            dataRateLimitBytes: base.dataRateLimitBytes,
            dataRateLimitSeconds: base.dataRateLimitSeconds,
            maxFrameDelayCount: base.maxFrameDelayCount,
            profileLevel: base.profileLevel,
            requiresHardwareAcceleration: true
        )
        // At the interval a session runs at once the viewer has said it asks
        // for key frames itself, which every viewer in this repository does.
        let configuration = logical.scaled(toStreamScale: 2.0)
            .with(keyFrameIntervalSeconds: VideoEncoderConfiguration.viewerRecoveryKeyFrameIntervalSeconds)
        let ledger = MotionBenchLedger()
        let receipts = FrameReceiptLedger()
        let decoder = VideoToolboxDecoder(receipts: receipts) { frame in
            guard let timing = frame.timing else { return }
            ledger.record(MotionBenchLedger.Decoded(
                presentationTime: timing.hostCapturedAtNanoseconds,
                decodedAt: timing.decodedAtNanoseconds,
                width: frame.width,
                height: frame.height
            ))
        }
        let decodeQueue = DispatchQueue(label: "sensorium.motion-bench-decode", qos: .userInteractive)
        let pointer = BenchPointer()
        let recorder = HostMediaLatencyRecorder()
        let surface = CanvasSurfaceID.allCases[0]
        let pipeline = try await HostMediaPipeline(
            surface: surface,
            configuration: configuration,
            latencyRecorder: recorder,
            sessionAdmissionGate: SharedEncodeAdmissionGate<CMSampleBuffer>(capacity: 1),
            frameSourceFactory: { configuration, deliveryHandler, _, frameHandler in
                try SyntheticDesktopFrameSource(
                    configuration: configuration,
                    pointer: pointer,
                    deliveryHandler: deliveryHandler,
                    frameHandler: frameHandler
                )
            },
            encodedPacketHandler: { packet in
                let presentationTime = Int64(packet.presentationTimeNanoseconds)
                ledger.record(MotionBenchLedger.Packet(
                    presentationTime: presentationTime,
                    isKeyFrame: packet.isKeyFrame,
                    bytes: packet.payload.count
                ))
                decodeQueue.async {
                    receipts.record(
                        presentationTimeNanoseconds: presentationTime,
                        receivedAtNanoseconds: MonotonicClock.nowNanoseconds()
                    )
                    do {
                        try decoder.decode(packet)
                    } catch {
                        ledger.recordDecodeFailure()
                    }
                }
                return true
            }
        )
        print("motion-bench encoding \(configuration.encodeWidth)x\(configuration.encodeHeight) interaction=\(options.reportsInteraction)")
        try await pipeline.start()
        // Lets the opening key frame through before anything is measured.
        try await Task.sleep(for: .seconds(1))

        var scrollWindows: [(start: Int64, end: Int64)] = []
        var stillEnds: [Int64] = []
        for _ in 0..<options.repeatCount {
            for step in options.plan {
                let start = MonotonicClock.nowNanoseconds()
                let end = start + Int64(step.seconds * 1_000_000_000)
                switch step {
                case .scroll:
                    while MonotonicClock.nowNanoseconds() < end {
                        pointer.move(byX: 0, y: options.speed)
                        if options.reportsInteraction {
                            reportInteraction(to: pipeline)
                        }
                        try await Task.sleep(for: .nanoseconds(1_000_000_000 / 60))
                    }
                    scrollWindows.append((start, MonotonicClock.nowNanoseconds()))
                case .still:
                    try await Task.sleep(for: .nanoseconds(end - start))
                    stillEnds.append(MonotonicClock.nowNanoseconds())
                }
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        try await pipeline.stop()
        decodeQueue.sync {}
        report(ledger.snapshot(), recorder: recorder, surface: surface, scrollWindows: scrollWindows, stillEnds: stillEnds)
    }

    /// What the host does with a scroll the viewer sent, for the pipeline's
    /// part of it. A build whose pipeline has no such signal ignores it.
    private static func reportInteraction(to pipeline: HostMediaPipeline) {}

    private static func report(
        _ snapshot: (packets: [MotionBenchLedger.Packet], decoded: [MotionBenchLedger.Decoded], decodeFailures: Int),
        recorder: HostMediaLatencyRecorder,
        surface: CanvasSurfaceID,
        scrollWindows: [(start: Int64, end: Int64)],
        stillEnds: [Int64]
    ) {
        func inScroll(_ time: Int64) -> Bool {
            scrollWindows.contains { time >= $0.start && time <= $0.end }
        }
        func percentile(_ values: [Int64], _ fraction: Double) -> Double {
            guard !values.isEmpty else { return .nan }
            let sorted = values.sorted()
            return Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]) / 1_000_000
        }
        let encode = recorder.metrics(for: surface).samples(for: .encode)
        let scrollSeconds = scrollWindows.reduce(0.0) { $0 + Double($1.end - $1.start) / 1_000_000_000 }
        let scrollPackets = snapshot.packets.filter { inScroll($0.presentationTime) }
        let endToEnd = snapshot.decoded.filter { inScroll($0.presentationTime) }.map { $0.decodedAt - $0.presentationTime }
        let firstFrames: [Int64] = scrollWindows.compactMap { window in
            snapshot.decoded
                .filter { $0.presentationTime >= window.start }
                .min { $0.presentationTime < $1.presentationTime }
                .map { $0.decodedAt - window.start }
        }
        let keyFrames = snapshot.packets.filter(\.isKeyFrame)
        let settledSizes: [String] = stillEnds.map { end in
            snapshot.decoded.filter { $0.decodedAt <= end }.max { $0.decodedAt < $1.decodedAt }
                .map { "\($0.width)x\($0.height)" } ?? "none"
        }
        let sizes = Set(snapshot.decoded.map { "\($0.width)x\($0.height)" }).sorted()
        let format = { (value: Double) in String(format: "%.1f", value) }
        print("motion-bench encode p50=\(format(Double(encode.p50 ?? 0) / 1_000_000))ms p95=\(format(Double(encode.p95 ?? 0) / 1_000_000))ms samples=\(encode.count)")
        print("motion-bench scroll encoded-fps=\(format(Double(scrollPackets.count) / scrollSeconds)) end-to-end p50=\(format(percentile(endToEnd, 0.5)))ms p95=\(format(percentile(endToEnd, 0.95)))ms frames=\(endToEnd.count)")
        print("motion-bench first-frame-after-motion p50=\(format(percentile(firstFrames, 0.5)))ms max=\(format(percentile(firstFrames, 1.0)))ms episodes=\(firstFrames.count)")
        print("motion-bench key-frames count=\(keyFrames.count) bytes=\(keyFrames.reduce(0) { $0 + $1.bytes }) total-bytes=\(snapshot.packets.reduce(0) { $0 + $1.bytes }) packets=\(snapshot.packets.count)")
        print("motion-bench decoded-sizes \(sizes.joined(separator: " ")) settled-after-each-rest \(settledSizes.joined(separator: " ")) decode-failures=\(snapshot.decodeFailures)")
    }
}

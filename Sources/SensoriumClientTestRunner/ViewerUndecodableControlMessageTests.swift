import Foundation
import SensoriumClient
import SensoriumCore

private final class ViewerLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private var stoppedByHostFlag = false
    private var endedReasonValue: String?

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(line)
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func noteStoppedByHost() {
        lock.lock()
        defer { lock.unlock() }
        stoppedByHostFlag = true
    }

    var stoppedByHost: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedByHostFlag
    }

    func noteEnded(_ reason: String) {
        lock.lock()
        defer { lock.unlock() }
        endedReasonValue = reason
    }

    var endedReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return endedReasonValue
    }
}

/// A whole, well-framed tag-0 transport packet carrying `message` as a real
/// encoder writes it, with `original` replaced by `replacement`: a message
/// from a newer host that this build cannot read.
private func unreadableHostPacket(
    _ message: SensoriumMessage,
    replacing original: String,
    with replacement: String
) -> Data {
    let frame = try! SensoriumFrameCodec.encode(message)
    let json = String(decoding: frame.dropFirst(4), as: UTF8.self)
    expect(json.contains(original), "the encoded message contains \(original) to replace, got \(json)")
    let payload = Data(json.replacingOccurrences(of: original, with: replacement).utf8)
    var inner = Data()
    var innerLength = UInt32(payload.count).bigEndian
    withUnsafeBytes(of: &innerLength) { inner.append(contentsOf: $0) }
    inner.append(payload)
    var packet = Data([0])
    var outerLength = UInt32(inner.count).bigEndian
    withUnsafeBytes(of: &outerLength) { packet.append(contentsOf: $0) }
    packet.append(inner)
    return packet
}

/// A live session that receives a control message it cannot read drops it,
/// says so once, and keeps reading: the message after it still arrives and
/// still has its effect.
@MainActor
func testViewerLiveLoopSurvivesAnUndecodableControlMessage() async {
    let unreadable = unreadableHostPacket(
        .hostScreenLockState(locked: true),
        replacing: "\"hostScreenLocked\":true",
        with: "\"hostScreenLocked\":\"sometimes\""
    )
    let stop = try! SensoriumTransportPacketCodec.encode(.control(.goodbye(reason: GoodbyeReason.stoppedByHost)))
    let connection = ScriptedControlConnection(wireFrames: [unreadable, unreadable, unreadable, stop])
    let recorded = ViewerLogLines()
    let runner = ClientSessionRunner(
        connection: connection,
        session: ClientSessionController(transport: FakeClientTransport()),
        window: RecordingSurfaceWindow(surfaceID: 0),
        log: { recorded.append($0) }
    )
    runner.onStoppedByHost = { recorded.noteStoppedByHost() }
    try! runner.start(onEnded: { recorded.noteEnded($0) })
    for _ in 0..<200 where recorded.endedReason == nil {
        try? await Task.sleep(for: .milliseconds(10))
    }
    runner.stop()

    expect(
        recorded.stoppedByHost,
        "the host's Stop after three messages this viewer cannot read still reaches it, so the loop kept reading; ended with \(String(describing: recorded.endedReason))"
    )
    let dropLines = recorded.lines.filter { $0.contains("could not read") }
    expect(dropLines.count == 1, "three drops in a row write one log line, got \(recorded.lines)")
    print("PASS: a viewer's live loop drops a control message it cannot read, logs it once, and keeps reading")
}

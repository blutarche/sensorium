import Foundation
import SensoriumClient
import SensoriumCore

/// `ClientSessionRunner` is portable behind `SessionCanvasWindow` alone --
/// proven here without AppKit, a window server connection, or a live socket:
/// a scripted connection and a recording fake window are enough to watch one
/// media packet for surface 0 reach the fake's own `videoSink` and one decode
/// session start.
@MainActor
func testSessionCanvasWindowRoutingTests() async {
    let window = RecordingSurfaceWindow(surfaceID: 0)
    let connection = ScriptedControlConnection(responses: [
        .video(EncodedVideoFramePacket(
            sequence: 1,
            presentationTimeNanoseconds: 1_000,
            isKeyFrame: true,
            payload: Data([0x01, 0x02, 0x03])
        ))
    ])
    let session = ClientSessionController(transport: FakeClientTransport())
    let runner = ClientSessionRunner(connection: connection, session: session, window: window)

    try! runner.start()

    // The receive loop runs detached from this actor -- poll rather than
    // assume one hop off `start()` is enough for the packet to travel
    // socket -> router -> sink.
    var routed = false
    for _ in 0..<200 {
        if window.videoSink.receipts.outstandingCount > 0 {
            routed = true
            break
        }
        try? await Task.sleep(for: .milliseconds(10))
    }

    expect(routed, "a video packet for surface 0 reaches the fake window's own videoSink")
    expect(window.startDecodingCount == 1, "start() calls startDecoding on the primary window exactly once")

    runner.stop()

    print("PASS: ClientSessionRunner routes surface 0's video to its window's videoSink and starts decoding, behind SessionCanvasWindow alone")
}

import Foundation
import SensoriumCore
import SensoriumHost

/// What the session reported through `onEvent`, read from the test.
private final class UndecodableEventLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

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
}

/// A whole, well-framed tag-0 transport packet carrying `message` as a real
/// encoder writes it, with `original` replaced by `replacement`: a message
/// from a newer viewer that this build cannot read.
private func unreadableControlPacket(
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

private let leftDownAtTen = SensoriumMessage.input(
    .pointerButton(button: .left, isDown: true, x: 10, y: 10),
    surfaceID: nil,
    sequence: nil
)

private var sidewaysButton: Data {
    unreadableControlPacket(leftDownAtTen, replacing: "\"left\"", with: "\"sideways\"")
}

private var squeezedPointer: Data {
    unreadableControlPacket(
        leftDownAtTen,
        replacing: "\"kind\":\"pointerButton\"",
        with: "\"kind\":\"pointerSqueezed\""
    )
}

/// A session with a live canvas on surface 0, its injector, and what it logged.
@MainActor
private func startAdmittedCanvasSession() async -> (
    HostNetworkSession, FakeHostByteChannel, FakeInputInjector, UndecodableEventLines
) {
    let injector = FakeInputInjector()
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        inputInjector: injector,
        keyConfinement: .unconfined,
        privateDesktopOffered: { true }
    )
    let channel = FakeHostByteChannel(scriptedMessages: [
        .canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)
    ])
    let events = UndecodableEventLines()
    let session = HostNetworkSession(
        connection: channel,
        controller: controller,
        onEvent: { events.append($0) }
    )
    session.start()
    let admitted = await waitUntil(timeoutSeconds: 1) {
        channel.sentPackets.contains {
            if case .control(.canvasReady) = $0 { return true }
            return false
        }
    }
    expect(admitted, "the canvas request was admitted before the test sends anything this build cannot read")
    return (session, channel, injector, events)
}

@MainActor
func runHostUndecodableControlMessageTests() async {
    for (label, unreadable) in [("a button", sidewaysButton), ("an input kind", squeezedPointer)] {
        let (session, channel, injector, events) = await startAdmittedCanvasSession()
        channel.feedRawFrames([unreadable, unreadable, unreadable])
        channel.feed([.input(.pointerButton(button: .left, isDown: true, x: 20, y: 30), surfaceID: nil, sequence: nil)])
        let applied = await waitUntil(timeoutSeconds: 1) {
            injector.events.contains(.pointerButton(button: .left, isDown: true, x: 20, y: 30))
        }
        expect(applied, "after three inputs naming \(label) this build has no case for, the next valid input is still applied")
        expect(channel.cancelCount == 0, "an admitted session that receives \(label) it cannot read keeps its connection open")
        expect(
            !injector.events.contains(.pointerButton(button: .left, isDown: true, x: 10, y: 10)),
            "the unreadable input is dropped, never applied as anything else"
        )
        let dropLines = events.lines.filter { $0.contains("could not read") }
        expect(
            dropLines.count == 1,
            "three drops in a row write one log line, not one per message, got \(events.lines)"
        )
        session.stop()
        print("PASS: an admitted session drops an input naming \(label) it cannot read, logs it once, and applies the next input")
    }

    // Before any surface is live, the same frame still closes the
    // connection: for a peer that has not authenticated, and for one that
    // has but was never given a canvas or a host screen.
    for requireAuthentication in [true, false] {
        let injector = FakeInputInjector()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: requireAuthentication,
            inputInjector: injector,
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        let channel = FakeHostByteChannel(scriptedMessages: [])
        let events = UndecodableEventLines()
        let session = HostNetworkSession(connection: channel, controller: controller, onEvent: { events.append($0) })
        session.start()
        channel.feedRawFrames([sidewaysButton])
        // With no authentication required, a canvas request behind the frame
        // would be admitted if the frame were skipped. With it required,
        // nothing follows: anything sent would itself be refused, and the
        // refusal could close the connection on its own.
        if !requireAuthentication {
            channel.feed([.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)])
        }
        let closed = await waitUntil(timeoutSeconds: 1) { channel.cancelCount > 0 }
        let who = requireAuthentication ? "an unauthenticated peer" : "a peer with no live surface"
        expect(closed, "an input this build cannot read from \(who) still closes the connection")
        expect(
            !channel.sentPackets.contains { if case .control(.canvasReady) = $0 { return true }; return false },
            "nothing \(who) sends after the unreadable frame is answered"
        )
        expect(
            !events.lines.contains { $0.contains("could not read") },
            "a connection closed over an unreadable frame is not reported as a message skipped, got \(events.lines)"
        )
        session.stop()
        print("PASS: an input this build cannot read from \(who) still closes the connection")
    }

    // A modifier bit this build does not know is masked off, never a reason
    // to refuse the key: refusing a key-up would leave the key held down.
    do {
        let injector = FakeInputInjector()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            inputInjector: injector,
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        _ = try? controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        let unknownBits = CanvasModifierFlags(rawValue: 0b0011_0000)
        for isDown in [true, false] {
            do {
                _ = try controller.handle(.input(
                    .key(keyCode: 0, isDown: isDown, modifiers: unknownBits.union(.shift)),
                    surfaceID: nil,
                    sequence: nil
                ))
            } catch {
                expect(false, "a key \(isDown ? "down" : "up") with a modifier bit this build does not know is not refused, got \(error)")
            }
        }
        expect(
            injector.events == [
                .key(keyCode: 0, isDown: true, modifiers: .shift),
                .key(keyCode: 0, isDown: false, modifiers: .shift)
            ],
            "both the key-down and the key-up are applied with the unknown bits masked off, got \(injector.events)"
        )
        print("PASS: a key event with a modifier bit this build does not know is applied with the bit masked")
    }
}

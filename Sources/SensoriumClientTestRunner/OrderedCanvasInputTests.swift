import Foundation
import SensoriumClient

private actor DeliveredEvents {
    private(set) var events: [CanvasSurfaceEvent] = []

    func append(_ event: CanvasSurfaceEvent) -> Int {
        events.append(event)
        return events.count
    }
}

private func key(_ code: UInt16, down: Bool) -> CanvasSurfaceEvent {
    .key(keyCode: code, isDown: down, modifiers: [])
}

private func button(down: Bool) -> CanvasSurfaceEvent {
    .pointerButton(button: .left, isDown: down, x: 1, y: 1)
}

private func scroll(_ dy: Double) -> CanvasSurfaceEvent {
    .scrolled(deltaX: 0, deltaY: dy, x: 1, y: 1, phase: nil, momentumPhase: nil)
}

func testOrderedCanvasInputTests() async {
    testCanvasInputBufferCoalescesOnlyConsecutiveMotion()
    await testOrderedPipelineDeliversInSubmissionOrder()
    await testOrderedPipelineCoalescesMotionBehindASlowSend()
    await testOrderedPipelineDrainsWhatWasQueuedWhenFinished()
    print("PASS: ordered canvas input")
}

private func testCanvasInputBufferCoalescesOnlyConsecutiveMotion() {
    var buffer = CanvasInputBuffer()
    buffer.push(.pointerMoved(x: 1, y: 1))
    buffer.push(.pointerMoved(x: 2, y: 2))
    buffer.push(key(1, down: true))
    buffer.push(.pointerMoved(x: 3, y: 3))
    buffer.push(button(down: true))
    buffer.push(.pointerMoved(x: 4, y: 4))
    buffer.push(.pointerMoved(x: 5, y: 5))
    var popped: [CanvasSurfaceEvent] = []
    while let event = buffer.pop() { popped.append(event) }
    expect(
        popped == [
            .pointerMoved(x: 2, y: 2), key(1, down: true), .pointerMoved(x: 3, y: 3),
            button(down: true), .pointerMoved(x: 5, y: 5)
        ],
        "motion collapses to the newest point only between non-motion events, got \(popped)"
    )
    expect(buffer.isEmpty, "a drained buffer is empty")

    var discrete = CanvasInputBuffer()
    let sequence: [CanvasSurfaceEvent] = [
        key(1, down: true), key(1, down: true), key(1, down: false),
        button(down: true), button(down: true), scroll(1), scroll(1)
    ]
    for event in sequence { discrete.push(event) }
    var out: [CanvasSurfaceEvent] = []
    while let event = discrete.pop() { out.append(event) }
    expect(out == sequence, "keys, buttons and scrolls are never collapsed or reordered, got \(out)")

    var relative = CanvasInputBuffer()
    relative.push(.pointerMovedRelative(deltaX: 1, deltaY: 2))
    relative.push(.pointerMovedRelative(deltaX: 3, deltaY: -1))
    expect(
        relative.pop() == .pointerMovedRelative(deltaX: 4, deltaY: 1) && relative.isEmpty,
        "queued relative motion is summed, so no captured-pointer travel is lost"
    )
}

private func testOrderedPipelineDeliversInSubmissionOrder() async {
    let delivered = DeliveredEvents()
    let pipeline = OrderedCanvasInputPipeline { event in
        // Every send suspends, so an unordered dispatch would interleave.
        try? await Task.sleep(nanoseconds: 200_000)
        _ = await delivered.append(event)
    }
    var expected: [CanvasSurfaceEvent] = []
    for code in 0..<200 {
        let down = key(UInt16(code), down: true)
        let up = key(UInt16(code), down: false)
        expected.append(down)
        expected.append(up)
        pipeline.submit(down)
        pipeline.submit(up)
    }
    pipeline.finish()
    await pipeline.waitUntilFinished()
    let events = await delivered.events
    expect(events == expected, "key down and up reach the router in the order they happened")
}

private func testOrderedPipelineCoalescesMotionBehindASlowSend() async {
    let delivered = DeliveredEvents()
    let (gateStream, gate) = AsyncStream<Void>.makeStream()
    let pipeline = OrderedCanvasInputPipeline { event in
        let count = await delivered.append(event)
        if count == 1 {
            for await _ in gateStream { break }
        }
    }
    pipeline.submit(.pointerMoved(x: 0, y: 0))
    while await delivered.events.isEmpty { await Task.yield() }
    pipeline.submit(.pointerMoved(x: 1, y: 1))
    pipeline.submit(.pointerMoved(x: 2, y: 2))
    pipeline.submit(button(down: true))
    pipeline.submit(.pointerMoved(x: 3, y: 3))
    pipeline.submit(.pointerMoved(x: 4, y: 4))
    pipeline.submit(button(down: false))
    gate.yield()
    pipeline.finish()
    await pipeline.waitUntilFinished()
    let events = await delivered.events
    expect(
        events == [
            .pointerMoved(x: 0, y: 0), .pointerMoved(x: 2, y: 2), button(down: true),
            .pointerMoved(x: 4, y: 4), button(down: false)
        ],
        "motion queued behind a slow send keeps only its newest point, got \(events)"
    )
}

private func testOrderedPipelineDrainsWhatWasQueuedWhenFinished() async {
    let delivered = DeliveredEvents()
    let pipeline = OrderedCanvasInputPipeline { event in _ = await delivered.append(event) }
    pipeline.submit(key(9, down: false))
    pipeline.submit(CanvasSurfaceEvent.focusLost)
    pipeline.finish()
    pipeline.submit(key(10, down: true))
    await pipeline.waitUntilFinished()
    let events = await delivered.events
    expect(
        events == [key(9, down: false), .focusLost],
        "events queued before teardown still reach the router and later ones are refused, got \(events)"
    )
}

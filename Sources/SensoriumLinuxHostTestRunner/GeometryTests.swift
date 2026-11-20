#if os(Linux)

import SensoriumLinuxHost

func testLogicalSizeComesFromTheStreamSizeAndScaleFromTheBufferWidth() {
    let stream = PortalStream(
        nodeID: 57,
        id: "monitor-a",
        position: PortalPoint(x: 0, y: 0),
        size: PortalSize(width: 1280, height: 800)
    )
    guard let geometry = PortalCaptureGeometry(stream: stream) else {
        expect(false, "a stream with a size has a geometry")
        return
    }
    expect(geometry.streamNodeID == 57, "the node is the stream's")
    expect(geometry.logicalWidth == 1280 && geometry.logicalHeight == 800, "the logical size is the stream's size")
    expect(geometry.backingScale(bufferWidth: 1280) == 1, "a buffer as wide as the logical size is scale 1")
    expect(geometry.backingScale(bufferWidth: 1920) == 1.5, "a 1920 pixel buffer on 1280 logical is scale 1.5")
    expect(geometry.backingScale(bufferWidth: 1600) == 1.25, "a 1600 pixel buffer on 1280 logical is scale 1.25")
    expect(geometry.backingScale(bufferWidth: 2560) == 2, "a 2560 pixel buffer on 1280 logical is scale 2")
}

func testAStreamWithNoSizeHasNoGeometryUntilTheFirstFrameGivesOne() {
    let stream = PortalStream(nodeID: 9)
    expect(PortalCaptureGeometry(stream: stream) == nil, "no size, no geometry")
    let fallback = PortalCaptureGeometry(stream: stream, firstFrameWidth: 1920, firstFrameHeight: 1080)
    expect(fallback.logicalWidth == 1920 && fallback.logicalHeight == 1080, "the first frame's size stands in, at scale 1")
    expect(fallback.backingScale(bufferWidth: 1920) == 1, "so the scale is 1")
    expect(fallback.streamNodeID == 9, "the node is kept")
}

func testClampingKeepsPointsInsideTheMonitor() {
    let geometry = PortalCaptureGeometry(streamNodeID: 1, logicalWidth: 1000, logicalHeight: 500, identitySeed: "x")
    let inside = geometry.clamped(x: 10.5, y: 20.25)
    expect(inside.x == 10.5 && inside.y == 20.25, "a point inside is unchanged")
    let low = geometry.clamped(x: -3, y: -0.5)
    expect(low.x == 0 && low.y == 0, "negative coordinates clamp to zero")
    let high = geometry.clamped(x: 1000, y: 9999)
    expect(high.x < 1000 && high.x >= 999.9, "the right edge is exclusive, got \(high.x)")
    expect(high.y < 500 && high.y >= 499.9, "the bottom edge is exclusive, got \(high.y)")
}

func testDisplayIdentityIsTheStreamIDWhenGivenAndOtherwiseThePositionAndSize() {
    let sized = PortalSize(width: 1920, height: 1080)
    let named = PortalCaptureGeometry(stream: PortalStream(nodeID: 1, id: "monitor-a", position: PortalPoint(x: 0, y: 0), size: sized))!
    let namedElsewhere = PortalCaptureGeometry(stream: PortalStream(nodeID: 2, id: "monitor-a", position: PortalPoint(x: 5, y: 5), size: PortalSize(width: 1280, height: 720)))!
    expect(named.displayIdentity == 2_850_258_567, "the identity is FNV-1a of the id, got \(named.displayIdentity)")
    expect(named.displayIdentity == namedElsewhere.displayIdentity, "the same id is the same display wherever it sits")

    let anonymous = PortalCaptureGeometry(stream: PortalStream(nodeID: 1, id: nil, position: PortalPoint(x: 0, y: 0), size: sized))!
    expect(anonymous.displayIdentity == 3_672_806_286, "without an id the identity hashes position and size, got \(anonymous.displayIdentity)")
    let moved = PortalCaptureGeometry(stream: PortalStream(nodeID: 1, id: nil, position: PortalPoint(x: 1920, y: 0), size: sized))!
    expect(moved.displayIdentity != anonymous.displayIdentity, "a different position is a different display")
    let noPosition = PortalCaptureGeometry(stream: PortalStream(nodeID: 1, id: nil, position: nil, size: sized))!
    expect(noPosition.displayIdentity == anonymous.displayIdentity, "a missing position reads as the origin")
    expect(named.displayIdentity != 0, "the identity is never zero")
}

func geometryTests() -> [NamedTest] { [
    ("logical size comes from the stream size and scale from the buffer width", testLogicalSizeComesFromTheStreamSizeAndScaleFromTheBufferWidth),
    ("a stream with no size has a geometry only from the first frame", testAStreamWithNoSizeHasNoGeometryUntilTheFirstFrameGivesOne),
    ("clamping keeps points inside the monitor", testClampingKeepsPointsInsideTheMonitor),
    ("the display identity is the stream id, else position and size", testDisplayIdentityIsTheStreamIDWhenGivenAndOtherwiseThePositionAndSize)
] }

#endif

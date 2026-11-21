#if os(Linux)
import Foundation
import SensoriumHost
import SensoriumLinuxHost

private func testNothingIsOfferedWithoutAGrantAndAFrame() {
    let state = PortalGrantState()
    let inventory = PortalDisplayInventory(grantState: state)
    expect(inventory.displays().isEmpty, "no grant, no host screen")
    let generation = state.install(grant: liveGrant(), sink: RecordingSink())
    expect(
        inventory.displays().isEmpty,
        "until a frame says how many pixels back each point, the host screen's scale is unknown and nothing is offered"
    )
    state.recordFrame(nodeID: grantedMonitor.nodeID, generation: generation, width: 3840, height: 2160)
    expect(inventory.displays().count == 1, "once a frame has arrived the granted monitor is offered")
    state.end()
    expect(inventory.displays().isEmpty, "an ended grant offers nothing")
}

private func testTheGrantedMonitorIsOfferedAtItsLogicalSizeAndBufferScale() {
    let state = PortalGrantState()
    let generation = state.install(grant: liveGrant(), sink: RecordingSink())
    state.recordFrame(nodeID: grantedMonitor.nodeID, generation: generation, width: 3840, height: 2160)
    guard let display = PortalDisplayInventory(grantState: state).displays().first else {
        expect(false, "the monitor is offered")
        return
    }
    let identity = PortalCaptureGeometry(stream: grantedMonitor)!.displayIdentity
    expect(display.id == identity, "the display ID is the stream's identity")
    expect(display.modeWidth == 1920 && display.modeHeight == 1080, "the logical size is the stream's size")
    expect(display.modePixelWidth == 3840 && display.modePixelHeight == 2160, "the pixels are the buffer's")
    expect(display.online && !display.asleep && display.mirrorsDisplay == 0, "it is a live, unmirrored screen")
    let wire = HostScreenDisplayIdentity(display)
    expect(wire == HostScreenDisplayIdentity(vendorNumber: 0, modelNumber: identity), "the wire identity carries the stream identity")
    expect(!PhysicalDisplayEvidence.isSensoriumCanvas(display), "it never reads as a display Sensorium created")
    expect(!PhysicalDisplayEvidence.isHeadlessStandIn(display), "nor as the headless placeholder")
    expect(!SharpScreen.isSharpScreen(display), "nor as a sharp screen")
    expect(HostScreenOfferEligibility.isOfferable(display, among: [display]), "the shared offer rule offers it")
}

private func testAFractionalScaleAndALaterResizeAreFollowed() {
    let state = PortalGrantState()
    let stream = PortalStream(nodeID: 61, id: nil, position: PortalPoint(x: 0, y: 0), size: PortalSize(width: 1707, height: 960))
    let generation = state.install(grant: liveGrant(streams: [stream]), sink: RecordingSink())
    state.recordFrame(nodeID: stream.nodeID, generation: generation, width: 2560, height: 1440)
    let inventory = PortalDisplayInventory(grantState: state)
    let first = inventory.displays()[0]
    expect(first.modeWidth == 1707 && first.modePixelWidth == 2560, "a 1.5x monitor keeps its fractional scale")
    state.recordFrame(nodeID: stream.nodeID, generation: generation, width: 1707, height: 960)
    let resized = inventory.displays()[0]
    expect(resized.modePixelWidth == 1707, "a later buffer size is the current scale")
    expect(resized.id == first.id, "the identity does not change with the buffer")
}

private func testAStreamWithNoSizeKeepsTheIdentityOfItsFirstFrame() {
    let state = PortalGrantState()
    let stream = PortalStream(nodeID: 62)
    let generation = state.install(grant: liveGrant(streams: [stream]), sink: RecordingSink())
    state.recordFrame(nodeID: stream.nodeID, generation: generation, width: 1920, height: 1080)
    let inventory = PortalDisplayInventory(grantState: state)
    let first = inventory.displays()[0]
    expect(first.modeWidth == 1920 && first.modePixelWidth == 1920, "the first frame stands in for the logical size")
    state.recordFrame(nodeID: stream.nodeID, generation: generation, width: 1280, height: 720)
    expect(inventory.displays()[0].id == first.id, "a later frame size does not change which display it is")
}

private func testOnlyFramesFromTheCurrentGrantAndKnownNodesOfferDisplays() {
    let state = PortalGrantState()
    let inventory = PortalDisplayInventory(grantState: state)
    let old = state.install(grant: liveGrant(), sink: RecordingSink())
    let current = state.install(grant: liveGrant(), sink: RecordingSink())
    state.recordFrame(nodeID: grantedMonitor.nodeID, generation: old, width: 1920, height: 1080)
    state.recordFrame(nodeID: grantedMonitor.nodeID + 1, generation: current, width: 2560, height: 1440)
    expect(inventory.displays().isEmpty, "a late frame or an unknown node cannot publish a monitor")
    state.recordFrame(nodeID: grantedMonitor.nodeID, generation: current, width: 3840, height: 2160)
    expect(inventory.displays().first?.modePixelWidth == 3840, "the offer uses the current authorized stream")
}

private func testMultiMonitorGrantsRequireDistinctIdentitiesAndLogicalGeometry() {
    let state = PortalGrantState()
    let inventory = PortalDisplayInventory(grantState: state)
    let unknownGeometry = PortalStream(nodeID: grantedMonitor.nodeID + 1)
    let generation = state.install(grant: liveGrant(streams: [grantedMonitor, unknownGeometry]), sink: RecordingSink())
    state.recordFrame(nodeID: unknownGeometry.nodeID, generation: generation, width: 1920, height: 1080)
    state.recordFrame(nodeID: grantedMonitor.nodeID, generation: generation, width: 3840, height: 2160)
    expect(inventory.displays().map(\.modePixelWidth) == [3840], "the other monitor cannot use its pixels as logical geometry")

    let duplicate = PortalStream(
        nodeID: unknownGeometry.nodeID, id: grantedMonitor.id, position: grantedMonitor.position, size: grantedMonitor.size
    )
    let ambiguous = state.install(grant: liveGrant(streams: [grantedMonitor, duplicate]), sink: RecordingSink())
    state.recordFrame(nodeID: grantedMonitor.nodeID, generation: ambiguous, width: 3840, height: 2160)
    expect(inventory.displays().isEmpty, "an ambiguous identity cannot be offered even when only one node has frames")
}

func portalDisplayInventoryTests() -> [(String, () throws -> Void)] { [
    ("nothing is offered without a grant and a frame", testNothingIsOfferedWithoutAGrantAndAFrame),
    ("the granted monitor is offered at its logical size and buffer scale", testTheGrantedMonitorIsOfferedAtItsLogicalSizeAndBufferScale),
    ("a fractional scale and a later resize are followed", testAFractionalScaleAndALaterResizeAreFollowed),
    ("a stream with no size keeps the identity of its first frame", testAStreamWithNoSizeKeepsTheIdentityOfItsFirstFrame),
    ("only frames from the current grant and known nodes offer displays", testOnlyFramesFromTheCurrentGrantAndKnownNodesOfferDisplays),
    ("multiple monitors require distinct identities and logical geometry", testMultiMonitorGrantsRequireDistinctIdentitiesAndLogicalGeometry)
] }
#endif

#if os(Linux)
import Foundation
import SensoriumHost
import SensoriumLinuxHost

private func testNothingIsOfferedWithoutAGrantAndAFrame() {
    let state = PortalGrantState()
    let inventory = PortalDisplayInventory(grantState: state)
    expect(inventory.displays().isEmpty, "no grant, no host screen")
    state.install(grant: liveGrant(), sink: RecordingSink())
    expect(
        inventory.displays().isEmpty,
        "until a frame says how many pixels back each point, the host screen's scale is unknown and nothing is offered"
    )
    state.recordFrame(width: 3840, height: 2160)
    expect(inventory.displays().count == 1, "once a frame has arrived the granted monitor is offered")
    state.end()
    expect(inventory.displays().isEmpty, "an ended grant offers nothing")
}

private func testTheGrantedMonitorIsOfferedAtItsLogicalSizeAndBufferScale() {
    let state = PortalGrantState()
    state.install(grant: liveGrant(), sink: RecordingSink())
    state.recordFrame(width: 3840, height: 2160)
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
    state.install(grant: liveGrant(streams: [stream]), sink: RecordingSink())
    state.recordFrame(width: 2560, height: 1440)
    let inventory = PortalDisplayInventory(grantState: state)
    let first = inventory.displays()[0]
    expect(first.modeWidth == 1707 && first.modePixelWidth == 2560, "a 1.5x monitor keeps its fractional scale")
    state.recordFrame(width: 1707, height: 960)
    let resized = inventory.displays()[0]
    expect(resized.modePixelWidth == 1707, "a later buffer size is the current scale")
    expect(resized.id == first.id, "the identity does not change with the buffer")
}

private func testAStreamWithNoSizeKeepsTheIdentityOfItsFirstFrame() {
    let state = PortalGrantState()
    let stream = PortalStream(nodeID: 62)
    state.install(grant: liveGrant(streams: [stream]), sink: RecordingSink())
    state.recordFrame(width: 1920, height: 1080)
    let inventory = PortalDisplayInventory(grantState: state)
    let first = inventory.displays()[0]
    expect(first.modeWidth == 1920 && first.modePixelWidth == 1920, "the first frame stands in for the logical size")
    state.recordFrame(width: 1280, height: 720)
    expect(inventory.displays()[0].id == first.id, "a later frame size does not change which display it is")
}

func portalDisplayInventoryTests() -> [(String, () throws -> Void)] { [
    ("nothing is offered without a grant and a frame", testNothingIsOfferedWithoutAGrantAndAFrame),
    ("the granted monitor is offered at its logical size and buffer scale", testTheGrantedMonitorIsOfferedAtItsLogicalSizeAndBufferScale),
    ("a fractional scale and a later resize are followed", testAFractionalScaleAndALaterResizeAreFollowed),
    ("a stream with no size keeps the identity of its first frame", testAStreamWithNoSizeKeepsTheIdentityOfItsFirstFrame)
] }
#endif

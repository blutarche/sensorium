#if os(Linux)
import Foundation
import SensoriumHost

/// The displays a Linux host can offer: only the monitor the portal granted,
/// described the way the shared host describes a display.
///
/// - The logical size is the stream's `size`; the pixels are the latest
///   PipeWire buffer's, so the backing scale is buffer width over logical
///   width, fractional scales included.
/// - The ID is the stream's identity (its `id`, else a hash of position and
///   size), and so is the wire identity: vendor 0 and that identity as the
///   model. No EDID reaches the portal, and vendor 0 never collides with the
///   identities Sensorium gives the displays it creates.
/// - Nothing is offered until a frame has arrived, because the scale is not
///   known before then.
public struct PortalDisplayInventory: Sendable {
    private let grantState: PortalGrantState

    public init(grantState: PortalGrantState) {
        self.grantState = grantState
    }

    public func displays() -> [DisplaySnapshot] {
        guard let live = grantState.live,
              let stream = live.stream,
              let geometry = live.geometry,
              let frame = live.frameSize else {
            return []
        }
        let logicalWidth = Int(geometry.logicalWidth.rounded())
        let logicalHeight = Int(geometry.logicalHeight.rounded())
        guard logicalWidth > 0, logicalHeight > 0 else { return [] }
        let origin = stream.position ?? PortalPoint(x: 0, y: 0)
        return [DisplaySnapshot(
            id: geometry.displayIdentity,
            pixelWidth: frame.width,
            pixelHeight: frame.height,
            modeWidth: logicalWidth,
            modeHeight: logicalHeight,
            modePixelWidth: frame.width,
            modePixelHeight: frame.height,
            bounds: CGRect(x: Double(origin.x), y: Double(origin.y), width: Double(logicalWidth), height: Double(logicalHeight)),
            online: true,
            builtin: false,
            main: true,
            vendorNumber: 0,
            modelNumber: geometry.displayIdentity
        )]
    }
}
#endif

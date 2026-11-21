#if os(Linux)
import Foundation
import SensoriumHost

/// The granted monitors as the shared host describes them. A monitor is
/// offered once its first frame establishes the scale from logical points
/// to pixels.
public struct PortalDisplayInventory: Sendable {
    private let grantState: PortalGrantState

    public init(grantState: PortalGrantState) {
        self.grantState = grantState
    }

    public func displays() -> [DisplaySnapshot] {
        guard let live = grantState.live else { return [] }
        return live.routableMonitors.enumerated().compactMap { index, target in
            guard let frame = target.monitor.frameSize else { return nil }
            let geometry = target.geometry
            let logicalWidth = Int(geometry.logicalWidth.rounded())
            let logicalHeight = Int(geometry.logicalHeight.rounded())
            let origin = target.monitor.stream.position ?? PortalPoint(x: 0, y: 0)
            return DisplaySnapshot(
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
                main: index == 0,
                vendorNumber: 0,
                modelNumber: geometry.displayIdentity
            )
        }
    }
}
#endif

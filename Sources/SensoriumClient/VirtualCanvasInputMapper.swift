public struct CanvasInputPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Maps a viewer video viewport onto the owned virtual canvas's logical
/// coordinate space through the letterboxed video rect actually presented
/// there. No physical-display coordinate is involved.
///
/// A point outside the video rect (over a letterbox/pillarbox bar) clamps to
/// the nearest edge of the canvas rather than being rejected: rejecting would
/// mean a button-down that drifts into the bar before its button-up never
/// reaches the host, stranding it held down remotely.
public struct VirtualCanvasInputMapper: Sendable {
    public let logicalWidth: Double
    public let logicalHeight: Double

    public init(logicalWidth: Double, logicalHeight: Double) {
        precondition(logicalWidth > 0 && logicalHeight > 0)
        self.logicalWidth = logicalWidth
        self.logicalHeight = logicalHeight
    }

    public func map(
        x: Double,
        y: Double,
        sourceWidth: Double,
        sourceHeight: Double,
        viewportWidth: Double,
        viewportHeight: Double
    ) -> CanvasInputPoint {
        let rect = CanvasPresentationLayout.videoRect(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight
        )
        guard rect.width > 0, rect.height > 0 else {
            return CanvasInputPoint(x: 0, y: 0)
        }
        let fractionX = clamp((x - rect.x) / rect.width, lower: 0, upper: 1)
        let fractionY = clamp((y - rect.y) / rect.height, lower: 0, upper: 1)
        return CanvasInputPoint(
            x: fractionX * logicalWidth,
            y: fractionY * logicalHeight
        )
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}

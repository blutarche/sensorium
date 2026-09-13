import SensoriumCore

/// Binds a shared session's input and viewer-size reporting to one non-primary
/// surface. The primary surface (0) uses `ClientSessionController` directly —
/// its `CanvasInputSending` conformance sends `surfaceID: nil`. Every other
/// surface needs its ID on the wire so the host knows which canvas the event
/// belongs to.
public struct SurfaceScopedInputSink: CanvasInputSending {
    private let session: ClientSessionController
    private let surfaceID: UInt32

    public init(session: ClientSessionController, surfaceID: UInt32) {
        self.session = session
        self.surfaceID = surfaceID
    }

    public func sendInput(_ event: SensoriumInputEvent) async throws {
        try await session.sendInput(event, surfaceID: surfaceID)
    }

    public func sendViewerDrawableSize(
        pixelWidth: Double,
        pixelHeight: Double,
        maximumScale: Double?
    ) async throws {
        try await session.sendViewerDrawableSize(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            surfaceID: surfaceID,
            maximumScale: maximumScale
        )
    }

    public func sendStreamScalePreference(_ preference: StreamScalePreference) async throws {
        try await session.sendStreamScalePreference(preference, surfaceID: surfaceID)
    }
}

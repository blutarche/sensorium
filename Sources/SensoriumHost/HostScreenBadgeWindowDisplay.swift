#if os(macOS)
extension HostScreenBadgeWindowController: HostScreenBadgeDisplaying {}

extension HostScreenAccountableMedia {
    /// The macOS wiring: the indicator is the badge window on the streamed
    /// display, which always shows.
    public convenience init(
        capturePermission: ScreenCapturePermissionGate,
        rawFactory: @escaping (VideoEncoderConfiguration, VideoPacketSequencer) -> any CanvasMediaStreaming,
        sessionLog: HostScreenSessionLogStore,
        deviceName: @escaping () -> String,
        reportedDeviceName: @escaping () -> String? = { nil },
        displayLabel: @escaping () -> String,
        onBadgeStop: @escaping @MainActor () -> Void
    ) {
        self.init(
            capturePermission: capturePermission,
            rawFactory: rawFactory,
            sessionLog: sessionLog,
            deviceName: deviceName,
            reportedDeviceName: reportedDeviceName,
            displayLabel: displayLabel,
            onBadgeStop: onBadgeStop,
            badgeFactory: { HostScreenBadgeWindowController(state: $0, targetDisplayID: $1) }
        )
    }
}
#endif

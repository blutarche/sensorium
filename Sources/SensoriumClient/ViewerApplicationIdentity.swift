/// The identifier a Linux desktop matches every Sensorium viewer window to
/// its own launcher entry by. The raw Wayland session window sets it as the
/// toplevel's `app_id`; GTK derives the same value from the process name, so
/// both paths use this one constant rather than two strings that could drift
/// apart. It matches `Packaging/linux/com.sensorium.viewer.desktop`.
enum ViewerApplicationIdentity {
    static let applicationID = "com.sensorium.viewer"
    static let applicationName = "Sensorium"
}

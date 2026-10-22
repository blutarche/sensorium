import SensoriumHost

/// The session log prints every line under one "Sensorium host: " prefix,
/// whether or not the line arrived carrying it.
func runHostSessionLogLineTests() {
    expect(
        HostSessionLog.printedLine("capture started on session canvas") == "Sensorium host: capture started on session canvas",
        "a bare line is printed under the host prefix"
    )
    expect(
        HostSessionLog.printedLine("Sensorium host: offered 1 host screens to Kestrel Laptop Pro: External Display")
            == "Sensorium host: offered 1 host screens to Kestrel Laptop Pro: External Display",
        "a line that already carries the prefix is printed with it once, not twice"
    )
    expect(
        HostSessionLog.unifiedLogLine("Sensorium host: key frame requested") == "key frame requested",
        "the unified log carries the line without the prefix, which its subsystem already says"
    )
    expect(
        HostSessionLog.unifiedLogLine("host screen: armed without asking first") == "host screen: armed without asking first",
        "a bare line reaches the unified log unchanged"
    )
    print("PASS: the session log prints each line under one host prefix and logs it without one")
}

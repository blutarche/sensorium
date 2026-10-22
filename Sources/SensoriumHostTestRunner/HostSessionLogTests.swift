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
    expect(
        HostSessionLog.printedLine("Sensorium host bound 100.64.1.7:4433; tailnet sources only")
            == "Sensorium host bound 100.64.1.7:4433; tailnet sources only",
        "a line that opens with the host name and no colon is printed as it is, which scripts waiting on it rely on"
    )
    expect(
        HostSessionLog.unifiedLogLine("Sensorium host bound 100.64.1.7:4433; tailnet sources only")
            == "bound 100.64.1.7:4433; tailnet sources only",
        "the unified log carries a colon-less line without the host name too"
    )
    print("PASS: the session log prints each line under one host prefix and logs it without one")
}

import SensoriumClient

/// Where the live provider looks for the `tailscale` binary is the platform's
/// own: a Linux distribution installs it on the system path, and none of the
/// macOS install locations exist there.
func testLocalTailscaleCandidatePathsTests() {
    let paths = LocalTailscaleStatusProvider.candidateExecutablePaths
    #if os(Linux)
    expect(
        paths == ["/usr/bin/tailscale", "/usr/sbin/tailscale", "/usr/local/bin/tailscale", "/bin/tailscale"],
        "a Linux viewer looks for tailscale where a distribution installs it, /usr/bin first -- got \(paths)"
    )
    #else
    expect(
        paths == [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        ],
        "a macOS viewer looks in both Homebrew prefixes and the Tailscale app -- got \(paths)"
    )
    #endif

    print("PASS: the live Tailscale provider looks for its binary where this platform installs it")
}

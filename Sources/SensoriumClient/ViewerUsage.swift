import Foundation

/// What `Sensorium --help`, and an argument the viewer cannot read, print.
/// The verbs are test scaffolding rather than a surface anybody is meant to
/// use, and this text says so, so nobody reads a usage line as an invitation
/// to run the app from a terminal.
public enum ViewerUsage {
    public static let lines: [String] = [
        "usage: Sensorium <pair|enter> [--trace <path.jsonl>] "
            + "[--system-shortcuts <local|remote-when-focused|remote-in-fullscreen>] "
            + "[--transport <quic|tcp-local-verification>]",
        "  pair <host> <port> <code>         pair with a machine once; its key is pinned afterwards",
        "  enter [sensorium://enter/<host>]  open the list of machines, with one of them named",
        "  --help                            print this and do nothing else",
        "  These verbs exist to check this build. Everything they reach is reachable from the window",
        "  the app opens when it is started with no arguments at all.",
        "  --transport is for diagnosing this machine only. tcp-local-verification drops TLS, so the",
        "  certificate saved at pairing is never checked; a normal session leaves it unset."
    ]
}

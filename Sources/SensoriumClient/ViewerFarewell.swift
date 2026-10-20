/// The line printed when the viewer quits out of a session.
public enum ViewerFarewell {
    /// Only a session canvas is a virtual display this host created, so only
    /// it is released on leaving.
    public static func line(sessionWasCanvas: Bool) -> String {
        sessionWasCanvas ? "Left; the virtual display has been released." : "Left."
    }
}

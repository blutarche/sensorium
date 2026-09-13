import Foundation

/// What the launch window's row says when a saved "Start with" preference
/// drives a machine's very first connect straight to a host screen and that
/// connect ends without a session -- refused by the host, or naming a
/// display that connect's own offer no longer lists. Every other host-screen
/// refusal is read under a Screen menu row a person just picked by its own
/// label (`HostScreenRefusalCopy.line(reason:)`'s own words already say
/// enough there); this one is the only refusal nobody picked from a menu at
/// all, so nothing else in the window says which screen it was trying.
public enum StartTargetConnectCopy {
    public static func line(reasonLine: String, displayLabel: String) -> String {
        "Sensorium tried to start with \(displayLabel). \(reasonLine)"
    }
}

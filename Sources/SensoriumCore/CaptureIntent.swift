import Foundation

/// Which capture target a session streams: the private virtual display this
/// host created (`sessionCanvas`), or one of this machine's own existing
/// displays (`hostScreen`), captured under the arming and consent gates in
/// docs/host-screen-design.md rather than by construction alone.
///
/// `token` is the opaque value the host minted for the specific display the
/// viewer chose from its `hostScreenList` offer (docs/host-screen-design.md
/// §5.4). It does
/// not name a display by itself; the host is the only party that can map it
/// back to one, and only for the session it was minted in.
public enum CaptureIntent: Equatable {
    case sessionCanvas
    case hostScreen(token: Data)
}

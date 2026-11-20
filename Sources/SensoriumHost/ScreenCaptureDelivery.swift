import Foundation

/// What one delivery from a capture stream turned out to be.
public enum ScreenCaptureDelivery: Equatable, Sendable {
    /// Pixels changed since the last delivery. The only kind that reaches the
    /// encoder, and the only kind counted as the screen changing.
    case screenChange
    /// A frame the stream attached an empty dirty-rect list to: the picture
    /// already sent, delivered again.
    case unchangedFrame
    /// `.idle`: the stream reporting no change, with no picture attached.
    case noChangeNotice
    /// Any other status update. It carries no picture, and says nothing about
    /// whether the screen changed.
    case otherStatus
}

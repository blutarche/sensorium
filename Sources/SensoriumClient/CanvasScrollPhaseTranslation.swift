#if canImport(AppKit)
import AppKit
import SensoriumCore

extension CanvasScrollPhase {
    /// `nil` for a plain scroll-wheel mouse, which never sets `NSEvent.phase`
    /// at all -- exactly the devices this protocol already forwarded pixel
    /// deltas for with no phase information, unchanged.
    public init?(_ nsPhase: NSEvent.Phase) {
        if nsPhase.contains(.began) {
            self = .began
        } else if nsPhase.contains(.cancelled) {
            self = .cancelled
        } else if nsPhase.contains(.ended) {
            self = .ended
        } else if nsPhase.contains(.changed) {
            self = .changed
        } else if nsPhase.contains(.mayBegin) {
            self = .mayBegin
        } else {
            return nil
        }
    }
}

extension CanvasScrollMomentumPhase {
    /// `NSEvent.momentumPhase` reuses `NSEvent.Phase`, but macOS only ever
    /// reports `.began`/`.changed`/`.ended` through it -- `CGMomentumScrollPhase`
    /// on the host side has no cases for anything else either.
    public init?(_ nsMomentumPhase: NSEvent.Phase) {
        if nsMomentumPhase.contains(.began) {
            self = .begin
        } else if nsMomentumPhase.contains(.changed) {
            self = .continue
        } else if nsMomentumPhase.contains(.ended) {
            self = .end
        } else {
            return nil
        }
    }
}
#endif

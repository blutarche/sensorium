#if canImport(AppKit)
import AppKit

/// The one "an attempt is under way" pulse every dot on the client uses:
/// opacity 1.0 to 0.35, 0.7s, eased, repeating until removed. Holds no state
/// of its own -- each caller decides, from its own model, when to apply and
/// remove it on the layer it owns.
enum ViewerPulse {
    private static let animationKey = "viewerPulse"

    /// A repeat call while the pulse is already running is a no-op, and
    /// nothing is added at all when the person has asked this machine to
    /// reduce motion.
    static func apply(to layer: CALayer?) {
        guard let layer, layer.animation(forKey: animationKey) == nil else { return }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.35
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: animationKey)
    }

    static func remove(from layer: CALayer?) {
        layer?.removeAnimation(forKey: animationKey)
        layer?.opacity = 1
    }
}
#endif

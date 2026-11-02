#if canImport(AppKit)
import AppKit

@MainActor
private final class AppearanceLayerSources {
    var colors: [String: [NSColor]] = [:]
}

@MainActor
public enum AppearanceLayerColors {
    private static let sources = NSMapTable<CALayer, AppearanceLayerSources>.weakToStrongObjects()

    public static func refresh(in view: NSView) {
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            if let layer = view.layer { refresh(layer) }
        }
        view.needsDisplay = true
        for child in view.subviews { refresh(in: child) }
    }

    private static func refresh(_ layer: CALayer) {
        if let source = sources.object(forKey: layer) {
            for (key, colors) in source.colors {
                if key == "colors" { layer.setValue(colors.map(\.cgColor), forKey: key) }
                else { layer.setValue(colors.first?.cgColor, forKey: key) }
            }
        }
        for child in layer.sublayers ?? [] { refresh(child) }
    }

    fileprivate static func set(_ colors: [NSColor], on layer: CALayer, key: String) {
        let source = sources.object(forKey: layer) ?? AppearanceLayerSources()
        source.colors[key] = colors
        sources.setObject(source, forKey: layer)
        refresh(layer)
    }
}

@MainActor
public extension CALayer {
    func setAppearanceColor(_ color: NSColor?, for key: String) {
        AppearanceLayerColors.set(color.map { [$0] } ?? [], on: self, key: key)
    }

    func setAppearanceGradientColors(_ colors: [NSColor]) {
        AppearanceLayerColors.set(colors, on: self, key: "colors")
    }
}
#endif

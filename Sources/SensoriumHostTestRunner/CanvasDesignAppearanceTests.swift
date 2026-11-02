import AppKit
import Foundation
import SensoriumCore
import SensoriumHost

/// WCAG 2.x relative luminance and contrast ratio of two opaque sRGB colours.
private func contrastRatio(_ first: DesignColor, _ second: DesignColor) -> Double {
    func channel(_ value: Double) -> Double {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    func luminance(_ color: DesignColor) -> Double {
        0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }
    let a = luminance(first)
    let b = luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

private func hex(_ color: DesignColor) -> String {
    func channel(_ value: Double) -> String {
        String(format: "%02X", Int((value * 255).rounded()))
    }
    return "#" + channel(color.red) + channel(color.green) + channel(color.blue)
}

/// Every opaque token with its dark and light value, as `docs/design-system.md` records them.
private let recordedTokens: [(String, DesignColor, String, String)] = [
    ("bg", CanvasDesign.bg, "#0A0A0C", "#F4F4F6"),
    ("bg2", CanvasDesign.bg2, "#121216", "#FFFFFF"),
    ("bg3", CanvasDesign.bg3, "#1A1A20", "#EAEAED"),
    ("bg4", CanvasDesign.bg4, "#24242C", "#DCDCE0"),
    ("chromeBg", CanvasDesign.chromeBg, "#07070A", "#EDEDF0"),
    ("chromeBg2", CanvasDesign.chromeBg2, "#0E0E14", "#E4E4E8"),
    ("chromeBgHover", CanvasDesign.chromeBgHover, "#14141A", "#DDDDE2"),
    ("chromeBorder", CanvasDesign.chromeBorder, "#18181E", "#D4D4D9"),
    ("chromeBorder2", CanvasDesign.chromeBorder2, "#1F1F26", "#DDDDE2"),
    ("chromeInk", CanvasDesign.chromeInk, "#E8E5DE", "#0A0A0C"),
    ("chromeInk2", CanvasDesign.chromeInk2, "#C8C5BD", "#18181D"),
    ("chromeMuted", CanvasDesign.chromeMuted, "#8A8A92", "#5E5E66"),
    ("chromeMuted2", CanvasDesign.chromeMuted2, "#5A5A63", "#8C8C94"),
    ("line", CanvasDesign.line, "#24242C", "#DDDDE2"),
    ("line2", CanvasDesign.line2, "#34343F", "#BFBFC6"),
    ("lineHi", CanvasDesign.lineHi, "#43434F", "#8E8E96"),
    ("ink", CanvasDesign.ink, "#F2EFEA", "#0A0A0C"),
    ("ink2", CanvasDesign.ink2, "#C8C5BD", "#18181D"),
    ("muted", CanvasDesign.muted, "#8C8C94", "#4A4A52"),
    ("muted2", CanvasDesign.muted2, "#5A5A63", "#6C6C74"),
    ("muted3", CanvasDesign.muted3, "#3A3A44", "#9C9CA4"),
    ("accent", CanvasDesign.accent, "#7C70F5", "#5C51D0"),
    ("accentHi", CanvasDesign.accentHi, "#9088F8", "#5047B8"),
    ("accentDeep", CanvasDesign.accentDeep, "#5A4FC0", "#3F356E"),
    ("accent2", CanvasDesign.accent2, "#F0A8D0", "#C87AAA"),
    ("accent2Hi", CanvasDesign.accent2Hi, "#F5BFE0", "#D48FBA"),
    ("accent2Deep", CanvasDesign.accent2Deep, "#C87AAA", "#A05E88"),
    ("ok", CanvasDesign.ok, "#6FBE83", "#267340"),
    ("bad", CanvasDesign.bad, "#E26F5C", "#B93A26"),
    ("info", CanvasDesign.info, "#8EE0E8", "#157383"),
    ("warn", CanvasDesign.warn, "#E0B85D", "#8F6000")
]

@MainActor
func runCanvasDesignAppearanceTests() async {
    // The dark values are the committed ones, whichever way they are read.
    for (name, color, dark, _) in recordedTokens {
        expect(hex(color) == dark, "\(name) reads \(dark) by default, not \(hex(color))")
        expect(hex(color.resolved(for: .dark)) == dark, "\(name) resolves to \(dark) in dark")
    }
    expect(
        CanvasDesign.bg.resolved(for: .dark) == DesignColor(hex: 0x0A0A0C)
            && CanvasDesign.ink.resolved(for: .dark) == DesignColor(hex: 0xF2EFEA),
        "a resolved colour equals the single-value colour of the same hex"
    )

    // The light values are the recorded ones.
    for (name, color, _, light) in recordedTokens {
        expect(hex(color.resolved(for: .light)) == light, "\(name) resolves to \(light) in light, not \(hex(color.resolved(for: .light)))")
    }

    // The translucent accents follow the accent in each appearance.
    let translucent: [(String, DesignColor, DesignColor, Double, Double)] = [
        ("accentSoft", CanvasDesign.accentSoft, CanvasDesign.accent, 0.10, 0.08),
        ("accentBorder", CanvasDesign.accentBorder, CanvasDesign.accent, 0.30, 0.32),
        ("selection", CanvasDesign.selection, CanvasDesign.accent, 0.32, 0.20),
        ("accent2Soft", CanvasDesign.accent2Soft, CanvasDesign.accent2, 0.10, 0.08),
        ("accent2Border", CanvasDesign.accent2Border, CanvasDesign.accent2, 0.30, 0.30)
    ]
    for (name, color, base, darkAlpha, lightAlpha) in translucent {
        for appearance in ResolvedAppearance.allCases {
            let alpha = appearance == .dark ? darkAlpha : lightAlpha
            let resolved = color.resolved(for: appearance)
            let source = base.resolved(for: appearance)
            expect(
                hex(resolved) == hex(source) && resolved.alpha == alpha,
                "\(name) is the accent at \(alpha) in \(appearance.rawValue)"
            )
        }
    }

    // Light readability. Ink is read on every surface it is drawn on. muted-2, muted-3 and
    // chrome-muted-2 are the design system's disabled and decorative tones, so they carry no floor.
    // The accent-2 family is a data-viz highlight and border colour, drawn as lines and never as text; its light
    // values (as the system states them) sit below 3:1 on the light surfaces, so no floor is asserted for them.
    let surfaces: [(String, DesignColor)] = [
        ("bg", CanvasDesign.bg), ("bg2", CanvasDesign.bg2), ("bg3", CanvasDesign.bg3), ("bg4", CanvasDesign.bg4),
        ("chromeBg", CanvasDesign.chromeBg), ("chromeBg2", CanvasDesign.chromeBg2), ("chromeBgHover", CanvasDesign.chromeBgHover)
    ]
    let floors: [(String, DesignColor, Double)] = [
        ("ink", CanvasDesign.ink, 4.5), ("ink2", CanvasDesign.ink2, 4.5),
        ("chromeInk", CanvasDesign.chromeInk, 4.5), ("chromeInk2", CanvasDesign.chromeInk2, 4.5),
        ("muted", CanvasDesign.muted, 4.5), ("chromeMuted", CanvasDesign.chromeMuted, 4.5),
        ("accent", CanvasDesign.accent, 3), ("accentHi", CanvasDesign.accentHi, 3), ("accentDeep", CanvasDesign.accentDeep, 4.5),
        ("ok", CanvasDesign.ok, 3), ("bad", CanvasDesign.bad, 3), ("info", CanvasDesign.info, 3), ("warn", CanvasDesign.warn, 3)
    ]
    for (surfaceName, surface) in surfaces {
        let ground = surface.resolved(for: .light)
        for (name, color, floor) in floors {
            let ratio = contrastRatio(color.resolved(for: .light), ground)
            expect(ratio >= floor, "\(name) on \(surfaceName) is \(ratio):1 in light, below \(floor):1")
        }
    }
    // Buttons fill with an accent or status colour and set their title in chromeBg.
    for fill in [CanvasDesign.accent, CanvasDesign.ok, CanvasDesign.bad, CanvasDesign.info, CanvasDesign.warn] {
        let ratio = contrastRatio(CanvasDesign.chromeBg.resolved(for: .light), fill.resolved(for: .light))
        expect(ratio >= 4.5, "a chromeBg title on the light fill \(hex(fill.resolved(for: .light))) is \(ratio):1, below 4.5:1")
    }

    // A colour's NSColor and CGColor follow the appearance they are drawn in.
    guard let aqua = NSAppearance(named: .aqua), let darkAqua = NSAppearance(named: .darkAqua) else {
        expect(false, "the system appearances exist")
        return
    }
    func srgb(_ color: NSColor) -> String {
        guard let converted = color.usingColorSpace(.sRGB) else { return "unconvertible" }
        func channel(_ value: CGFloat) -> String { String(format: "%02X", Int((value * 255).rounded())) }
        return "#" + channel(converted.redComponent) + channel(converted.greenComponent) + channel(converted.blueComponent)
    }
    func srgb(_ color: CGColor) -> String {
        guard let converted = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return "unconvertible" }
        func channel(_ value: CGFloat) -> String { String(format: "%02X", Int((value * 255).rounded())) }
        return "#" + channel(c[0]) + channel(c[1]) + channel(c[2])
    }
    var inDark = ""
    var inLight = ""
    darkAqua.performAsCurrentDrawingAppearance { inDark = srgb(CanvasDesign.bg.nsColor) }
    aqua.performAsCurrentDrawingAppearance { inLight = srgb(CanvasDesign.bg.nsColor) }
    expect(inDark == "#0A0A0C" && inLight == "#F4F4F6", "bg's NSColor is dark in dark aqua and light in aqua: \(inDark), \(inLight)")
    darkAqua.performAsCurrentDrawingAppearance { inDark = srgb(CanvasDesign.bg.cgColor) }
    aqua.performAsCurrentDrawingAppearance { inLight = srgb(CanvasDesign.bg.cgColor) }
    expect(inDark == "#0A0A0C" && inLight == "#F4F4F6", "bg's CGColor resolves in the drawing appearance: \(inDark), \(inLight)")
    expect(
        srgb(CanvasDesign.bg.cgColor(in: darkAqua)) == "#0A0A0C" && srgb(CanvasDesign.bg.cgColor(in: aqua)) == "#F4F4F6",
        "cgColor(in:) names the appearance without a drawing scope"
    )
    let translucentLight = CanvasDesign.selection.cgColor(in: aqua)
    expect(translucentLight.alpha == 0.20, "a translucent token keeps its opacity through the appearance lookup")

    // The view helper resolves layer colours in the view's own appearance.
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
    view.wantsLayer = true
    view.appearance = aqua
    view.resolvingDesignColors { view.layer?.backgroundColor = CanvasDesign.bg.cgColor }
    expect(view.layer?.backgroundColor.map(srgb) == "#F4F4F6", "a layer colour set through the helper is light in a light view")
    view.appearance = darkAqua
    view.resolvingDesignColors { view.layer?.backgroundColor = CanvasDesign.bg.cgColor }
    expect(view.layer?.backgroundColor.map(srgb) == "#0A0A0C", "and dark once the view turns dark")

    let bound = NSView(frame: .zero)
    bound.wantsLayer = true
    bound.layer?.setAppearanceColor(CanvasDesign.bg4.nsColor, for: "backgroundColor")
    bound.layer?.setAppearanceColor(CanvasDesign.line.nsColor, for: "borderColor")
    let alphaLayer = CALayer()
    alphaLayer.setAppearanceColor(CanvasDesign.accentBorder.nsColor, for: "backgroundColor")
    bound.layer?.addSublayer(alphaLayer)
    let gradient = CAGradientLayer()
    gradient.setAppearanceGradientColors([CanvasDesign.accent.nsColor, CanvasDesign.accent2.nsColor])
    bound.layer?.addSublayer(gradient)
    for mode in [ResolvedAppearance.light, .dark, .light] {
        bound.appearance = mode == .light ? aqua : darkAqua
        AppearanceLayerColors.refresh(in: bound)
        expect(bound.layer?.backgroundColor == CanvasDesign.bg4.resolved(for: mode).nsColor.cgColor, "bound fill follows appearance")
        expect(bound.layer?.borderColor == CanvasDesign.line.resolved(for: mode).nsColor.cgColor, "equal dark tokens retain distinct light values")
        expect(alphaLayer.backgroundColor == CanvasDesign.accentBorder.resolved(for: mode).nsColor.cgColor, "alphaLayer colors follow appearance")
        expect((gradient.colors as? [CGColor]) == [CanvasDesign.accent, CanvasDesign.accent2].map { $0.resolved(for: mode).nsColor.cgColor }, "gradient colors follow appearance")
    }

    bound.layer?.setAppearanceColor(nil, for: "backgroundColor")
    AppearanceLayerColors.refresh(in: bound)
    expect(bound.layer?.backgroundColor == nil, "clearing a bound fill survives appearance refresh")

    print("PASS: the design tokens carry a dark and a light value, the dark ones unchanged, the light ones readable, and resolve per appearance")
}

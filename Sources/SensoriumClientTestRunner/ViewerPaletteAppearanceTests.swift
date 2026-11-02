import Foundation
import SensoriumClient
import SensoriumCore

/// WCAG 2.x relative luminance and contrast ratio of two opaque sRGB colours.
private func contrastRatio(_ first: ViewerColor, _ second: ViewerColor) -> Double {
    func channel(_ value: Double) -> Double {
        value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    func luminance(_ color: ViewerColor) -> Double {
        0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }
    let a = luminance(first)
    let b = luminance(second)
    return (max(a, b) + 0.05) / (min(a, b) + 0.05)
}

func testViewerPaletteDarkValuesAreTheCommittedOnes() {
    let committed: [(String, ViewerColor, String)] = [
        ("chromeBg", ViewerPalette.chromeBg, "#07070A"),
        ("chromeBg2", ViewerPalette.chromeBg2, "#0E0E14"),
        ("chromeBorder2", ViewerPalette.chromeBorder2, "#1F1F26"),
        ("bg4", ViewerPalette.bg4, "#24242C"),
        ("line", ViewerPalette.line, "#24242C"),
        ("ink", ViewerPalette.ink, "#F2EFEA"),
        ("muted", ViewerPalette.muted, "#8C8C94"),
        ("muted2", ViewerPalette.muted2, "#5A5A63"),
        ("accent", ViewerPalette.accent, "#7C70F5"),
        ("accentHi", ViewerPalette.accentHi, "#9088F8"),
        ("accent2", ViewerPalette.accent2, "#F0A8D0"),
        ("selection", ViewerPalette.selection, "#7C70F5"),
        ("scrim", ViewerPalette.scrim, "#000000"),
        ("ok", ViewerPalette.ok, "#6FBE83"),
        ("bad", ViewerPalette.bad, "#E26F5C"),
        ("info", ViewerPalette.info, "#8EE0E8"),
        ("warn", ViewerPalette.warn, "#E0B85D")
    ]
    for (name, color, hex) in committed {
        expect(color.hexString == hex, "\(name) is unchanged in the default reading: \(color.hexString) vs \(hex)")
        expect(color.hexString(for: .dark) == hex, "\(name) reads \(hex) in dark")
        expect(color.resolved(for: .dark).hexString == hex, "\(name) resolves to \(hex) in dark")
    }
    expect(
        ViewerPalette.selection.alpha == 0.32 && ViewerPalette.scrim.alpha == 0.66,
        "the translucent tokens keep their dark opacity"
    )
}

func testViewerPaletteLightValuesAreReadableOnTheLightSurfaces() {
    let surfaces: [(String, ViewerColor)] = [
        ("chromeBg", ViewerPalette.chromeBg),
        ("chromeBg2", ViewerPalette.chromeBg2),
        ("bg4", ViewerPalette.bg4)
    ]
    let text: [(String, ViewerColor, Double)] = [
        ("ink", ViewerPalette.ink, 4.5),
        ("muted", ViewerPalette.muted, 3),
        ("accent", ViewerPalette.accent, 3),
        ("accentHi", ViewerPalette.accentHi, 3),
        ("accent2", ViewerPalette.accent2, 3),
        ("ok", ViewerPalette.ok, 3),
        ("bad", ViewerPalette.bad, 3),
        ("info", ViewerPalette.info, 3),
        ("warn", ViewerPalette.warn, 3)
    ]
    for (surfaceName, surface) in surfaces {
        let ground = surface.resolved(for: .light)
        for (name, color, floor) in text {
            let ratio = contrastRatio(color.resolved(for: .light), ground)
            expect(ratio >= floor, "\(name) on \(surfaceName) is \(ratio):1 in light, below \(floor):1")
        }
    }
    for fill in [ViewerPalette.accent, ViewerPalette.ok, ViewerPalette.bad, ViewerPalette.info, ViewerPalette.warn] {
        let ratio = contrastRatio(
            ViewerPalette.chromeBg.resolved(for: .light),
            fill.resolved(for: .light)
        )
        expect(ratio >= 4.5, "text in chromeBg on the light fill \(fill.hexString(for: .light)) is \(ratio):1, below 4.5:1")
    }
}

func testViewerPaletteLightValuesAreTheRecordedOnes() {
    let recorded: [(String, ViewerColor, String)] = [
        ("chromeBg", ViewerPalette.chromeBg, "#ECE9E2"),
        ("chromeBg2", ViewerPalette.chromeBg2, "#F3F1EB"),
        ("chromeBorder2", ViewerPalette.chromeBorder2, "#CCC8BE"),
        ("bg4", ViewerPalette.bg4, "#E0DDD5"),
        ("line", ViewerPalette.line, "#DAD6CD"),
        ("ink", ViewerPalette.ink, "#1A1917"),
        ("muted", ViewerPalette.muted, "#626068"),
        ("muted2", ViewerPalette.muted2, "#7C7A82"),
        ("accent", ViewerPalette.accent, "#5B4FDB"),
        ("accentHi", ViewerPalette.accentHi, "#6A5EEA"),
        ("accent2", ViewerPalette.accent2, "#B8437F"),
        ("selection", ViewerPalette.selection, "#5B4FDB"),
        ("scrim", ViewerPalette.scrim, "#000000"),
        ("ok", ViewerPalette.ok, "#267340"),
        ("bad", ViewerPalette.bad, "#B93A26"),
        ("info", ViewerPalette.info, "#157383"),
        ("warn", ViewerPalette.warn, "#8F6000")
    ]
    for (name, color, hex) in recorded {
        expect(color.hexString(for: .light) == hex, "\(name) reads \(hex) in light, not \(color.hexString(for: .light))")
        expect(color.resolved(for: .light).hexString == hex, "\(name) resolves to \(hex) in light")
    }
}

func testViewerColorResolvesOneVariantAndKeepsOpacityAcrossBoth() {
    let both = ViewerColor(dark: 0x102030, light: 0xE0D0C0)
    expect(both.hexString == "#102030", "the default reading is the dark value")
    expect(both.hexString(for: .light) == "#E0D0C0", "the light reading is the light value")
    let light = both.resolved(for: .light)
    expect(
        light.hexString(for: .dark) == "#E0D0C0" && light.hexString(for: .light) == "#E0D0C0",
        "a resolved colour reads the same in both appearances"
    )
    let faded = both.withAlpha(0.4)
    expect(
        faded.alpha == 0.4 && faded.resolved(for: .light).alpha == 0.4
            && faded.hexString == "#102030" && faded.hexString(for: .light) == "#E0D0C0",
        "withAlpha changes opacity and leaves both variants"
    )
    let single = ViewerColor(hex: 0x336699)
    expect(
        single.hexString(for: .light) == single.hexString(for: .dark),
        "a colour made from one hex is the same in both appearances"
    )
    expect(
        ViewerPalette.color(for: .ok).hexString(for: .light) == ViewerPalette.ok.hexString(for: .light),
        "a status tone keeps both variants"
    )
}

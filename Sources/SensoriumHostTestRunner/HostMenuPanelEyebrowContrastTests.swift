import AppKit
import Foundation
import SensoriumHost

/// The menu-bar panel's status eyebrow is the design system's muted token on
/// the panel's own surface. Judged on the pixels the panel actually draws:
/// thin mono glyphs only ever reach a fraction of their nominal colour, so
/// a token that passes on paper can still drop under 4.5:1 on screen.
@MainActor
func runHostMenuPanelEyebrowContrastTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)

    func luminance(_ red: Int, _ green: Int, _ blue: Int) -> Double {
        func channel(_ value: Int) -> Double {
            let v = Double(value) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }

    func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    let presentation = HostOperatorStatus(
        connection: .hosting(address: "203.0.113.42"),
        permissions: granted
    ).presentation(now: Date())
    expect(presentation.eyebrow == "READY", "the status this checks is READY -- got \(presentation.eyebrow)")
    expect(
        presentation.eyebrowColor == CanvasDesign.muted,
        "a calm status reads in the muted token, not a colour of its own"
    )

    guard let image = CanvasHostTestHooks.menuBarPanelImage(presentation),
          let data = image.dataProvider?.data as Data? else {
        fatalError("the menu-bar panel drew no bitmap")
    }
    let bytesPerPixel = image.bitsPerPixel / 8
    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        return (Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2]))
    }

    // The eyebrow is the first line, inside the panel's top 34 points.
    let scale = Double(image.width) / 288
    let background = pixel(1, 1)
    let backgroundLuminance = luminance(background.0, background.1, background.2)
    var worst = 0.0
    var peak = background
    for y in 0..<min(image.height, Int(34 * scale)) {
        for x in 0..<image.width {
            let candidate = pixel(x, y)
            let ratio = contrast(luminance(candidate.0, candidate.1, candidate.2), backgroundLuminance)
            if ratio > worst {
                worst = ratio
                peak = candidate
            }
        }
    }
    expect(
        worst >= 4.5,
        "the READY eyebrow's brightest drawn pixel \(peak) on \(background) is \(worst):1, under the 4.5:1 AA floor"
    )

    print("PASS: the menu-bar panel's READY eyebrow reaches AA contrast as drawn")
}

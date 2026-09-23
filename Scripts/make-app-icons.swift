#!/usr/bin/env swift
// Draws the Sensorium app icons from code and assembles them into .icns files.
//
// Both marks are two overlapping screens, offset so the near one sits down and
// to the right of the far one -- one machine's screen seen from another. A moat
// of tile background is knocked out around the near screen so the two never
// merge into one blob at small sizes. The geometry is identical in both
// bundles; they differ in the tone of the near screen, which is what survives
// greyscale and a 16pt list row where a fiddly interior would not. The host is
// solid ink -- it is the machine that is the screen being shared -- and the
// viewer is solid accent -- it is the window you look through. The far screen
// carries a fill too, for what the mark means, but it never shows: at this
// offset it is reduced to a stroke-wide corner either way.
//
// Everything here is deterministic: fixed geometry, no timestamps, no system
// fonts, no asset files. Scripts/test-package-apps.sh depends on packaging
// being byte-reproducible, so the icons must be too.
//
// Usage: swift Scripts/make-app-icons.swift <output-directory>
//        swift Scripts/make-app-icons.swift --linux <output-directory>
//
// The --linux mode writes the viewer mark alone, at the freedesktop icon
// theme's sizes, in the hicolor layout a Linux package installs. Same
// geometry, same renderer: there is one drawing of this mark, and a second
// renderer would be a second drawing that drifts.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Design system tokens (docs/design-system.md)

let bg = 0x0A0A0C
let line2 = 0x34343F
let ink = 0xF2EFEA
let accent = 0x7C70F5

func color(_ hex: Int, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// MARK: - Geometry, in Apple's 1024pt icon grid

let grid: CGFloat = 1024
/// Apple's macOS app tile: 824x824 centred in the 1024 canvas, corner radius
/// 185.4. The transparent margin around it is part of the convention, not slack.
let tileSide: CGFloat = 824
let tileCorner: CGFloat = 185.4
/// Squircle exponent. 2 would give circular corners; 5 approximates the
/// continuous-curvature corner macOS has used since Big Sur.
let tileCornerExponent: CGFloat = 5

let tileBorderWidth: CGFloat = 5
/// Each screen is 16:10, the aspect of the canvas this product streams.
let screenSize = CGSize(width: 500, height: 312.5)
let screenStroke: CGFloat = 96
/// Tile background knocked out around the near screen. The 1024 grid maps to
/// the 16px render at 1:64, so this is a pixel of separation at the size where
/// separation is hardest to keep.
let screenMoat: CGFloat = 72
/// Centre-to-centre offset of the two screens: the near one sits down-right of
/// the far one. Stroke plus moat exactly, on both axes, and the exactness is
/// the point. Any less and the moat eats into the far screen's stroke; any
/// more and it leaves a sliver of the far screen's interior hanging past the
/// moat, which at icon size reads as a broken notch rather than as depth. At
/// this offset the far screen renders as its left edge, its whole top edge and
/// a square top-right corner -- a rectangle with its bottom-right hidden.
let screenOffset = CGSize(width: screenStroke + screenMoat, height: screenStroke + screenMoat)
let screenCorner: CGFloat = 20

/// Quarter superellipse from (0, r) to (r, 0), sampled so no chord is long
/// enough to facet. Uniform sampling in one axis breaks down where the curve
/// turns, so each half is sampled along the axis it moves slowly in.
func superellipseQuarter(radius r: CGFloat, exponent n: CGFloat, steps: Int) -> [CGPoint] {
    let mid = r * pow(2, -1 / n)
    func other(_ v: CGFloat) -> CGFloat { r * pow(max(0, 1 - pow(v / r, n)), 1 / n) }
    var points: [CGPoint] = []
    for i in 0...steps {
        let x = mid * CGFloat(i) / CGFloat(steps)
        points.append(CGPoint(x: x, y: other(x)))
    }
    for i in stride(from: steps - 1, through: 0, by: -1) {
        let y = mid * CGFloat(i) / CGFloat(steps)
        points.append(CGPoint(x: other(y), y: y))
    }
    return points
}

/// Rounded rect with superellipse corners, walked counter-clockwise from the
/// bottom edge. Each corner arc spans that corner's two tangent points.
func squirclePath(in rect: CGRect, radius r: CGFloat, exponent n: CGFloat) -> CGPath {
    let quarter = superellipseQuarter(radius: r, exponent: n, steps: 192)
    let path = CGMutablePath()
    path.move(to: CGPoint(x: rect.minX + r, y: rect.minY))
    path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
    // Anchors are the corner-inset centres; each corner mirrors the quarter arc,
    // reversed where the walk enters the corner at the arc's far end. The
    // straight edges fall out of the line into each corner's first point.
    let corners: [(anchor: CGPoint, sx: CGFloat, sy: CGFloat, reversed: Bool)] = [
        (CGPoint(x: rect.maxX - r, y: rect.minY + r), 1, -1, false),
        (CGPoint(x: rect.maxX - r, y: rect.maxY - r), 1, 1, true),
        (CGPoint(x: rect.minX + r, y: rect.maxY - r), -1, 1, false),
        (CGPoint(x: rect.minX + r, y: rect.minY + r), -1, -1, true),
    ]
    for corner in corners {
        let arc = corner.reversed ? Array(quarter.reversed()) : quarter
        for point in arc {
            path.addLine(
                to: CGPoint(
                    x: corner.anchor.x + corner.sx * point.x,
                    y: corner.anchor.y + corner.sy * point.y
                )
            )
        }
    }
    path.closeSubpath()
    return path
}

// MARK: - The marks

enum ScreenStyle {
    case outline(Int)
    case solid(Int)
}

struct Mark {
    let name: String
    let far: ScreenStyle
    let near: ScreenStyle
}

let marks = [
    Mark(name: "Sensorium", far: .outline(ink), near: .solid(accent)),
    Mark(name: "SensoriumHost", far: .solid(ink), near: .solid(ink)),
]

func screenPath(_ rect: CGRect, corner: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
}

func drawScreen(_ style: ScreenStyle, in rect: CGRect, into context: CGContext) {
    switch style {
    case .solid(let hex):
        context.addPath(screenPath(rect, corner: screenCorner))
        context.setFillColor(color(hex))
        context.fillPath()
    case .outline(let hex):
        // The stroke straddles the path, so inset by half of it to keep the
        // screen's outer edge on its stated bounds.
        let centre = rect.insetBy(dx: screenStroke / 2, dy: screenStroke / 2)
        context.addPath(screenPath(centre, corner: screenCorner - screenStroke / 2))
        context.setStrokeColor(color(hex))
        context.setLineWidth(screenStroke)
        context.strokePath()
    }
}

func draw(_ mark: Mark, into context: CGContext, pixels: CGFloat) {
    let scale = pixels / grid
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.interpolationQuality = .high
    context.scaleBy(x: scale, y: scale)

    let tile = CGRect(
        x: (grid - tileSide) / 2, y: (grid - tileSide) / 2,
        width: tileSide, height: tileSide
    )
    let tilePath = squirclePath(in: tile, radius: tileCorner, exponent: tileCornerExponent)
    context.addPath(tilePath)
    context.setFillColor(color(bg))
    context.fillPath()

    // Flat, no shadow: the tile edge is a border, exactly as panels are.
    let borderRect = tile.insetBy(dx: tileBorderWidth / 2, dy: tileBorderWidth / 2)
    context.addPath(
        squirclePath(
            in: borderRect,
            radius: tileCorner - tileBorderWidth / 2,
            exponent: tileCornerExponent
        )
    )
    context.setStrokeColor(color(line2))
    context.setLineWidth(tileBorderWidth)
    context.strokePath()

    // The moat is knocked out in the tile's own colour, so without this clip it
    // would punch an opaque bite through the tile edge and the border with it.
    context.saveGState()
    context.addPath(tilePath)
    context.clip()

    let far = CGRect(
        x: grid / 2 - screenOffset.width / 2 - screenSize.width / 2,
        y: grid / 2 + screenOffset.height / 2 - screenSize.height / 2,
        width: screenSize.width, height: screenSize.height
    )
    let near = far.offsetBy(dx: screenOffset.width, dy: -screenOffset.height)

    drawScreen(mark.far, in: far, into: context)

    // Interrupt the far screen around the near one. Offsetting a rounded rect
    // outwards grows its radius by the same amount, which keeps the moat an
    // even width the whole way round.
    context.addPath(
        screenPath(
            near.insetBy(dx: -screenMoat, dy: -screenMoat),
            corner: screenCorner + screenMoat
        )
    )
    context.setFillColor(color(bg))
    context.fillPath()

    drawScreen(mark.near, in: near, into: context)
    context.restoreGState()
}

// MARK: - Emit

/// The set `iconutil` expects. Each is drawn at its own pixel size rather than
/// downsampled, so the heavy strokes stay crisp at the sizes that matter.
let iconSizes: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

/// The freedesktop icon theme's sizes, which are not Apple's. A desktop
/// environment picks the nearest one it has, so the small end matters most:
/// 16 and 24 are list rows and window buttons, 22 is a KDE panel.
let hicolorSizes = [16, 22, 24, 32, 48, 64, 128, 256, 512]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-app-icons: \(message)\n".utf8))
    exit(1)
}

func renderPNG(_ mark: Mark, pixels: Int, to url: URL) {
    guard
        let context = CGContext(
            data: nil,
            width: pixels, height: pixels,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { fail("could not create a \(pixels)x\(pixels) bitmap context") }
    draw(mark, into: context, pixels: CGFloat(pixels))
    guard let image = context.makeImage() else { fail("could not snapshot \(url.lastPathComponent)") }
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )
    else { fail("could not open \(url.path) for writing") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
}

func run(_ launchPath: String, _ arguments: [String]) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    do { try process.run() } catch { fail("could not run \(launchPath): \(error)") }
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        fail("\(launchPath) \(arguments.joined(separator: " ")) exited \(process.terminationStatus)")
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
let fileManager = FileManager.default

if arguments.first == "--linux" {
    guard arguments.count == 2 else {
        fail("usage: swift Scripts/make-app-icons.swift --linux <output-directory>")
    }
    // The viewer is the only mark Linux gets: there is no Linux host.
    guard let viewer = marks.first(where: { $0.name == "Sensorium" }) else {
        fail("no viewer mark to draw")
    }
    let hicolor = URL(fileURLWithPath: arguments[1]).appendingPathComponent("hicolor", isDirectory: true)
    for pixels in hicolorSizes {
        let directory = hicolor
            .appendingPathComponent("\(pixels)x\(pixels)", isDirectory: true)
            .appendingPathComponent("apps", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = directory.appendingPathComponent("com.sensorium.viewer.png")
        try? fileManager.removeItem(at: png)
        renderPNG(viewer, pixels: pixels, to: png)
        print(png.path)
    }
    exit(0)
}

guard arguments.count == 1 else {
    fail("usage: swift Scripts/make-app-icons.swift [--linux] <output-directory>")
}
let outputDirectory = URL(fileURLWithPath: arguments[0])
try? fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for mark in marks {
    let iconset = outputDirectory.appendingPathComponent("\(mark.name).iconset")
    try? fileManager.removeItem(at: iconset)
    try? fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)
    for size in iconSizes {
        renderPNG(mark, pixels: size.pixels, to: iconset.appendingPathComponent(size.name))
    }
    let icns = outputDirectory.appendingPathComponent("\(mark.name).icns")
    try? fileManager.removeItem(at: icns)
    run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", icns.path])
    for size in iconSizes {
        print(iconset.appendingPathComponent(size.name).path)
    }
    print(icns.path)
}

#!/usr/bin/env swift
// Draws the background of the window a Sensorium disk image opens in, from
// code, and writes the window layout the release script gives Finder.
//
// The picture is the app icon's mark, two overlapping screens, built out into
// two machines lit up in a dark room: the viewer's portable, with a hinge and
// a deck, and the host's desk display, on a neck and a foot. Each is a dark
// housing with a white panel set in it and is one fixed drawing, the same in
// both pictures. The portable has a camera in its top bezel, a panel edged in
// the brand's accent to pink, as the viewer icon's near screen is accent, and
// a glow in the same colours. The display has an ink panel edge, a dimmer
// accent glow and a live light in its top bezel, for the indicator the person
// at the host sees whenever someone is connected.
//
// Each disk image has its own role, and its own machine stands in front, down
// and to the right of the other: the portable for the viewer, the display for
// the host. The two pictures differ only in that order, the moat of room
// knocked out of the back machine around the front one, and where the arrow
// crosses from the app, on the back machine's panel, to Applications, on the
// front one's. The room is the apps' own dark surface: a faint dot grid, a
// soft accent glow from the top-right, a fainter pink one from the lower left
// and a trace of grain.
//
// Finder can draw icon labels in black over a background picture whatever the
// system appearance, so the panels are light and each icon and its label sit
// on a clean stretch of one. It carries no text, because Finder already labels
// both icons. The bottom strip is the bare base colour, which layout.json also
// gives Finder for anything outside the picture: a taller title bar than
// expected crops it, a shorter one extends it, and neither shows a seam.
//
// Every position here is in Finder's own window frame, points from the
// top-left of the content area, and the drawing and layout.json both derive
// from the one set of constants below, so the icons cannot drift off their
// panels.
//
// Everything is deterministic: fixed geometry, grain from a fixed-seed
// generator, no timestamps, no system fonts, no asset files. Two runs write
// identical bytes.
//
// Usage: swift Scripts/make-dmg-background.swift <viewer|host> <output-directory>
//
// Writes background.png (1x, 72 dpi), background@2x.png (2x, 144 dpi) and
// layout.json, which is the same for both roles. The two pictures are one
// drawing at two scales, and their dpi lets `tiffutil -cathidpicheck` join
// them into the one HiDPI picture Finder shows.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum Role: String {
    case viewer, host
}

/// A desk display stands on a neck and a foot; a portable sits on a hinge and
/// a deck wider than its screen.
enum Form {
    case desk, portable
}

extension Role {
    var nearForm: Form { self == .viewer ? .portable : .desk }
    var farForm: Form { self == .viewer ? .desk : .portable }
}

// MARK: - Tokens

// From docs/design-system.md.
let base = 0x0A0A0C
let ink = 0xF2EFEA
let line2 = 0x34343F
let accent = 0x7C70F5
let accentHi = 0x9088F8
let accent2 = 0xF0A8D0
let white = 0xFFFFFF

// The housings, lifted a little off the room and lit from above.
let housingTop = 0x1C1C22
let housingBottom = 0x16161B
/// The milled edge along the top of a housing.
let housingHighlightAlpha: CGFloat = 0.07
let cameraDot = 0x2C2C35

func channels(_ hex: Int) -> (red: Double, green: Double, blue: Double) {
    (Double((hex >> 16) & 0xFF), Double((hex >> 8) & 0xFF), Double(hex & 0xFF))
}

func color(_ hex: Int, alpha: CGFloat = 1) -> CGColor {
    let rgb = channels(hex)
    return CGColor(srgbRed: rgb.red / 255, green: rgb.green / 255, blue: rgb.blue / 255, alpha: alpha)
}

// MARK: - Window geometry, in Finder points from the top-left

let windowSize = CGSize(width: 760, height: 500)
let iconSize: CGFloat = 128
let textSize: CGFloat = 13
/// The bottom strip left as the bare base colour.
let bottomClear: CGFloat = 32
/// How much of a panel Finder needs around an icon centre for the icon and its
/// label: this far either side, above and below.
let iconClearSide: CGFloat = 80
let iconClearAbove: CGFloat = 64
let iconClearBelow: CGFloat = 104

// MARK: - The room

/// A radial glow, strongest at its centre and fading evenly to nothing at
/// `reach`.
struct Glow {
    let centre: CGPoint
    let reach: CGFloat
    let colour: Int
    let alpha: Double
}

let windowDiagonal = hypot(windowSize.width, windowSize.height)
let glows = [
    Glow(centre: CGPoint(x: windowSize.width, y: 0), reach: windowDiagonal * 0.68, colour: accent, alpha: 0.16),
    Glow(centre: CGPoint(x: 0, y: windowSize.height - 100), reach: windowDiagonal * 0.45, colour: accent2, alpha: 0.07),
]
/// Square dots on a grid aligned to the window's top-left corner.
let dotPitch: CGFloat = 22
let dotSize: CGFloat = 1
let dotAlpha = 0.10
/// How far each channel's grain reaches either way, in 8-bit levels. It also
/// dithers the glows, which would otherwise band.
let grainLevels = 2.0
let grainSeed: UInt64 = 0x5E45_0B1A_D15C_0A11
/// The room fades to the bare base colour over this height above the bottom
/// strip, so the strip has no edge.
let floorFade: CGFloat = 150

// MARK: - The machines

/// Each panel is 16:10, the aspect of the canvas this product streams, and
/// holds its icon and label with room to spare.
let panelSize = CGSize(width: 320, height: 200)
let panelCorner: CGFloat = 5
let bezel: CGFloat = 10
let housingCorner: CGFloat = 14
let housingSize = CGSize(width: panelSize.width + 2 * bezel, height: panelSize.height + 2 * bezel)

let neckSize = CGSize(width: 40, height: 24)
let footSize = CGSize(width: 136, height: 8)
let hingeSize = CGSize(width: 240, height: 4)
let deckOverhang: CGFloat = 22
let deckHeight: CGFloat = 12
let deckCorner: CGFloat = 5
/// The deck's thumb notch, a shallow cut in its front edge.
let notchSize = CGSize(width: 56, height: 3)
/// The taller of the two bases, which sets how much room each machine needs
/// below its housing.
let baseHeight = max(neckSize.height + footSize.height, hingeSize.height + deckHeight)

/// Where the near housing sits relative to the far one: over its corner like
/// the mark's screens, far enough that each icon and label keep their panel.
let machineOffset = CGSize(width: 300, height: 180)
/// The pair, centred across the window and down the part of it above the
/// bottom strip.
let farHousing = CGRect(
    x: (windowSize.width - housingSize.width - machineOffset.width) / 2,
    y: (windowSize.height - bottomClear - housingSize.height - machineOffset.height - baseHeight) / 2,
    width: housingSize.width, height: housingSize.height
)
let nearHousing = farHousing.offsetBy(dx: machineOffset.width, dy: machineOffset.height)
let farPanel = farHousing.insetBy(dx: bezel, dy: bezel)
let nearPanel = nearHousing.insetBy(dx: bezel, dy: bezel)

/// Each icon centred across its panel, with its icon and label centred down it.
func iconCentre(in panel: CGRect) -> CGPoint {
    CGPoint(x: panel.midX, y: panel.minY + (panel.height - iconClearAbove - iconClearBelow) / 2 + iconClearAbove)
}
let appCentre = iconCentre(in: farPanel)
let applicationsCentre = iconCentre(in: nearPanel)

/// The gap of room knocked out of the far machine around the near housing.
let machineMoat: CGFloat = 6

let panelEdgeWidth: CGFloat = 2
/// The light each machine throws into the room, strongest at its housing and
/// gone `glowReach` points out. It is painted with the room, so it fades into
/// the floor like the rest of it. The portable's runs from accent at its
/// top-left to pink at its bottom-right, like its panel's edge; the display's
/// is accent alone, and dimmer.
let glowReach: CGFloat = 60
let portableGlowAlpha = 0.3
let deskGlowAlpha = 0.17

/// The portable's camera, centred in its top bezel.
let cameraDiameter: CGFloat = 3.5
/// The display's live light, a pill centred in its top bezel.
let liveLightSize = CGSize(width: 24, height: 4.5)
let liveLightGlowBlur: CGFloat = 10
let liveLightGlowAlpha: CGFloat = 0.9

/// Each machine is drawn once into a picture of its own, with this much room
/// around its housing for its base and the live light's glow, then placed.
let machineMargin: CGFloat = 24
let machineCanvas = CGSize(
    width: housingSize.width + 2 * machineMargin,
    height: housingSize.height + baseHeight + 2 * machineMargin
)

func housing(of form: Form, role: Role) -> CGRect {
    form == role.nearForm ? nearHousing : farHousing
}

// MARK: - Arrow between the icons

let arrowLineWidth: CGFloat = 2.5
/// How far the arrow's tail stays from the app's clear space, and how far
/// across it reaches.
let arrowInset: CGFloat = 14
let arrowSpan: CGFloat = 84
let arrowHeadLength: CGFloat = 9
let arrowHeadSpread: CGFloat = 0.6
/// How far below the line between the icon centres the arrow runs, so it
/// crosses the near housing's straight edge rather than its corner.
let arrowDrop: CGFloat = 40

/// The arrow runs parallel to the line between the two icons, from just clear
/// of the app into the near panel, on the pair's own diagonal.
func arrowPoint(atX x: CGFloat) -> CGPoint {
    let progress = (x - appCentre.x) / (applicationsCentre.x - appCentre.x)
    return CGPoint(x: x, y: appCentre.y + arrowDrop + progress * (applicationsCentre.y - appCentre.y))
}
let arrowStart = arrowPoint(atX: appCentre.x + iconClearSide + arrowInset)
let arrowEnd = arrowPoint(atX: arrowStart.x + arrowSpan)

// MARK: - Drawing

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-dmg-background: \(message)\n".utf8))
    exit(1)
}

func roundedRect(_ rect: CGRect, corner: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: corner, cornerHeight: corner, transform: nil)
}

/// Offsetting a rounded rect outwards grows its radius by the same amount,
/// which keeps a band around it an even width the whole way round.
func outset(_ rect: CGRect, corner: CGFloat, by distance: CGFloat) -> CGPath {
    roundedRect(rect.insetBy(dx: -distance, dy: -distance), corner: corner + distance)
}

/// xorshift64*, enough for grain and the same sequence on every machine.
struct Grain {
    var state: UInt64

    /// A value in -1..<1.
    mutating func next() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        return Double((state &* 0x2545_F491_4F6C_DD1D) >> 11) / Double(1 << 52) - 1
    }
}

/// How far a point lies outside a housing, zero inside it.
func distanceOutside(_ housing: CGRect, x: CGFloat, y: CGFloat) -> CGFloat {
    let dx = max(abs(x - housing.midX) - (housing.width / 2 - housingCorner), 0)
    let dy = max(abs(y - housing.midY) - (housing.height / 2 - housingCorner), 0)
    return max(hypot(dx, dy) - housingCorner, 0)
}

/// Where a point falls along a housing's diagonal, from 0 at its top-left
/// corner to 1 at its bottom-right, as an axial gradient between those
/// corners measures it.
func progressAlong(_ housing: CGRect, x: CGFloat, y: CGFloat) -> Double {
    let w = housing.width, h = housing.height
    let along = ((x - housing.minX) * w + (y - housing.minY) * h) / (w * w + h * h)
    return Double(min(max(along, 0), 1))
}

/// Paints the room pixel by pixel straight into the bitmap, before any of the
/// stage is drawn over it.
func paintRoom(into context: CGContext, role: Role, scale: CGFloat) {
    guard let data = context.data else { fail("the bitmap has no pixel buffer") }
    let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
    let floor = windowSize.height - bottomClear
    let room = channels(base)
    var grain = Grain(state: grainSeed)
    // The back machine's light first, so the front one's lies over it.
    let lit = [role.farForm, role.nearForm].map { ($0, housing(of: $0, role: role)) }
    // Row 0 of the buffer is the top of the picture.
    for row in 0..<context.height {
        let y = (CGFloat(row) + 0.5) / scale
        let fadeIn = min(max((floor - y) / floorFade, 0), 1)
        let strength = Double(fadeIn * fadeIn * (3 - 2 * fadeIn))
        let onDotRow = (y - dotPitch / 2).truncatingRemainder(dividingBy: dotPitch) < dotSize && y > dotPitch / 2
        for column in 0..<context.width {
            let x = (CGFloat(column) + 0.5) / scale
            var red = room.red, green = room.green, blue = room.blue
            for glow in glows {
                let distance = hypot(x - glow.centre.x, y - glow.centre.y) / glow.reach
                guard distance < 1 else { continue }
                let amount = glow.alpha * Double(1 - distance) * strength
                let tint = channels(glow.colour)
                red += (tint.red - red) * amount
                green += (tint.green - green) * amount
                blue += (tint.blue - blue) * amount
            }
            for (form, housing) in lit {
                let outside = distanceOutside(housing, x: x, y: y) / glowReach
                guard outside < 1 else { continue }
                let falloff = Double((1 - outside) * (1 - outside))
                let tint: (red: Double, green: Double, blue: Double)
                let amount: Double
                switch form {
                case .portable:
                    let from = channels(accent), to = channels(accent2)
                    let along = progressAlong(housing, x: x, y: y)
                    tint = (
                        from.red + (to.red - from.red) * along,
                        from.green + (to.green - from.green) * along,
                        from.blue + (to.blue - from.blue) * along
                    )
                    amount = portableGlowAlpha * falloff * strength
                case .desk:
                    tint = channels(accent)
                    amount = deskGlowAlpha * falloff * strength
                }
                red += (tint.red - red) * amount
                green += (tint.green - green) * amount
                blue += (tint.blue - blue) * amount
            }
            if onDotRow && x > dotPitch / 2
                && (x - dotPitch / 2).truncatingRemainder(dividingBy: dotPitch) < dotSize {
                let amount = dotAlpha * strength
                red += (255 - red) * amount
                green += (255 - green) * amount
                blue += (255 - blue) * amount
            }
            let speck = grain.next() * grainLevels * strength
            let pixel = row * context.bytesPerRow + column * 4
            bytes[pixel] = UInt8(min(max((red + speck).rounded(), 0), 255))
            bytes[pixel + 1] = UInt8(min(max((green + speck).rounded(), 0), 255))
            bytes[pixel + 2] = UInt8(min(max((blue + speck).rounded(), 0), 255))
            bytes[pixel + 3] = 255
        }
    }
}

func linearGradient(_ from: Int, _ to: Int) -> CGGradient {
    guard
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [color(from), color(to)] as CFArray,
            locations: [0, 1]
        )
    else { fail("could not build a gradient") }
    return gradient
}

/// A housing's metal: a fill lit from above, a hairline edge and a milled
/// highlight just inside its top.
func drawMetal(_ path: CGPath, in rect: CGRect, into context: CGContext) {
    context.saveGState()
    context.addPath(path)
    context.clip()
    context.drawLinearGradient(
        linearGradient(housingTop, housingBottom),
        start: CGPoint(x: rect.midX, y: rect.minY),
        end: CGPoint(x: rect.midX, y: rect.maxY),
        options: []
    )
    var down = CGAffineTransform(translationX: 0, y: 1)
    if let lowered = path.copy(using: &down) {
        context.addPath(path)
        context.addPath(lowered)
        context.setFillColor(color(white, alpha: housingHighlightAlpha))
        context.fillPath(using: .evenOdd)
    }
    context.restoreGState()
    context.addPath(path)
    context.setStrokeColor(color(line2))
    context.setLineWidth(1)
    context.strokePath()
}

/// The parts of a machine below its housing, each with its own outline.
func baseParts(of housing: CGRect, form: Form) -> [(path: CGPath, rect: CGRect)] {
    switch form {
    case .desk:
        let neck = CGRect(
            x: housing.midX - neckSize.width / 2, y: housing.maxY,
            width: neckSize.width, height: neckSize.height
        )
        let foot = CGRect(
            x: housing.midX - footSize.width / 2, y: neck.maxY,
            width: footSize.width, height: footSize.height
        )
        return [
            (CGPath(rect: neck, transform: nil), neck),
            (roundedRect(foot, corner: footSize.height / 2), foot),
        ]
    case .portable:
        let hinge = CGRect(
            x: housing.midX - hingeSize.width / 2, y: housing.maxY,
            width: hingeSize.width, height: hingeSize.height
        )
        let deck = CGRect(
            x: housing.minX - deckOverhang, y: hinge.maxY,
            width: housing.width + 2 * deckOverhang, height: deckHeight
        )
        return [
            (CGPath(rect: hinge, transform: nil), hinge),
            (roundedRect(deck, corner: deckCorner), deck),
        ]
    }
}

/// Draws one machine into a picture of its own, its housing `machineMargin`
/// in from the top-left, so the same pixels land wherever it is placed.
func machinePicture(_ form: Form, scale: CGFloat) -> CGImage {
    let width = Int(machineCanvas.width * scale)
    let height = Int(machineCanvas.height * scale)
    guard
        let context = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    else { fail("could not create a \(width)x\(height) bitmap context") }
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    context.translateBy(x: 0, y: machineCanvas.height * scale)
    context.scaleBy(x: scale, y: -scale)

    let housing = CGRect(origin: CGPoint(x: machineMargin, y: machineMargin), size: housingSize)
    let panel = housing.insetBy(dx: bezel, dy: bezel)
    let parts = baseParts(of: housing, form: form)
    for part in parts {
        drawMetal(part.path, in: part.rect, into: context)
    }
    if form == .portable, let deck = parts.last?.rect {
        let notch = CGRect(
            x: deck.midX - notchSize.width / 2, y: deck.maxY - notchSize.height,
            width: notchSize.width, height: notchSize.height
        )
        context.addPath(roundedRect(notch, corner: notchSize.height / 2))
        context.setFillColor(color(base))
        context.fillPath()
    }
    drawMetal(roundedRect(housing, corner: housingCorner), in: housing, into: context)

    let screen = roundedRect(panel, corner: panelCorner)
    context.addPath(screen)
    context.setFillColor(color(white))
    context.fillPath()

    // The panel's edge is painted through the outline's own shape.
    context.saveGState()
    context.addPath(screen)
    context.setLineWidth(panelEdgeWidth)
    context.replacePathWithStrokedPath()
    context.clip()
    switch form {
    case .portable:
        // Accent at the top-left corner to pink at the bottom-right.
        context.drawLinearGradient(
            linearGradient(accent, accent2),
            start: CGPoint(x: panel.minX, y: panel.minY),
            end: CGPoint(x: panel.maxX, y: panel.maxY),
            options: []
        )
    case .desk:
        context.setFillColor(color(ink))
        context.fill(panel.insetBy(dx: -panelEdgeWidth, dy: -panelEdgeWidth))
    }
    context.restoreGState()

    let bezelMiddle = CGPoint(x: housing.midX, y: housing.minY + bezel / 2)
    switch form {
    case .portable:
        context.addEllipse(in: CGRect(
            x: bezelMiddle.x - cameraDiameter / 2, y: bezelMiddle.y - cameraDiameter / 2,
            width: cameraDiameter, height: cameraDiameter
        ))
        context.setFillColor(color(cameraDot))
        context.fillPath()
    case .desk:
        let pill = CGRect(
            x: bezelMiddle.x - liveLightSize.width / 2, y: bezelMiddle.y - liveLightSize.height / 2,
            width: liveLightSize.width, height: liveLightSize.height
        )
        // Shadow geometry is in device pixels and ignores the current
        // transform, so it is scaled by hand.
        context.saveGState()
        context.setShadow(offset: .zero, blur: liveLightGlowBlur * scale, color: color(accent, alpha: liveLightGlowAlpha))
        context.addPath(roundedRect(pill, corner: liveLightSize.height / 2))
        context.setFillColor(color(accent))
        context.fillPath()
        context.restoreGState()
    }
    guard let picture = context.makeImage() else { fail("could not snapshot a machine") }
    return picture
}

/// Places a machine's picture with its housing at `housing`, pixel for pixel.
func place(_ picture: CGImage, housing: CGRect, into context: CGContext) {
    let frame = CGRect(
        x: housing.minX - machineMargin, y: housing.minY - machineMargin,
        width: machineCanvas.width, height: machineCanvas.height
    )
    context.saveGState()
    context.interpolationQuality = .none
    // The window's frame is flipped, and a picture drawn into it would land
    // upside down, so it is flipped back around the frame.
    context.translateBy(x: frame.minX, y: frame.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(picture, in: CGRect(origin: .zero, size: frame.size))
    context.restoreGState()
}

func drawArrow(into context: CGContext) {
    let heading = atan2(arrowEnd.y - arrowStart.y, arrowEnd.x - arrowStart.x)
    let path = CGMutablePath()
    path.move(to: arrowStart)
    path.addLine(to: arrowEnd)
    for side in [-arrowHeadSpread, arrowHeadSpread] {
        path.move(to: CGPoint(
            x: arrowEnd.x - arrowHeadLength * cos(heading + side),
            y: arrowEnd.y - arrowHeadLength * sin(heading + side)
        ))
        path.addLine(to: arrowEnd)
    }
    context.saveGState()
    context.addPath(path)
    context.setStrokeColor(color(accent))
    context.setLineWidth(arrowLineWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.strokePath()
    context.restoreGState()
}

func draw(into context: CGContext, role: Role, scale: CGFloat) {
    paintRoom(into: context, role: role, scale: scale)
    context.setShouldAntialias(true)
    context.setAllowsAntialiasing(true)
    // Flip once into Finder's frame: points, origin top-left, y down.
    context.translateBy(x: 0, y: windowSize.height * scale)
    context.scaleBy(x: scale, y: -scale)

    context.saveGState()
    context.addRect(CGRect(origin: .zero, size: windowSize))
    context.addPath(outset(nearHousing, corner: housingCorner, by: machineMoat))
    context.clip(using: .evenOdd)
    place(machinePicture(role.farForm, scale: scale), housing: farHousing, into: context)
    context.restoreGState()
    place(machinePicture(role.nearForm, scale: scale), housing: nearHousing, into: context)
    drawArrow(into: context)
}

// MARK: - Emit

func renderPNG(role: Role, scale: Int, to url: URL) {
    let width = Int(windowSize.width) * scale
    let height = Int(windowSize.height) * scale
    guard
        let context = CGContext(
            data: nil,
            width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
    else { fail("could not create a \(width)x\(height) bitmap context") }
    draw(into: context, role: role, scale: CGFloat(scale))
    guard let image = context.makeImage() else { fail("could not snapshot \(url.lastPathComponent)") }
    guard
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        )
    else { fail("could not open \(url.path) for writing") }
    // Finder and tiffutil read a picture's size in points from its dpi, which
    // is how the 2x picture comes out the same size as the 1x one.
    let dpi = 72 * scale
    let properties = [
        kCGImagePropertyDPIWidth: dpi,
        kCGImagePropertyDPIHeight: dpi,
    ] as CFDictionary
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else { fail("could not write \(url.path)") }
}

/// Written by hand, in a fixed key order, so the bytes never depend on how a
/// JSON encoder formats numbers.
func layoutJSON() -> String {
    let room = channels(base)
    let fields: [(String, String)] = [
        ("windowWidth", "\(Int(windowSize.width))"),
        ("windowHeight", "\(Int(windowSize.height))"),
        ("iconSize", "\(Int(iconSize))"),
        ("textSize", "\(Int(textSize))"),
        ("appX", "\(Int(appCentre.x))"),
        ("appY", "\(Int(appCentre.y))"),
        ("applicationsX", "\(Int(applicationsCentre.x))"),
        ("applicationsY", "\(Int(applicationsCentre.y))"),
        ("backgroundRed", String(format: "%.6f", room.red / 255)),
        ("backgroundGreen", String(format: "%.6f", room.green / 255)),
        ("backgroundBlue", String(format: "%.6f", room.blue / 255)),
    ]
    let lines = fields.map { "  \"\($0.0)\": \($0.1)" }
    return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
}

let usage = "usage: swift Scripts/make-dmg-background.swift <viewer|host> <output-directory>"
let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else { fail(usage) }
guard let role = Role(rawValue: arguments[0]) else {
    fail("unknown role \"\(arguments[0])\"; \(usage)")
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    fail("could not create \(outputDirectory.path): \(error)")
}

for (name, scale) in [("background.png", 1), ("background@2x.png", 2)] {
    let url = outputDirectory.appendingPathComponent(name)
    renderPNG(role: role, scale: scale, to: url)
    print(url.path)
}
let layout = outputDirectory.appendingPathComponent("layout.json")
do {
    try layoutJSON().write(to: layout, atomically: true, encoding: .utf8)
} catch {
    fail("could not write \(layout.path): \(error)")
}
print(layout.path)

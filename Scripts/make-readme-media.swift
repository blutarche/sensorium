//
// Builds the README media from the apps' own offscreen renders.
//
//   swift Scripts/make-readme-media.swift <previews-directory> [output-directory]
//
// <previews-directory> is the output of `swift Scripts/render-ui-previews.swift`.
// The output directory defaults to `docs/media` in this repository and receives
//
//   pairing.gif          the pairing walkthrough, 1280x720, looping
//   pairing-still.png    the walkthrough's end card as one picture, for readers who prefer no motion
//   at-the-host.png      what the person at the host sees, in three panels
//   social-preview.png   the repository's 1280x640 social image
//
// Nothing in a picture is drawn by this script except the frames around the
// renders, the chips, captions and labels, and the host screen's backdrop and
// the editor and terminal staged on it, whose text is invented. Every app
// window, badge and prompt is a render. In pairing.gif each beat shows one
// window at 1.5x, cropped to end between controls, or the host screen: that
// backdrop carrying the staged editor and terminal and a render of the
// presence badge. A pointer clicks the controls, a click that changes a window
// cuts its content and resizes its frame, and beats hand over with eased fades
// and moves. The walkthrough ends on the session window with the app's icon and
// name above it, then fades back into its first picture so it loops without a
// seam.
//
// Only the renders named in `allowedRenders` are ever opened, and the
// directory is never listed. Renders of the launcher and workspace windows
// show the applications installed on whichever machine ran the renderer, so
// they are not inputs here and must not become inputs.
//
// Needs the Swift toolchain from the Command Line Tools and nothing else.

import CoreGraphics
import CoreText
import Foundation
import ImageIO

// MARK: - Inputs

/// Every render this script reads, by file name without extension.
let allowedRenders: [String] = [
    "viewer-machines-1-empty",
    "host-window-3-ready-no-machines-paired",
    "host-window-4-pairing-code-shown",
    "viewer-add-1-picker",
    "viewer-add-2-code",
    "viewer-add-2b-code-typed-1",
    "viewer-add-2b-code-typed-2",
    "viewer-add-2b-code-typed-3",
    "viewer-add-2b-code-typed-4",
    "viewer-add-2b-code-typed-5",
    "viewer-add-2b-code-typed-6",
    "viewer-shortcuts-1b-pinned",
    "host-screen-badge-1-expanded",
    "host-screen-presence-prompt-1-short",
    "host-window-12-last-session-clean-stop"
]

/// The viewer's icon, read from the repository rather than the previews.
let appIconPath = "Packaging/linux/icons/hicolor/256x256/apps/com.sensorium.viewer.png"

let repositoryRoot = URL(fileURLWithPath: #filePath)
    .standardizedFileURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()

func die(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-readme-media: \(message)\n".utf8))
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard (1...2).contains(arguments.count) else {
    die("usage: swift Scripts/make-readme-media.swift <previews-directory> [output-directory]")
}
let previewsDirectory = URL(fileURLWithPath: arguments[0], isDirectory: true)
let outputDirectory = arguments.count > 1
    ? URL(fileURLWithPath: arguments[1], isDirectory: true)
    : repositoryRoot.appendingPathComponent("docs/media", isDirectory: true)

// MARK: - Palette and metrics (docs/design-system.md)

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255,
            CGFloat((hex >> 8) & 0xFF) / 255,
            CGFloat(hex & 0xFF) / 255,
            1
        ]
    )!
}

let chromeBackground = color(0x07070A)
let panelFill = color(0x0E0E14)
let panelBorder = color(0x18181E)
let windowLine = color(0x34343F)
let accent = color(0x7C70F5)
let hostScreenFill = color(0x16142A)
let mutedText = color(0x8A8A92)
let wordmarkColor = color(0xF2EFEA)

let cornerRadius: CGFloat = 12
let borderWidth: CGFloat = 2
let tallImageLimit = 880
let fadeHeight = 120
let labelSize: CGFloat = 24

// MARK: - Loading

func loadImage(at url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { die("cannot read \(url.lastPathComponent) as a picture") }
    return image
}

let missingRenders = allowedRenders.filter {
    !FileManager.default.fileExists(atPath: previewsDirectory.appendingPathComponent($0 + ".png").path)
}
guard missingRenders.isEmpty else {
    die("missing renders in \(previewsDirectory.path): " + missingRenders.map { $0 + ".png" }.joined(separator: ", "))
}
let iconURL = repositoryRoot.appendingPathComponent(appIconPath)
guard FileManager.default.fileExists(atPath: iconURL.path) else { die("missing \(appIconPath)") }

let renders: [String: CGImage] = Dictionary(
    uniqueKeysWithValues: allowedRenders.map {
        ($0, loadImage(at: previewsDirectory.appendingPathComponent($0 + ".png")))
    }
)
let appIcon = loadImage(at: iconURL)

func render(_ name: String) -> CGImage {
    guard let image = renders[name] else { die("\(name) is not an allowed render") }
    return image
}

func crop(_ image: CGImage, _ rect: CGRect, _ what: String) -> CGImage {
    guard let cropped = image.cropping(to: rect) else {
        die("\(what) is \(image.width)x\(image.height), too small for the crop it needs")
    }
    return cropped
}

// MARK: - Drawing

/// A bitmap that is addressed from its top-left corner, as the layout is
/// written.
struct Canvas {
    let context: CGContext
    let width: Int
    let height: Int

    /// `width` and `height` are in drawing units; the bitmap is `scale` times that.
    init(width: Int, height: Int, background: CGColor, scale: CGFloat = 1) {
        let pixelWidth = Int((CGFloat(width) * scale).rounded())
        let pixelHeight = Int((CGFloat(height) * scale).rounded())
        guard let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { die("cannot allocate a \(pixelWidth)x\(pixelHeight) bitmap") }
        context.interpolationQuality = .high
        if scale != 1 { context.scaleBy(x: scale, y: scale) }
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        self.context = context
        self.width = width
        self.height = height
    }

    func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x, y: CGFloat(height) - y - h, width: w, height: h)
    }

    func image() -> CGImage {
        guard let image = context.makeImage() else { die("cannot read back a bitmap") }
        return image
    }
}

func roundedPath(_ rect: CGRect, inset: CGFloat = 0) -> CGPath {
    let inner = rect.insetBy(dx: inset, dy: inset)
    let radius = cornerRadius - inset
    return CGPath(roundedRect: inner, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawPanel(_ canvas: Canvas, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
    let rect = canvas.rect(x, y, width, height)
    canvas.context.addPath(roundedPath(rect))
    canvas.context.setFillColor(panelFill)
    canvas.context.fillPath()
    canvas.context.addPath(roundedPath(rect, inset: borderWidth / 2))
    canvas.context.setStrokeColor(panelBorder)
    canvas.context.setLineWidth(borderWidth)
    canvas.context.strokePath()
}

/// A render ready to be framed: tall ones are cut from the top and fade into
/// the panel colour where the cut is.
struct Placement {
    let image: CGImage
    let fadesAtBottom: Bool

    init(_ source: CGImage, cropsTall: Bool = true) {
        if cropsTall, source.height > tallImageLimit {
            image = crop(source, CGRect(x: 0, y: 0, width: source.width, height: tallImageLimit), "a tall render")
            fadesAtBottom = true
        } else {
            image = source
            fadesAtBottom = false
        }
    }
}

func drawFramed(_ canvas: Canvas, _ placement: Placement, in box: CGRect) {
    let context = canvas.context
    let rect = canvas.rect(box.minX, box.minY, box.width, box.height)
    context.saveGState()
    context.addPath(roundedPath(rect))
    context.clip()
    context.draw(placement.image, in: rect)
    if placement.fadesAtBottom {
        let band = CGFloat(fadeHeight) * box.height / CGFloat(placement.image.height)
        let clear = CGColor(colorSpace: colorSpace, components: [14 / 255, 14 / 255, 20 / 255, 0])!
        guard let gradient = CGGradient(
            colorsSpace: colorSpace, colors: [clear, panelFill] as CFArray, locations: [0, 1]
        ) else { die("cannot build the crop fade") }
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: 0, y: rect.minY + band),
            end: CGPoint(x: 0, y: rect.minY),
            options: []
        )
    }
    context.restoreGState()
    context.addPath(roundedPath(rect, inset: borderWidth / 2))
    context.setStrokeColor(windowLine)
    context.setLineWidth(borderWidth)
    context.strokePath()
}

func drawUnframed(_ canvas: Canvas, _ image: CGImage, x: CGFloat, y: CGFloat, size: CGSize) {
    canvas.context.draw(image, in: canvas.rect(x, y, size.width, size.height))
}

// MARK: - Type

func font(trying names: [String], familyPrefix: String, size: CGFloat) -> CTFont? {
    for name in names {
        let candidate = CTFontCreateWithName(name as CFString, size, nil)
        // CoreText substitutes a default face for a name it does not know.
        if (CTFontCopyFamilyName(candidate) as String).hasPrefix(familyPrefix) { return candidate }
    }
    return nil
}

func monoFont(size: CGFloat) -> CTFont {
    font(trying: ["JetBrainsMono-Regular", "JetBrains Mono"], familyPrefix: "JetBrains Mono", size: size)
        ?? CTFontCreateUIFontForLanguage(.userFixedPitch, size, nil)!
}

func labelFont() -> CTFont { monoFont(size: labelSize) }

func wordmarkFont(size: CGFloat) -> CTFont {
    if let face = font(
        trying: ["SpaceGrotesk-SemiBold", "Space Grotesk SemiBold", "Space Grotesk"],
        familyPrefix: "Space Grotesk", size: size
    ) { return face }
    let system = CTFontCreateUIFontForLanguage(.system, size, nil)!
    let weight: [CFString: Any] = [kCTFontTraitsAttribute: [kCTFontWeightTrait: 0.3]]
    let descriptor = CTFontDescriptorCreateCopyWithAttributes(
        CTFontCopyFontDescriptor(system), weight as CFDictionary
    )
    return CTFontCreateWithFontDescriptor(descriptor, size, nil)
}

func taglineFont(size: CGFloat) -> CTFont {
    font(trying: ["Inter-Regular", "Inter"], familyPrefix: "Inter", size: size)
        ?? CTFontCreateUIFontForLanguage(.system, size, nil)!
}

func line(_ text: String, font: CTFont, color: CGColor, kern: CGFloat) -> CTLine {
    let attributes: [CFString: Any] = [
        kCTFontAttributeName: font,
        kCTForegroundColorAttributeName: color,
        kCTKernAttributeName: kern
    ]
    let string = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary)!
    return CTLineCreateWithAttributedString(string)
}

@discardableResult
func drawText(_ canvas: Canvas, _ text: CTLine, x: CGFloat, baseline: CGFloat) -> CGFloat {
    canvas.context.textMatrix = .identity
    canvas.context.textPosition = CGPoint(x: x, y: CGFloat(canvas.height) - baseline)
    CTLineDraw(text, canvas.context)
    return CGFloat(CTLineGetTypographicBounds(text, nil, nil, nil))
}

func drawLabel(_ canvas: Canvas, _ text: String, x: CGFloat, baseline: CGFloat) {
    drawText(
        canvas,
        line(text.uppercased(), font: labelFont(), color: mutedText, kern: 0.22 * labelSize),
        x: x, baseline: baseline
    )
}

// MARK: - Scene

let sceneWidth = 2048
let sceneHeight = 1152
let panelTop: CGFloat = 104
let panelPadding: CGFloat = 24

let chipTop: CGFloat = 48
let chipHeight: CGFloat = 60
let chipGap: CGFloat = 24
let chipPadding: CGFloat = 24
let captionBaseline: CGFloat = 212
let captionSize: CGFloat = 52
let stage = CGRect(x: 48, y: 280, width: 1952, height: 824)
let windowScale: CGFloat = 1.5
let labelBaseline: CGFloat = 1080

let captions = [
    "In Sensorium Host, click Show Pairing Code.",
    "Sensorium Host shows a six-digit code.",
    "In Sensorium, click Add a Machine and pick the host.",
    "Type the code from the host: 418 297",
    "You now see and control the host's screen.",
    "The host shows who is connected, with a Stop button."
]

func textWidth(_ text: CTLine) -> CGFloat {
    CGFloat(CTLineGetTypographicBounds(text, nil, nil, nil))
}

func mix(_ from: CGColor, _ to: CGColor, _ amount: Double) -> CGColor {
    if amount <= 0 { return from }
    if amount >= 1 { return to }
    guard let a = from.components, let b = to.components, a.count == b.count else { die("cannot mix two colours") }
    let blended = zip(a, b).map { $0 + ($1 - $0) * CGFloat(amount) }
    return CGColor(colorSpace: colorSpace, components: blended)!
}

let chipFont = labelFont()
let chipTexts = ["Sensorium · The machine you sit at", "Sensorium Host · The machine you reach"]

/// The two chips naming the machines, always left then right. A chip's amount is
/// how lit it is: 1 carries the accent border, 0 recedes.
func drawChips(_ canvas: Canvas, left: Double, right: Double) {
    let kern = 0.22 * labelSize
    let amounts = [left, right]
    let lines = zip(chipTexts, amounts).map {
        line($0.uppercased(), font: chipFont, color: mix(mutedText, wordmarkColor, $1), kern: kern)
    }
    // The last letter's trailing kern is not part of what is seen.
    let widths = lines.map { textWidth($0) - kern + 2 * chipPadding }
    var x = ((CGFloat(sceneWidth) - widths.reduce(0, +) - chipGap) / 2).rounded(.down)
    for index in lines.indices {
        let rect = canvas.rect(x, chipTop, widths[index], chipHeight)
        if amounts[index] > 0 {
            canvas.context.addPath(roundedPath(rect))
            canvas.context.setFillColor(panelFill.copy(alpha: CGFloat(min(1, amounts[index])))!)
            canvas.context.fillPath()
        }
        canvas.context.addPath(roundedPath(rect, inset: borderWidth / 2))
        canvas.context.setStrokeColor(mix(panelBorder, accent, amounts[index]))
        canvas.context.setLineWidth(borderWidth)
        canvas.context.strokePath()
        drawText(canvas, lines[index], x: x + chipPadding, baseline: chipTop + chipHeight / 2 + CTFontGetCapHeight(chipFont) / 2)
        x += widths[index] + chipGap
    }
}

let captionLines: [CTLine] = captions.map { text in
    let caption = line(text, font: taglineFont(size: captionSize), color: wordmarkColor, kern: 0)
    if textWidth(caption) > stage.width {
        die("the caption \"\(text)\" is \(Int(textWidth(caption))) px wide, over the \(Int(stage.width)) px it may use")
    }
    return caption
}

func drawCaption(_ canvas: Canvas, _ index: Int) {
    let caption = captionLines[index]
    drawText(canvas, caption, x: ((CGFloat(sceneWidth) - textWidth(caption)) / 2).rounded(.down), baseline: captionBaseline)
}

// MARK: - Inputs to the scene

let machinesEmpty = render("viewer-machines-1-empty")
let pinnedStrip = crop(render("viewer-shortcuts-1b-pinned"), CGRect(x: 0, y: 0, width: 1920, height: 90), "the pinned shortcut strip")
let badgeExpanded = render("host-screen-badge-1-expanded")

/// Each crop ends in the empty space between two controls.
func windowCrop(_ name: String, height: Int) -> CGImage {
    let source = render(name)
    return crop(source, CGRect(x: 0, y: 0, width: source.width, height: height), name)
}

let hostReady = windowCrop("host-window-3-ready-no-machines-paired", height: 322)
let hostCode = windowCrop("host-window-4-pairing-code-shown", height: 484)
let viewerPicker = windowCrop("viewer-add-1-picker", height: 484)
let viewerCode = windowCrop("viewer-add-2-code", height: 548)
let viewerTyped = (1...6).map { windowCrop("viewer-add-2b-code-typed-\($0)", height: 548) }

/// Where a window of this render size rests: at 1.5x, centred in the stage.
func restRect(_ image: CGImage) -> CGRect {
    let width = CGFloat(image.width) * windowScale
    let height = CGFloat(image.height) * windowScale
    guard width <= stage.width, height <= stage.height else {
        die("a window of \(Int(width))x\(Int(height)) does not fit the \(Int(stage.width))x\(Int(stage.height)) stage")
    }
    return CGRect(
        x: stage.minX + ((stage.width - width) / 2).rounded(.down),
        y: stage.minY + ((stage.height - height) / 2).rounded(.down),
        width: width,
        height: height
    )
}

/// A window with its content cropped to the top of `box`, framed.
func drawWindow(_ canvas: Canvas, _ image: CGImage, in box: CGRect) {
    let context = canvas.context
    let rect = canvas.rect(box.minX, box.minY, box.width, box.height)
    context.saveGState()
    context.addPath(roundedPath(rect))
    context.clip()
    context.draw(
        image,
        in: canvas.rect(
            box.minX, box.minY, CGFloat(image.width) * windowScale, CGFloat(image.height) * windowScale
        )
    )
    context.restoreGState()
    context.addPath(roundedPath(rect, inset: borderWidth / 2))
    context.setStrokeColor(windowLine)
    context.setLineWidth(borderWidth)
    context.strokePath()
}

// MARK: - The host's screen

/// What the terminal on the host's screen shows: how many characters of the
/// command are typed, and how many of its output lines have appeared.
struct TerminalState: Hashable {
    let typed: Int
    let output: Int
}

let terminalPrompt = "~/code/tide $ "
let terminalCommand = "swift test"
let terminalOutput = ["Building for debugging...", "Build complete! (1.84s)", "Executed 12 tests, with 0 failures"]

let terminalStates: [TerminalState] =
    [TerminalState(typed: 0, output: 0)]
    + (1...terminalCommand.count).map { TerminalState(typed: $0, output: 0) }
    + (1...terminalOutput.count).map { TerminalState(typed: terminalCommand.count, output: $0) }

let editorTitle = "Forecast.swift · tide"
let editorLines = [
    "import Foundation",
    "",
    "struct Forecast {",
    "    let hour: Int",
    "    let swellMetres: Double",
    "    let windKnots: Double",
    "",
    "    var isSurfable: Bool {",
    "        swellMetres >= 0.8 && windKnots < 15",
    "    }",
    "}",
    "",
    "func bestHour(in day: [Forecast]) -> Forecast? {",
    "    day.filter(\\.isSurfable)",
    "        .max { $0.swellMetres < $1.swellMetres }",
    "}"
]
let editorKeywords: Set<String> = ["import", "struct", "let", "var", "func", "in"]

/// The host's display is staged at twice the size of the pictures' windows, so
/// a camera can move into it and stay sharp.
let hostScreenSize = CGSize(width: 2636, height: 1648)
let hostScreenBounds = CGRect(origin: .zero, size: hostScreenSize)
let stagedFontSize: CGFloat = 30
let stagedLineHeight: CGFloat = 46
let stagedTitleBar: CGFloat = 64
let stagedPadding: CGFloat = 28
let stagedFont = monoFont(size: stagedFontSize)
let stagedAdvance = textWidth(line("M", font: stagedFont, color: wordmarkColor, kern: 0))

func fractionRect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
    CGRect(
        x: (x * hostScreenSize.width).rounded(), y: (y * hostScreenSize.height).rounded(),
        width: (w * hostScreenSize.width).rounded(), height: (h * hostScreenSize.height).rounded()
    )
}

let editorRect = fractionRect(0.04, 0.06, 0.58, 0.72)
let terminalRect = fractionRect(0.44, 0.42, 0.48, 0.40)

/// A flat window, drawn at the host screen's 2x: title bar, rule, body.
func drawStagedWindow(_ canvas: Canvas, _ box: CGRect, title: String) {
    let context = canvas.context
    let radius = cornerRadius * 2
    let rect = canvas.rect(box.minX, box.minY, box.width, box.height)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(panelFill)
    context.fillPath()
    context.setFillColor(windowLine)
    context.fill(canvas.rect(box.minX, box.minY + stagedTitleBar, box.width, borderWidth))
    context.addPath(CGPath(
        roundedRect: rect.insetBy(dx: borderWidth / 2, dy: borderWidth / 2),
        cornerWidth: radius - borderWidth / 2, cornerHeight: radius - borderWidth / 2, transform: nil
    ))
    context.setStrokeColor(windowLine)
    context.setLineWidth(borderWidth)
    context.strokePath()
    let heading = line(title, font: taglineFont(size: 30), color: mutedText, kern: 0)
    drawText(
        canvas, heading, x: box.midX - textWidth(heading) / 2,
        baseline: box.minY + stagedTitleBar / 2 + CTFontGetCapHeight(taglineFont(size: 30)) / 2
    )
}

func stagedBaseline(_ box: CGRect, row: Int) -> CGFloat {
    box.minY + stagedTitleBar + borderWidth + stagedPadding + CGFloat(row) * stagedLineHeight
        + (stagedLineHeight + CTFontGetCapHeight(stagedFont)) / 2
}

func drawStagedText(_ canvas: Canvas, _ text: String, color: CGColor, x: CGFloat, baseline: CGFloat) {
    drawText(canvas, line(text, font: stagedFont, color: color, kern: 0), x: x, baseline: baseline)
}

/// Splits a source line into runs of one colour: keywords in the accent,
/// everything else in the text colour.
func syntaxRuns(_ text: String) -> [(text: String, column: Int, color: CGColor)] {
    var runs: [(text: String, column: Int, color: CGColor)] = []
    var word = ""
    var other = ""
    var column = 0
    func flush() {
        if !other.isEmpty {
            runs.append((other, column - other.count, wordmarkColor))
            other = ""
        }
        if !word.isEmpty {
            runs.append((word, column - word.count, editorKeywords.contains(word) ? accent : wordmarkColor))
            word = ""
        }
    }
    for character in text {
        if character.isLetter || character.isNumber || character == "_" {
            if !other.isEmpty { flush() }
            word.append(character)
        } else {
            if !word.isEmpty { flush() }
            other.append(character)
        }
        column += 1
    }
    flush()
    return runs
}

func drawEditor(_ canvas: Canvas) {
    drawStagedWindow(canvas, editorRect, title: editorTitle)
    let digits = String(editorLines.count).count
    let codeX = editorRect.minX + stagedPadding + CGFloat(digits + 2) * stagedAdvance
    for (row, source) in editorLines.enumerated() {
        let baseline = stagedBaseline(editorRect, row: row)
        let number = String(row + 1)
        let numberX = editorRect.minX + stagedPadding + CGFloat(digits - number.count) * stagedAdvance
        drawStagedText(canvas, number, color: mutedText, x: numberX, baseline: baseline)
        for run in syntaxRuns(source) {
            drawStagedText(canvas, run.text, color: run.color, x: codeX + CGFloat(run.column) * stagedAdvance, baseline: baseline)
        }
    }
}

func drawTerminal(_ canvas: Canvas, _ state: TerminalState) {
    drawStagedWindow(canvas, terminalRect, title: "tide · zsh")
    let left = terminalRect.minX + stagedPadding
    var rows: [(prompt: Bool, text: String)] = [
        (true, "git status --short"),
        (false, " M Sources/Tide/Forecast.swift"),
        (true, String(terminalCommand.prefix(state.typed)))
    ]
    rows += terminalOutput.prefix(state.output).map { (false, $0) }
    let finished = state.output == terminalOutput.count
    if finished { rows.append((true, "")) }
    for (row, item) in rows.enumerated() {
        let baseline = stagedBaseline(terminalRect, row: row)
        var x = left
        if item.prompt {
            drawStagedText(canvas, terminalPrompt, color: mutedText, x: x, baseline: baseline)
            x += CGFloat(terminalPrompt.count) * stagedAdvance
        }
        drawStagedText(canvas, item.text, color: wordmarkColor, x: x, baseline: baseline)
        let isLast = row == rows.count - 1
        if isLast, item.prompt {
            x += CGFloat(item.text.count) * stagedAdvance
            let ascent = CTFontGetAscent(stagedFont)
            let descent = CTFontGetDescent(stagedFont)
            canvas.context.setFillColor(wordmarkColor.copy(alpha: 0.8)!)
            canvas.context.fill(canvas.rect(x, baseline - ascent, stagedAdvance, ascent + descent))
        }
    }
}

let badgeWidth = (0.26 * hostScreenSize.width).rounded()
let badgeHeight = (badgeWidth * CGFloat(badgeExpanded.height) / CGFloat(badgeExpanded.width)).rounded()
let badgeInset = (0.03 * hostScreenSize.width).rounded()
let badgeBox = CGRect(
    x: hostScreenSize.width - badgeInset - badgeWidth, y: hostScreenSize.height - badgeInset - badgeHeight,
    width: badgeWidth, height: badgeHeight
)

/// One picture of the whole host screen per terminal state.
let hostScreens: [TerminalState: CGImage] = Dictionary(
    uniqueKeysWithValues: terminalStates.map { state in
        let canvas = Canvas(width: Int(hostScreenSize.width), height: Int(hostScreenSize.height), background: hostScreenFill)
        drawEditor(canvas)
        drawTerminal(canvas, state)
        drawUnframed(canvas, badgeExpanded, x: badgeBox.minX, y: badgeBox.minY, size: badgeBox.size)
        return (state, canvas.image())
    }
)

let terminalTitleBar = CGRect(x: terminalRect.minX, y: terminalRect.minY, width: terminalRect.width, height: stagedTitleBar)
if terminalTitleBar.intersects(badgeBox) { die("the presence badge overlaps the terminal's title bar on the host screen") }

let fullScreenWidth = min(stage.width, (stage.height * 1.6).rounded(.down))
let fullScreenHeight = (fullScreenWidth * 0.625).rounded(.down)

/// Beat 6: the host screen alone, centred in the stage.
let zoomedScreenRect = CGRect(
    x: stage.minX + ((stage.width - fullScreenWidth) / 2).rounded(.down),
    y: stage.minY + ((stage.height - fullScreenHeight) / 2).rounded(.down),
    width: fullScreenWidth, height: fullScreenHeight
)

/// Beat 6 looks at the badge: the smallest 16:10 window onto the host screen
/// that holds the whole terminal and the badge, so no line of text is cut.
let badgeViewport: CGRect = {
    let subject = terminalRect.union(badgeBox).insetBy(dx: -40, dy: -40)
    let width = max(subject.width, subject.height * 1.6)
    let height = width * 0.625
    if width > hostScreenSize.width || height > hostScreenSize.height {
        die("the terminal and the badge do not fit one 16:10 view of the host screen")
    }
    return CGRect(
        x: min(max(0, subject.midX - width / 2), hostScreenSize.width - width),
        y: min(max(0, subject.midY - height / 2), hostScreenSize.height - height),
        width: width, height: height
    )
}()

/// Beat 5: the viewer's session window on the left, the host screen on the right.
let splitScreenSize = CGSize(width: 900, height: 562)
let pinnedStripHeight = (splitScreenSize.width * CGFloat(pinnedStrip.height) / CGFloat(pinnedStrip.width)).rounded()
let sessionRect = CGRect(
    x: 72, y: stage.minY + ((stage.height - pinnedStripHeight - splitScreenSize.height) / 2).rounded(.down),
    width: splitScreenSize.width, height: pinnedStripHeight + splitScreenSize.height
)
let sessionScreenRect = CGRect(
    x: sessionRect.minX, y: sessionRect.minY + pinnedStripHeight,
    width: splitScreenSize.width, height: splitScreenSize.height
)
let splitScreenRect = CGRect(
    x: 1076, y: stage.minY + ((stage.height - splitScreenSize.height) / 2).rounded(.down),
    width: splitScreenSize.width, height: splitScreenSize.height
)

/// The end card: the session window, as tall as the card leaves room for.
let endCardTop: CGFloat = 236
let endCardBottom: CGFloat = 1104
let endWindowWidth: CGFloat = {
    let proportion = 90.0 / 1920 + 10.0 / 16
    return (CGFloat(endCardBottom - endCardTop) / proportion).rounded(.down)
}()
let endStripHeight = (endWindowWidth * 90 / 1920).rounded()
let endScreenHeight = (endWindowWidth * 10 / 16).rounded(.down)
let endWindowRect = CGRect(
    x: ((CGFloat(sceneWidth) - endWindowWidth) / 2).rounded(.down), y: endCardTop,
    width: endWindowWidth, height: endStripHeight + endScreenHeight
)
let endScreenRect = CGRect(
    x: endWindowRect.minX, y: endWindowRect.minY + endStripHeight, width: endWindowWidth, height: endScreenHeight
)

func strokeFrame(_ canvas: Canvas, _ rect: CGRect, alpha: Double = 1) {
    canvas.context.addPath(roundedPath(rect, inset: borderWidth / 2))
    canvas.context.setStrokeColor(windowLine.copy(alpha: CGFloat(alpha))!)
    canvas.context.setLineWidth(borderWidth)
    canvas.context.strokePath()
}

/// Draws the part of the host screen inside `source` so that it fills `box`.
func drawHostScreen(
    _ canvas: Canvas, _ state: TerminalState, source: CGRect, in box: CGRect, borderAlpha: Double = 1
) {
    guard let image = hostScreens[state] else { die("no host screen for the terminal state \(state)") }
    let rect = canvas.rect(box.minX, box.minY, box.width, box.height)
    let scaleX = box.width / source.width
    let scaleY = box.height / source.height
    canvas.context.saveGState()
    canvas.context.addPath(roundedPath(rect))
    canvas.context.clip()
    canvas.context.draw(
        image,
        in: canvas.rect(
            box.minX - source.minX * scaleX, box.minY - source.minY * scaleY,
            hostScreenSize.width * scaleX, hostScreenSize.height * scaleY
        )
    )
    canvas.context.restoreGState()
    if borderAlpha > 0 { strokeFrame(canvas, rect, alpha: borderAlpha) }
}

/// The viewer's session window without its picture: the pinned strip, over
/// the colour of the host screen's backdrop, in a frame.
func drawSessionFrame(_ canvas: Canvas, _ box: CGRect) {
    let rect = canvas.rect(box.minX, box.minY, box.width, box.height)
    let stripHeight = (box.width * CGFloat(pinnedStrip.height) / CGFloat(pinnedStrip.width)).rounded()
    canvas.context.saveGState()
    canvas.context.addPath(roundedPath(rect))
    canvas.context.clip()
    canvas.context.setFillColor(hostScreenFill)
    canvas.context.fill(rect)
    canvas.context.draw(pinnedStrip, in: canvas.rect(box.minX, box.minY, box.width, stripHeight))
    canvas.context.restoreGState()
    strokeFrame(canvas, rect)
}

// MARK: - Easing and motion

/// A CSS-style cubic Bézier from (0,0) to (1,1) with control points (x1,y1)
/// and (x2,y2), read as progress in, progress out.
struct CubicBezier {
    let x1: Double, y1: Double, x2: Double, y2: Double

    init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) {
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
    }

    private func point(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * t * a + 3 * u * t * t * b + t * t * t
    }

    private func slope(_ a: Double, _ b: Double, _ t: Double) -> Double {
        let u = 1 - t
        return 3 * u * u * a + 6 * u * t * (b - a) + 3 * t * t * (1 - b)
    }

    func callAsFunction(_ x: Double) -> Double {
        if x <= 0 { return 0 }
        if x >= 1 { return 1 }
        var t = x
        for _ in 0..<8 {
            let error = point(x1, x2, t) - x
            if abs(error) < 1e-7 { return point(y1, y2, t) }
            let derivative = slope(x1, x2, t)
            if abs(derivative) < 1e-6 { break }
            t -= error / derivative
        }
        var low = 0.0, high = 1.0
        t = x
        for _ in 0..<48 {
            let error = point(x1, x2, t) - x
            if abs(error) < 1e-7 { break }
            if error < 0 { low = t } else { high = t }
            t = (low + high) / 2
        }
        return point(y1, y2, t)
    }
}

/// Entrances, exits, fades and caption moves.
let easeOut = CubicBezier(0.23, 1, 0.32, 1)
/// Things that travel across the screen: the pointer, a resize, the zoom.
let easeInOut = CubicBezier(0.77, 0, 0.175, 1)

func progress(_ t: Double, _ start: Double, _ duration: Double) -> Double {
    min(1, max(0, (t - start) / duration))
}

func lerp(_ from: Double, _ to: Double, _ amount: Double) -> Double {
    amount >= 1 ? to : from + (to - from) * amount
}

func lerp(_ from: CGPoint, _ to: CGPoint, _ amount: Double) -> CGPoint {
    CGPoint(x: lerp(from.x, to.x, amount), y: lerp(from.y, to.y, amount))
}

func lerp(_ from: CGRect, _ to: CGRect, _ amount: Double) -> CGRect {
    CGRect(
        x: lerp(from.minX, to.minX, amount), y: lerp(from.minY, to.minY, amount),
        width: lerp(from.width, to.width, amount), height: lerp(from.height, to.height, amount)
    )
}

/// A value that glides, with `easeOut`, from one target to the next at each step.
func ramp(_ t: Double, from initial: Double, _ steps: [(start: Double, duration: Double, to: Double)]) -> Double {
    var value = initial
    for step in steps {
        if t < step.start { return value }
        let amount = progress(t, step.start, step.duration)
        if amount < 1 { return lerp(value, step.to, easeOut(amount)) }
        value = step.to
    }
    return value
}

/// How a thing is drawn right now. Offsets are in scene pixels, y down.
struct Appearance {
    var alpha = 1.0
    var dx = 0.0
    var dy = 0.0
    var scale = 1.0
}

/// An entrance or exit. For an entrance the offsets and scale are where it
/// starts; for an exit, where it ends.
struct Motion {
    let start: Double
    let duration: Double
    var dx = 0.0
    var dy = 0.0
    var scale = 1.0
}

/// Nil while the thing is not on screen.
func appearance(at t: Double, enter: Motion?, exit: Motion?) -> Appearance? {
    if let enter, t < enter.start { return nil }
    if let exit, t >= exit.start {
        let amount = easeOut(progress(t, exit.start, exit.duration))
        if amount >= 1 { return nil }
        return Appearance(
            alpha: 1 - amount, dx: lerp(0, exit.dx, amount), dy: lerp(0, exit.dy, amount), scale: lerp(1, exit.scale, amount)
        )
    }
    if let enter {
        let amount = easeOut(progress(t, enter.start, enter.duration))
        return Appearance(
            alpha: amount, dx: lerp(enter.dx, 0, amount), dy: lerp(enter.dy, 0, amount), scale: lerp(enter.scale, 1, amount)
        )
    }
    return Appearance()
}

/// Draws `body` as one group with the appearance applied; a thing at rest is
/// drawn directly.
func draw(_ canvas: Canvas, _ look: Appearance, about center: CGPoint = .zero, _ body: () -> Void) {
    if look.alpha <= 0 { return }
    if look.alpha >= 1, look.dx == 0, look.dy == 0, look.scale == 1 {
        body()
        return
    }
    let context = canvas.context
    context.saveGState()
    context.translateBy(x: look.dx, y: -look.dy)
    if look.scale != 1 {
        let pivot = CGPoint(x: center.x, y: CGFloat(sceneHeight) - center.y)
        context.translateBy(x: pivot.x, y: pivot.y)
        context.scaleBy(x: look.scale, y: look.scale)
        context.translateBy(x: -pivot.x, y: -pivot.y)
    }
    context.setAlpha(look.alpha)
    context.beginTransparencyLayer(auxiliaryInfo: nil)
    body()
    context.endTransparencyLayer()
    context.restoreGState()
}

// MARK: - Pointer

let pointerHeight: CGFloat = 44
let pointerOutline: [CGPoint] = [
    (0, 0), (0, 0.72), (0.18, 0.56), (0.30, 0.82), (0.40, 0.78), (0.28, 0.52), (0.50, 0.52)
].map { CGPoint(x: $0.0, y: $0.1) }

func drawPointer(_ canvas: Canvas, tip: CGPoint) {
    let path = CGMutablePath()
    for (index, corner) in pointerOutline.enumerated() {
        let point = CGPoint(
            x: tip.x + corner.x * pointerHeight, y: CGFloat(sceneHeight) - (tip.y + corner.y * pointerHeight)
        )
        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    let context = canvas.context
    context.setLineJoin(.round)
    context.setLineWidth(3)
    context.setStrokeColor(chromeBackground)
    context.addPath(path)
    context.strokePath()
    context.setFillColor(wordmarkColor)
    context.addPath(path)
    context.fillPath()
}

func drawClickRing(_ canvas: Canvas, at tip: CGPoint, amount: Double) {
    let radius = lerp(12, 34, amount)
    let center = CGPoint(x: tip.x, y: CGFloat(sceneHeight) - tip.y)
    canvas.context.setStrokeColor(accent.copy(alpha: CGFloat(0.7 * (1 - amount)))!)
    canvas.context.setLineWidth(3)
    canvas.context.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius))
}

/// One travel of the pointer to a control, and the click that ends it.
struct PointerRun {
    let start: Double
    let travel: Double
    let from: CGPoint
    let to: CGPoint
    /// Fades in over the first 0.15 s of the travel; false when the pointer is already on screen.
    let entering: Bool
    let fadeOutAt: Double?

    static let pressDuration = 0.06
    static let releaseDuration = 0.10
    static let fadeOutDuration = 0.2

    var click: Double { start + travel + PointerRun.pressDuration }
}

struct PointerLook {
    let tip: CGPoint
    let appearance: Appearance
}

func pointerLook(of run: PointerRun, at t: Double) -> PointerLook? {
    var alpha = run.entering ? easeOut(progress(t, run.start, 0.15)) : 1
    if let fadeOutAt = run.fadeOutAt, t >= fadeOutAt {
        let amount = easeOut(progress(t, fadeOutAt, PointerRun.fadeOutDuration))
        if amount >= 1 { return nil }
        alpha *= 1 - amount
    }
    let tip = lerp(run.from, run.to, easeInOut(progress(t, run.start, run.travel)))
    let arrived = t - (run.start + run.travel)
    var press = 1.0
    if arrived >= PointerRun.pressDuration {
        press = lerp(0.9, 1, easeOut(progress(arrived, PointerRun.pressDuration, PointerRun.releaseDuration)))
    } else if arrived > 0 {
        press = lerp(1, 0.9, easeOut(progress(arrived, 0, PointerRun.pressDuration)))
    }
    return PointerLook(tip: tip, appearance: Appearance(alpha: alpha, scale: press))
}

// MARK: - Timeline

/// Seconds between samples of the timeline.
let sampleStep = 0.05

/// A content change lands on the nearest sample.
func snap(_ t: Double) -> Double { (t / sampleStep).rounded() * sampleStep }

let resizeDuration = 0.32
let captionOutDuration = 0.18
let captionInDuration = 0.36
let chipDuration = 0.24
let clickRingDuration = 0.32

// Step by step; see the comments on each beat for what moves.
let hostRestsFirst = 1.0
let clickShowCode = hostRestsFirst + 0.5 + PointerRun.pressDuration
let captionTwoSettles = clickShowCode + captionOutDuration + captionInDuration
let switchToViewer = captionTwoSettles + 2.0
let viewerEnters = switchToViewer + 0.2
let viewerSettles = viewerEnters + max(0.4, 0.06 + captionInDuration)
let addMachineStart = viewerSettles + 0.8
let clickAddMachine = addMachineStart + 0.5 + PointerRun.pressDuration
let workstationStart = clickAddMachine + resizeDuration + 0.6
let clickWorkstation = workstationStart + 0.45 + PointerRun.pressDuration
let typingStart = clickWorkstation + captionOutDuration + captionInDuration + 0.6
let typingOffsets = [0, 0.15, 0.35, 0.45, 0.65, 0.80]
let pairStart = typingStart + typingOffsets[5] + 0.7
let clickPair = pairStart + 0.45 + PointerRun.pressDuration
let viewerLeaves = clickPair + 0.12
let sessionEnters = viewerLeaves + 0.2
let hostScreenEnters = sessionEnters + 0.08
let sessionSettles = sessionEnters + max(0.08 + 0.42, 0.1 + captionInDuration)

// Beat 5: the person at the viewer types into the host's terminal.
let typingGaps = [0.10, 0.08, 0.12, 0.09, 0.11, 0.08, 0.10, 0.12, 0.09, 0.10]
let hostTypingStart = sessionSettles + 0.8
let lastKeyAt = hostTypingStart + typingGaps.reduce(0, +)
let outputOneAt = lastKeyAt + 0.35 + 0.25
let outputTwoAt = outputOneAt + 0.6
let outputThreeAt = outputTwoAt + 0.3

/// When each terminal state first shows, in order.
let terminalSchedule: [(at: Double, state: TerminalState)] = {
    var schedule = [(at: 0.0, state: terminalStates[0])]
    var time = hostTypingStart
    for (index, gap) in typingGaps.enumerated() {
        time += gap
        schedule.append((snap(time), TerminalState(typed: index + 1, output: 0)))
    }
    for (index, at) in [outputOneAt, outputTwoAt, outputThreeAt].enumerated() {
        schedule.append((snap(at), TerminalState(typed: terminalCommand.count, output: index + 1)))
    }
    return schedule
}()

func terminalState(at t: Double) -> TerminalState {
    terminalSchedule.last(where: { $0.at <= t + 1e-9 })?.state ?? terminalStates[0]
}

let zoomDuration = 0.7
let zoomStart = outputThreeAt + 1.6
let zoomSettles = zoomStart + max(zoomDuration, 0.45 + captionInDuration)
let endCardStart = zoomSettles + 2.4
let pullBackDuration = 0.8
let lockupEnters = endCardStart + pullBackDuration - 0.15
let cardSettles = lockupEnters + 0.07 + 0.48
let loopStart = cardSettles + 3.0
let hostReturns = loopStart + 0.32
let timelineEnd = hostReturns + max(0.4, 0.06 + captionInDuration)

/// The moment the still picture is taken: the end card at rest.
let stillTime = cardSettles + 1.0

// Where the pointer goes: tips, in render pixels, mapped through the window's resting rect.
func scenePoint(_ rect: CGRect, _ tip: CGPoint) -> CGPoint {
    CGPoint(x: rect.minX + tip.x * windowScale, y: rect.minY + tip.y * windowScale)
}

let hostReadyRect = restRect(hostReady)
let hostCodeRect = restRect(hostCode)
let machinesRect = restRect(machinesEmpty)
let pickerRect = restRect(viewerPicker)
let codeRect = restRect(viewerCode)

let showCodeTip = scenePoint(hostReadyRect, CGPoint(x: 400, y: 276))
let addMachineTip = scenePoint(machinesRect, CGPoint(x: 190, y: 256))
let workstationTip = scenePoint(pickerRect, CGPoint(x: 330, y: 290))
let pairTip = scenePoint(codeRect, CGPoint(x: 290, y: 494))

func approach(_ tip: CGPoint) -> CGPoint { CGPoint(x: tip.x + 180, y: tip.y + 120) }

let pointerRuns: [PointerRun] = [
    PointerRun(
        start: hostRestsFirst, travel: 0.5, from: approach(showCodeTip), to: showCodeTip,
        entering: true, fadeOutAt: clickShowCode + 0.1
    ),
    PointerRun(
        start: addMachineStart, travel: 0.5, from: approach(addMachineTip), to: addMachineTip,
        entering: true, fadeOutAt: nil
    ),
    PointerRun(
        start: workstationStart, travel: 0.45, from: addMachineTip, to: workstationTip,
        entering: false, fadeOutAt: clickWorkstation + 0.1
    ),
    PointerRun(
        start: pairStart, travel: 0.45, from: approach(pairTip), to: pairTip,
        entering: true, fadeOutAt: viewerLeaves
    )
]

/// A window showing `image` from `cut` on, resting in `rect`.
struct WindowState {
    let cut: Double
    let image: CGImage
    let rect: CGRect
}

/// The content cuts at the cut; the frame then glides from the old rect to the new.
func windowState(_ states: [WindowState], at t: Double) -> (image: CGImage, rect: CGRect) {
    var index = 0
    for (position, state) in states.enumerated() where t + 1e-9 >= state.cut { index = position }
    let current = states[index]
    if index == 0 { return (current.image, current.rect) }
    let amount = easeInOut(progress(t, current.cut, resizeDuration))
    return (current.image, lerp(states[index - 1].rect, current.rect, amount))
}

func drawTrackedWindow(_ canvas: Canvas, _ states: [WindowState], at t: Double, enter: Motion?, exit: Motion?) {
    guard let look = appearance(at: t, enter: enter, exit: exit) else { return }
    let state = windowState(states, at: t)
    draw(canvas, look, about: CGPoint(x: state.rect.midX, y: state.rect.midY)) {
        drawWindow(canvas, state.image, in: state.rect)
    }
}

let hostFirstStates = [
    WindowState(cut: -1, image: hostReady, rect: hostReadyRect),
    WindowState(cut: snap(clickShowCode), image: hostCode, rect: hostCodeRect)
]
let hostReturnStates = [WindowState(cut: -1, image: hostReady, rect: hostReadyRect)]
let viewerStates =
    [
        WindowState(cut: -1, image: machinesEmpty, rect: machinesRect),
        WindowState(cut: snap(clickAddMachine), image: viewerPicker, rect: pickerRect),
        WindowState(cut: snap(clickWorkstation), image: viewerCode, rect: codeRect)
    ]
    + viewerTyped.enumerated().map { position, image in
        WindowState(cut: snap(typingStart + typingOffsets[position]), image: image, rect: codeRect)
    }

struct CaptionRun {
    let index: Int
    let enterAt: Double?
    let exitAt: Double?
    var exitDuration = captionOutDuration
}

let captionRuns = [
    CaptionRun(index: 0, enterAt: nil, exitAt: clickShowCode),
    CaptionRun(index: 1, enterAt: clickShowCode + captionOutDuration, exitAt: switchToViewer),
    CaptionRun(index: 2, enterAt: viewerEnters + 0.06, exitAt: clickWorkstation),
    CaptionRun(index: 3, enterAt: clickWorkstation + captionOutDuration, exitAt: viewerLeaves),
    CaptionRun(index: 4, enterAt: sessionEnters + 0.1, exitAt: zoomStart),
    CaptionRun(index: 5, enterAt: zoomStart + 0.45, exitAt: endCardStart, exitDuration: 0.24),
    CaptionRun(index: 0, enterAt: hostReturns + 0.06, exitAt: nil)
]

// MARK: - The end card

let lockupIconSide: CGFloat = 120
let lockupGap: CGFloat = 28
let lockupCenterY: CGFloat = 132
let lockupWordmark = line("Sensorium", font: wordmarkFont(size: 96), color: wordmarkColor, kern: 0)

/// The app icon and the name, centred as a pair above the session window.
func drawLockup(_ canvas: Canvas, at t: Double, fade: Double) {
    let pairWidth = lockupIconSide + lockupGap + textWidth(lockupWordmark)
    let left = ((CGFloat(sceneWidth) - pairWidth) / 2).rounded(.down)
    let iconTop = lockupCenterY - lockupIconSide / 2
    func look(after delay: Double) -> Appearance? {
        guard var look = appearance(at: t, enter: Motion(start: lockupEnters + delay, duration: 0.48, dy: 12), exit: nil) else {
            return nil
        }
        look.alpha *= fade
        return look
    }
    if let look = look(after: 0) {
        draw(canvas, look) {
            canvas.context.draw(appIcon, in: canvas.rect(left, iconTop, lockupIconSide, lockupIconSide))
        }
    }
    if let look = look(after: 0.07) {
        draw(canvas, look) {
            drawText(
                canvas, lockupWordmark, x: left + lockupIconSide + lockupGap,
                baseline: lockupCenterY + CTFontGetCapHeight(wordmarkFont(size: 96)) / 2
            )
        }
    }
}

// MARK: - A frame of the walkthrough

/// Which part of the host screen is shown, and where it is drawn.
func camera(at t: Double) -> (source: CGRect, box: CGRect) {
    if t < endCardStart {
        let amount = easeInOut(progress(t, zoomStart, zoomDuration))
        return (lerp(hostScreenBounds, badgeViewport, amount), lerp(splitScreenRect, zoomedScreenRect, amount))
    }
    let amount = easeInOut(progress(t, endCardStart, pullBackDuration))
    return (lerp(badgeViewport, hostScreenBounds, amount), lerp(zoomedScreenRect, endScreenRect, amount))
}

/// The whole picture at time `t`, drawn straight at `scale` times scene size.
func frame(at t: Double, scale: CGFloat = 0.625) -> CGImage {
    let canvas = Canvas(width: sceneWidth, height: sceneHeight, background: chromeBackground, scale: scale)

    let chips = Appearance(alpha: ramp(t, from: 1, [(endCardStart, chipDuration, 0), (hostReturns, chipDuration, 1)]))
    let leftLit = ramp(t, from: 0, [(switchToViewer, chipDuration, 1), (zoomStart, chipDuration, 0)])
    let rightLit = ramp(t, from: 1, [(switchToViewer, chipDuration, 0), (viewerLeaves, chipDuration, 1)])
    draw(canvas, chips) { drawChips(canvas, left: leftLit, right: rightLit) }

    for run in captionRuns {
        let motion: (Double, Double, Double) -> Motion = { Motion(start: $0, duration: $1, dy: $2) }
        let look = appearance(
            at: t,
            enter: run.enterAt.map { motion($0, captionInDuration, 12) },
            exit: run.exitAt.map { motion($0, run.exitDuration, -10) }
        )
        if let look { draw(canvas, look) { drawCaption(canvas, run.index) } }
    }

    drawTrackedWindow(canvas, hostFirstStates, at: t, enter: nil, exit: Motion(start: switchToViewer, duration: 0.2, dx: 32))
    drawTrackedWindow(canvas, hostReturnStates, at: t, enter: Motion(start: hostReturns, duration: 0.4, dx: 32), exit: nil)
    drawTrackedWindow(
        canvas, viewerStates, at: t,
        enter: Motion(start: viewerEnters, duration: 0.4, dx: -32),
        exit: Motion(start: viewerLeaves, duration: 0.2, scale: 0.98)
    )

    let state = terminalState(at: t)
    let cardFade = 1 - easeOut(progress(t, loopStart, 0.32))
    if let look = appearance(
        at: t, enter: Motion(start: sessionEnters, duration: 0.42, dy: 16), exit: Motion(start: zoomStart, duration: 0.2)
    ) {
        draw(canvas, look) {
            drawSessionFrame(canvas, sessionRect)
            drawHostScreen(canvas, state, source: hostScreenBounds, in: sessionScreenRect, borderAlpha: 0)
            drawLabel(canvas, "Session window", x: 72, baseline: labelBaseline)
        }
    }

    let frameIn = easeOut(progress(t, endCardStart + pullBackDuration - 0.4, 0.4))
    draw(canvas, Appearance(alpha: frameIn * cardFade)) { drawSessionFrame(canvas, endWindowRect) }

    let view = camera(at: t)
    if var look = appearance(at: t, enter: Motion(start: hostScreenEnters, duration: 0.42, dy: 16), exit: nil) {
        look.alpha *= cardFade
        draw(canvas, look) {
            drawHostScreen(canvas, state, source: view.source, in: view.box, borderAlpha: 1 - frameIn)
        }
        var label = look
        label.alpha *= 1 - easeOut(progress(t, zoomStart, 0.2))
        draw(canvas, label) { drawLabel(canvas, "Host screen", x: 1076, baseline: labelBaseline) }
    }

    drawLockup(canvas, at: t, fade: cardFade)

    for run in pointerRuns {
        let age = t - run.click
        if age >= 0, age < clickRingDuration {
            drawClickRing(canvas, at: run.to, amount: easeOut(progress(t, run.click, clickRingDuration)))
        }
    }
    if let run = pointerRuns.last(where: { $0.start <= t }), let look = pointerLook(of: run, at: t) {
        draw(canvas, look.appearance, about: look.tip) { drawPointer(canvas, tip: look.tip) }
    }
    return canvas.image()
}

// MARK: - Files

func fileSize(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
}

func report(_ url: URL, width: Int, height: Int, budget: Int?) {
    let bytes = fileSize(url)
    print("\(url.path)  \(width)x\(height)  \(bytes) bytes")
    if let budget, bytes > budget {
        die("\(url.lastPathComponent) is \(bytes) bytes, over its budget of \(budget)")
    }
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.removeItem(at: url)
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        die("cannot create \(url.lastPathComponent)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { die("cannot write \(url.lastPathComponent)") }
}

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
} catch {
    die("cannot create \(outputDirectory.path)")
}

// MARK: - pairing.gif

func pixels(of image: CGImage) -> Data {
    guard let data = image.dataProvider?.data else { die("cannot read back a frame") }
    return data as Data
}

/// Samples the timeline every `sampleStep` seconds and keeps one frame for each
/// run of identical samples, so a rest costs a single frame. The sample at the
/// end of the timeline is the first picture again; it is dropped, so the loop
/// wraps without showing it twice.
func writeGIF(to url: URL) {
    let sampleCount = Int((timelineEnd / sampleStep).rounded(.up)) + 1
    var runs: [(first: Int, samples: Int)] = []
    var previous: Data?
    var opening: Data?
    for sample in 0..<sampleCount {
        let current = pixels(of: frame(at: Double(sample) * sampleStep))
        if current == previous {
            runs[runs.count - 1].samples += 1
        } else {
            runs.append((sample, 1))
        }
        if opening == nil { opening = current }
        previous = current
    }
    if runs.count > 1, previous == opening { runs.removeLast() }

    try? FileManager.default.removeItem(at: url)
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, "com.compuserve.gif" as CFString, runs.count, nil
    ) else { die("cannot create pairing.gif") }
    let loop = [kCGImagePropertyGIFDictionary as String: [kCGImagePropertyGIFLoopCount as String: 0]]
    CGImageDestinationSetProperties(destination, loop as CFDictionary)
    for run in runs {
        let delay = (Double(run.samples) * sampleStep * 100).rounded() / 100
        let properties = [kCGImagePropertyGIFDictionary as String: [
            kCGImagePropertyGIFDelayTime as String: delay,
            kCGImagePropertyGIFUnclampedDelayTime as String: delay
        ]]
        CGImageDestinationAddImage(destination, frame(at: Double(run.first) * sampleStep), properties as CFDictionary)
    }
    guard CGImageDestinationFinalize(destination) else { die("cannot write pairing.gif") }
    report(url, width: 1280, height: 720, budget: 5 * 1024 * 1024)
    print("pairing.gif: \(runs.count) frames, \(runs.reduce(0) { $0 + $1.samples }) samples of \(sampleStep) s")
}

// MARK: - pairing-still.png

func writeStill(to url: URL) {
    writePNG(frame(at: stillTime, scale: 1), to: url)
    report(url, width: sceneWidth, height: sceneHeight, budget: 1024 * 1024)
}

// MARK: - at-the-host.png

func writeAtTheHost(to url: URL) {
    let width = 2048
    let margin: CGFloat = 48
    let gap: CGFloat = 24
    let contents: [(label: String, placement: Placement, framed: Bool)] = [
        ("While a session is live", Placement(badgeExpanded), false),
        ("If asking first is on", Placement(render("host-screen-presence-prompt-1-short")), true),
        (
            "After it ends",
            // The last-session record: its heading and its card, without the
            // paired-machine list above.
            Placement(crop(
                render("host-window-12-last-session-clean-stop"),
                CGRect(x: 32, y: 922, width: 656, height: 206),
                "the host window"
            )),
            true
        )
    ]
    // One scale for all three so they stay the same size relative to each other.
    let available = CGFloat(width) - 2 * margin - 2 * gap - CGFloat(contents.count) * 2 * panelPadding
    let natural = contents.reduce(0) { $0 + CGFloat($1.placement.image.width) }
    let scale = min(1, available / natural)
    let sizes = contents.map {
        CGSize(
            width: (CGFloat($0.placement.image.width) * scale).rounded(.down),
            height: (CGFloat($0.placement.image.height) * scale).rounded(.down)
        )
    }
    let contentHeight = sizes.map(\.height).max() ?? 0
    let panelHeight = contentHeight + 2 * panelPadding
    let spare = CGFloat(width) - 2 * margin - 2 * gap - sizes.reduce(0) { $0 + $1.width + 2 * panelPadding }
    let extra = (spare / CGFloat(contents.count)).rounded(.down)

    let canvas = Canvas(width: width, height: Int(panelTop + panelHeight + margin), background: chromeBackground)
    var x = margin
    for (index, item) in contents.enumerated() {
        let panelWidth = sizes[index].width + 2 * panelPadding + extra
        drawPanel(canvas, x: x, y: panelTop, width: panelWidth, height: panelHeight)
        drawLabel(canvas, item.label, x: x, baseline: 72)
        let box = CGRect(
            x: x + ((panelWidth - sizes[index].width) / 2).rounded(.down),
            y: panelTop + ((panelHeight - sizes[index].height) / 2).rounded(.down),
            width: sizes[index].width,
            height: sizes[index].height
        )
        if item.framed {
            drawFramed(canvas, item.placement, in: box)
        } else {
            drawUnframed(canvas, item.placement.image, x: box.minX, y: box.minY, size: box.size)
        }
        x += panelWidth + gap
    }
    writePNG(canvas.image(), to: url)
    report(url, width: canvas.width, height: canvas.height, budget: nil)
}

// MARK: - social-preview.png

func writeSocialPreview(to url: URL) {
    let width = 1280
    let height = 640
    let margin: CGFloat = 44
    let canvas = Canvas(width: width, height: height, background: chromeBackground)

    // The end card, from the top of the lockup to the foot of the window.
    let top = lockupCenterY - lockupIconSide / 2
    let scale = (CGFloat(height) - 2 * margin) / (endWindowRect.maxY - top)
    let card = frame(at: stillTime, scale: 1)
    canvas.context.draw(
        card,
        in: canvas.rect(
            (CGFloat(width) - CGFloat(sceneWidth) * scale) / 2, margin - top * scale,
            CGFloat(sceneWidth) * scale, CGFloat(sceneHeight) * scale
        )
    )
    writePNG(canvas.image(), to: url)
    report(url, width: width, height: height, budget: 1024 * 1024)
}

writeGIF(to: outputDirectory.appendingPathComponent("pairing.gif"))
writeStill(to: outputDirectory.appendingPathComponent("pairing-still.png"))
writeAtTheHost(to: outputDirectory.appendingPathComponent("at-the-host.png"))
writeSocialPreview(to: outputDirectory.appendingPathComponent("social-preview.png"))

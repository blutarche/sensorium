//
// Renders the repository's real AppKit views to PNG files, offscreen.
//
//   swift Scripts/render-ui-previews.swift [output-directory]
//
// Every view here is the production type from Sources/, constructed and drawn
// with no window, no display and no permissions, so on-canvas UI can be
// reviewed by eye without a host machine, a client machine and a live session between
// them. Nothing is reimplemented for the preview: a state this file cannot
// reach through the real type is named in `index.txt` rather than faked.
//
// The script compiles itself against the built package. Run 1 (the Swift
// interpreter) has no Sensorium modules on its search path, takes the `#else`
// branch below, runs `swift build`, and re-invokes `swiftc` on this same file
// with the modules and their objects. Run 2 takes the `#if` branch and renders.
//
// SwiftPM cannot build inside a nested sandbox; run this unsandboxed. It
// writes only to the output directory and `.build`.
//
// Reads `/Applications`, `/System/Applications` and `~/Applications` — one
// directory listing each, no file contents. That is `CanvasApplicationCatalog`
// doing exactly what it does on the host; a launcher rendered against a fake
// catalog would not be the launcher.

import Foundation

#if canImport(SensoriumHost) && canImport(SensoriumClient)

import AppKit
@testable import SensoriumClient
import SensoriumCore
@testable import SensoriumHost

// MARK: - Output layout

let arguments = Array(CommandLine.arguments.dropFirst())
/// This file's own place in the repository, which is what lets the default
/// output directory below be a path inside it rather than one that depends on
/// where the renderer happens to be run from.
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .standardizedFileURL
    .deletingLastPathComponent()
    .deletingLastPathComponent()
/// Named on the command line, or `Artifacts/ui-previews` -- ignored by Git,
/// like everything else in `Artifacts`, and inside the repository, so a
/// preview run writes nowhere a person has to go looking for it.
let outputDirectory = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
    ?? repositoryRoot.appendingPathComponent("Artifacts/ui-previews", isDirectory: true)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("render-ui-previews: \(message)\n".utf8))
    exit(1)
}

/// The canvas the host actually draws on, and the two stream scales the
/// simulated pass resamples through. 1.0x is not a no-op: the canvas is a
/// scale-2 display, so a 1920x1200 stream is already half the drawn pixels.
let canvas = VirtualCanvasConfiguration.remoteDefault
let streamScales: [Double] = [1.0, 1.5]

// MARK: - Bitmaps

let sRGB = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

func bitmapContext(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil,
        width: max(1, width),
        height: max(1, height),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: sRGB,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fail("could not allocate a \(width)x\(height) bitmap")
    }
    return context
}

/// Draws a view into a bitmap without a window. `cacheDisplay` is the AppKit
/// path that also captures layer-backed content, which is all of the chrome in
/// this design system — borders and fills live on layers, not in `draw(_:)`.
@MainActor
func render(_ view: NSView) -> CGImage {
    view.layoutSubtreeIfNeeded()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
        fail("AppKit refused a caching bitmap for \(type(of: view))")
    }
    view.cacheDisplay(in: view.bounds, to: rep)
    guard let image = rep.cgImage else {
        fail("no image from the cached bitmap for \(type(of: view))")
    }
    return image
}

/// Down to the streamed resolution and back up, at the canvas's own scale
/// factor. Resampling only: no H.264 quantisation, no motion, no bitrate.
func resampleThroughStream(_ image: CGImage, scale: Double, canvasScale: Int) -> CGImage {
    let factor = Double(canvasScale) * scale
    let down = bitmapContext(
        width: Int((Double(image.width) / factor).rounded()),
        height: Int((Double(image.height) / factor).rounded())
    )
    down.interpolationQuality = .high
    down.draw(image, in: CGRect(x: 0, y: 0, width: down.width, height: down.height))
    guard let small = down.makeImage() else {
        fail("downscale produced no image")
    }
    let up = bitmapContext(width: image.width, height: image.height)
    up.interpolationQuality = .high
    up.draw(small, in: CGRect(x: 0, y: 0, width: up.width, height: up.height))
    guard let restored = up.makeImage() else {
        fail("upscale produced no image")
    }
    return restored
}

/// `composite` for chrome that occupies a corner rather than the whole frame.
/// `rect` is in the same pixel space as `bottom`.
func place(_ top: CGImage, over bottom: CGImage, in rect: CGRect) -> CGImage {
    let context = bitmapContext(width: bottom.width, height: bottom.height)
    context.draw(bottom, in: CGRect(x: 0, y: 0, width: bottom.width, height: bottom.height))
    context.draw(top, in: rect)
    guard let image = context.makeImage() else {
        fail("placing chrome produced no image")
    }
    return image
}

func composite(_ top: CGImage, over bottom: CGImage) -> CGImage {
    let context = bitmapContext(width: bottom.width, height: bottom.height)
    let frame = CGRect(x: 0, y: 0, width: bottom.width, height: bottom.height)
    context.draw(bottom, in: frame)
    context.draw(top, in: frame)
    guard let composited = context.makeImage() else {
        fail("compositing produced no image")
    }
    return composited
}

struct PixelReport {
    let nonBackgroundFraction: Double
    let distinctColors: Int
    let backgroundHex: String

    var isBlank: Bool {
        nonBackgroundFraction < 0.005 || distinctColors < 16
    }
}

/// The check that a PNG is a picture rather than 4KB of one flat colour: the
/// most common colour is taken as the background, and everything else counted.
func inspect(_ image: CGImage) -> PixelReport {
    let context = bitmapContext(width: image.width, height: image.height)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let raw = context.data else {
        fail("no pixels to inspect")
    }
    let bytes = raw.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * image.height)
    var histogram: [UInt32: Int] = [:]
    for y in 0..<image.height {
        let row = y * context.bytesPerRow
        for x in 0..<image.width {
            let offset = row + x * 4
            let packed = UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2])
            histogram[packed, default: 0] += 1
        }
    }
    let total = image.width * image.height
    guard let background = histogram.max(by: { $0.value < $1.value }) else {
        fail("empty histogram")
    }
    return PixelReport(
        nonBackgroundFraction: Double(total - background.value) / Double(total),
        distinctColors: histogram.count,
        backgroundHex: String(format: "#%06X", background.key)
    )
}

// MARK: - Index

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func padLeft(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
}

struct IndexEntry {
    let file: String
    let bytes: Int
    let pixels: String
    let report: PixelReport
    let state: String
}

var index: [IndexEntry] = []
var blanks: [String] = []

@discardableResult
func write(_ image: CGImage, named name: String, state: String) -> IndexEntry {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("no PNG encoding for \(name)")
    }
    let url = outputDirectory.appendingPathComponent(name)
    do {
        try data.write(to: url)
    } catch {
        fail("could not write \(url.path): \(error)")
    }
    let report = inspect(image)
    if report.isBlank {
        blanks.append(name)
    }
    let entry = IndexEntry(
        file: name,
        bytes: data.count,
        pixels: "\(image.width)x\(image.height)",
        report: report,
        state: state
    )
    index.append(entry)
    print(
        pad(name, 46) + padLeft("\(data.count)", 10) + " bytes  " + pad(entry.pixels, 11)
            + " non-bg " + String(format: "%.3f", report.nonBackgroundFraction)
            + "  colours " + padLeft("\(report.distinctColors)", 6)
    )
    return entry
}

/// One natural-size pass and one per stream scale. `degrade` exists because
/// only the host's canvas goes through the encoder: for the viewer's own
/// chrome, the stream degrades the picture underneath and nothing else.
@MainActor
func writePasses(
    _ image: CGImage,
    prefix: String,
    state: String,
    degrade: (CGImage, Double) -> CGImage
) {
    write(image, named: "\(prefix)-natural.png", state: "\(state) [natural, as drawn]")
    for scale in streamScales {
        write(
            degrade(image, scale),
            named: String(format: "%@-stream%.1fx.png", prefix, scale),
            state: "\(state) [stream \(String(format: "%.1f", scale))x, resampling only — no H.264]"
        )
    }
}

@MainActor
func hostPasses(_ image: CGImage, prefix: String, state: String) {
    writePasses(image, prefix: prefix, state: state) { image, scale in
        resampleThroughStream(image, scale: scale, canvasScale: canvas.scale)
    }
}

// MARK: - Private state the real views hold

/// Reaches one stored property by name. Used only to drive a real view through
/// a real code path — the status relay, the labels the empty state owns — and
/// it aborts rather than guessing, so a renamed property fails the run instead
/// of quietly rendering the wrong state.
func stored<T>(_ label: String, of subject: Any, as type: T.Type = T.self) -> T {
    for child in Mirror(reflecting: subject).children where child.label == label {
        guard let typed = child.value as? T else {
            fail("\(label) is \(Swift.type(of: child.value)), not \(T.self)")
        }
        return typed
    }
    fail("no stored property named \(label) on \(Swift.type(of: subject))")
}

/// The relay hops to the main queue, exactly as it does when a launch outcome
/// arrives off the main thread on the host.
@MainActor
func pumpUntil(_ satisfied: () -> Bool, description: String) {
    for _ in 0..<200 where !satisfied() {
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    guard satisfied() else {
        fail("timed out waiting for \(description)")
    }
}

// MARK: - Synthetic frame

/// A stand-in for a decoded host frame. Deliberately not a screenshot: the
/// script captures no display. It says so on its face so no reviewer mistakes
/// it for a real capture.
@MainActor
func syntheticFrame(width: Int, height: Int) -> CGImage {
    let context = bitmapContext(width: width, height: height)
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let scale = Double(width) / 1920

    CanvasDesign.bg.nsColor.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    CanvasDesign.line.nsColor.setStroke()
    let grid = 80.0 * scale
    let path = NSBezierPath()
    path.lineWidth = 1
    for column in stride(from: 0.0, through: Double(width), by: grid) {
        path.move(to: NSPoint(x: column, y: 0))
        path.line(to: NSPoint(x: column, y: Double(height)))
    }
    for row in stride(from: 0.0, through: Double(height), by: grid) {
        path.move(to: NSPoint(x: 0, y: row))
        path.line(to: NSPoint(x: Double(width), y: row))
    }
    path.stroke()

    for (index, colour) in [CanvasDesign.bg2, CanvasDesign.bg3].enumerated() {
        let box = NSRect(
            x: (160 + Double(index) * 520) * scale,
            y: (200 + Double(index) * 120) * scale,
            width: 560 * scale,
            height: 380 * scale
        )
        colour.nsColor.setFill()
        box.fill()
        CanvasDesign.line2.nsColor.setStroke()
        NSBezierPath(rect: box).stroke()
    }

    let caption = NSAttributedString(
        string: "SYNTHETIC STAND-IN FRAME — NOT A REAL CAPTURE",
        attributes: [
            .font: CanvasDesign.font(.mono, size: 22 * scale, weight: .medium),
            .foregroundColor: CanvasDesign.muted.nsColor,
            .kern: CanvasDesign.kern(CanvasDesign.Tracking.wide, size: 22 * scale)
        ]
    )
    caption.draw(at: NSPoint(x: 160 * scale, y: Double(height) - 160 * scale))

    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else {
        fail("synthetic frame produced no image")
    }
    return image
}

// MARK: - Render

let application = NSApplication.shared
// No dock icon, no menu bar, no activation: this must not disturb whoever is
// logged in on the machine that runs it.
application.setActivationPolicy(.prohibited)

var fontNotes: [String] = []

MainActor.assumeIsolated {
    let families = Set(NSFontManager.shared.availableFontFamilies)
    for (face, expected) in [
        (DesignTypeface.primary, "Inter"),
        (DesignTypeface.alternate, "Space Grotesk"),
        (DesignTypeface.mono, "JetBrains Mono")
    ] {
        let resolved = CanvasDesign.font(face, size: 14).familyName ?? "unknown"
        fontNotes.append(
            "  host \(expected): installed=\(families.contains(expected)) resolved=\(resolved)"
                + (resolved == expected ? "" : "  <-- FALLBACK")
        )
    }
    for (mono, expected) in [(false, "Inter"), (true, "JetBrains Mono")] {
        let resolved = ViewerDesign.font(mono: mono, size: 14).familyName ?? "unknown"
        fontNotes.append(
            "  viewer \(expected): installed=\(families.contains(expected)) resolved=\(resolved)"
                + (resolved == expected ? "" : "  <-- FALLBACK")
        )
    }

    // The canvas the workspace is laid out for. Fabricated rather than created:
    // this script never asks for a display.
    let placement = CanvasWorkspacePlacement(
        displayID: 0,
        bounds: CGRect(x: 0, y: 0, width: canvas.logicalWidth, height: canvas.logicalHeight)
    )
    // What `WorkspaceContentView` gives the launcher on a 1920x1200 canvas.
    let launcherFrame = NSRect(x: 0, y: 0, width: 440, height: CGFloat(canvas.logicalHeight) - 96)

    // Every sentence on the launcher that names the host reads the view's
    // own `hostName`; a fixed one keeps these renders the same on every machine.
    @MainActor func launcher() -> CanvasLauncherView {
        let view = CanvasLauncherView(frame: launcherFrame, canvas: placement)
        view.hostName = "Kestrel Mac mini"
        return view
    }

    @MainActor func type(_ query: String, into view: CanvasLauncherView) {
        view.queryField.stringValue = query
        view.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: view.queryField))
    }

    @MainActor func post(_ report: CanvasLaunchReport, to view: CanvasLauncherView) {
        let label: NSTextField = stored("statusLabel", of: view)
        let expected = CanvasLauncherPresentation.outcomeStatus(
            application: report.application,
            outcome: report.outcome,
            hostName: view.hostName
        )
        stored("relay", of: view, as: LaunchStatusRelay.self).post(report)
        pumpUntil({ label.stringValue == expected.text }, description: "the launch status relay")
    }

    let catalog = CanvasApplicationCatalog.discover(
        roots: CanvasApplicationCatalog.defaultSearchRoots(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ),
        list: CanvasApplicationCatalog.systemListing
    )

    hostPasses(
        render(launcher()),
        prefix: "host-launcher-1-populated",
        state: "CanvasLauncherView, catalog as discovered on this machine (\(catalog.count) applications)"
    )

    let unique = catalog.first { CanvasApplicationCatalog.filter(catalog, query: $0.name).count == 1 }
    if let unique {
        let filtered = launcher()
        type(unique.name, into: filtered)
        hostPasses(
            render(filtered),
            prefix: "host-launcher-2-filtered-one-match",
            state: "CanvasLauncherView, query \"\(unique.name)\" matching exactly one application"
        )
    } else {
        fontNotes.append("  (no query on this machine's catalog matches exactly one application)")
    }

    let noMatch = launcher()
    type("qqzzxx", into: noMatch)
    hostPasses(
        render(noMatch),
        prefix: "host-launcher-3-no-match-filter",
        state: "CanvasLauncherView, query \"qqzzxx\" matching nothing — empty state over a non-empty catalog"
    )

    // `loadCatalog()` reads the disk with no seam, and this machine has
    // applications on it -- `testAdoptCatalog([])` drives this view through
    // its own real `adopt(catalog:)` → `applyQuery()` path with an empty
    // array instead, so the empty-state labels, their frame, and the status
    // line are all the real thing, not text poked into stale-framed labels.
    let emptyCatalog = launcher()
    emptyCatalog.testAdoptCatalog([])
    hostPasses(
        render(emptyCatalog),
        prefix: "host-launcher-4-empty-catalog",
        state: "CanvasLauncherView, no applications installed"
    )

    let launched = launcher()
    if let first = catalog.first {
        type(first.name, into: launched)
    }
    post(
        CanvasLaunchReport(application: catalog.first?.name ?? "Safari", outcome: .placed(windows: 1)),
        to: launched
    )
    hostPasses(
        render(launched),
        prefix: "host-launcher-5-launch-succeeded",
        state: "CanvasLauncherView after a successful launch — status severity .ok (green)"
    )

    let failed = launcher()
    if let first = catalog.first {
        type(first.name, into: failed)
    }
    post(
        CanvasLaunchReport(
            application: catalog.first?.name ?? "Safari",
            outcome: .launchFailed(message: "NSWorkspace error")
        ),
        to: failed
    )
    hostPasses(
        render(failed),
        prefix: "host-launcher-6-launch-failed",
        state: "CanvasLauncherView after a failed launch — status severity .bad (red)"
    )

    // Every other launcher image draws its selected row in the inactive
    // treatment, because nothing here has a window and so nothing can be first
    // responder. `controlTextDidBeginEditing` is the delegate method AppKit
    // itself calls when the query field takes the keyboard, and it is the only
    // thing that marks the list active, so calling it directly is the same code
    // path with a simulated origin.
    let activeSelection = launcher()
    if let first = catalog.first {
        type(first.name, into: activeSelection)
    }
    activeSelection.controlTextDidBeginEditing(
        Notification(name: NSControl.textDidBeginEditingNotification, object: activeSelection.queryField)
    )
    hostPasses(
        render(activeSelection),
        prefix: "host-launcher-7-active-selection",
        state: "CanvasLauncherView with the query field holding the keyboard — accent selection and accent"
            + " field border; FORCED: the field-editor notification is simulated, everything drawn is real"
    )

    let workspace = WorkspaceContentView(
        frame: NSRect(x: 0, y: 0, width: canvas.logicalWidth, height: canvas.logicalHeight),
        canvas: placement
    )
    hostPasses(
        render(workspace),
        prefix: "host-workspace-content",
        state: "WorkspaceContentView, the whole \(canvas.logicalWidth)x\(canvas.logicalHeight) canvas"
            + " — editor, launcher, and the permanent keyboard hint above the editor"
    )

    // Both surfaces below are drawn on the screen of the machine the person is
    // sitting at, never on the streamed canvas, so neither gets a stream pass.
    // Each is rendered at the size it really appears at: blowing a 288pt panel
    // up to canvas size would flatter type nobody sees that big.

    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
    // One instant for the whole run, so the countdown is the same in every
    // rendering rather than depending on when the script happened to reach it.
    let issued = Date()
    // `.notHosting` without a problem has no fixture of its own: the GUI
    // starts hosting itself at launch, synchronously, before this status is
    // ever observed on screen, so this state is never actually reachable
    // there -- see `HostOperatorStatus.presentation(now:)`'s own comment on
    // its `.notHosting` case.
    let operatorStates: [(String, String, HostOperatorStatus)] = [
        (
            "host-menu-panel-2-hosting",
            "a bound listener, nobody connected yet",
            HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted)
        ),
        (
            "host-menu-panel-3-pairing",
            "a live pairing code and its countdown",
            HostOperatorStatus(
                connection: .hosting(address: "203.0.113.42"),
                pairing: .showing(code: "418297", expiresAt: issued.addingTimeInterval(272)),
                permissions: granted
            )
        ),
        (
            "host-menu-panel-4-serving",
            "a connected client, by the name it sent",
            HostOperatorStatus(connection: .serving(peerName: "Kestrel MacBook Pro"), permissions: granted)
        ),
        (
            "host-menu-panel-5-permission-missing",
            "Screen Recording revoked out from under a live session",
            HostOperatorStatus(
                connection: .serving(peerName: "Kestrel MacBook Pro"),
                permissions: HostPermissionRequestResult(
                    screenCapture: .approvalRequired,
                    accessibility: .granted
                )
            )
        )
    ]
    for (prefix, description, status) in operatorStates {
        let panel = HostOperatorPanelView(frame: .zero)
        panel.presentation = status.presentation(now: issued)
        write(
            render(panel),
            named: "\(prefix).png",
            state: "HostOperatorPanelView — \(description); 288pt wide at its own fitting height,"
                + " the size it hangs off the menu bar at; no stream pass, it never leaves the host"
        )
    }

    // The host window, like the panel above, never leaves the host and gets
    // no stream pass. Constructed but never shown -- `show()` is the only
    // thing that orders it in front of anyone.
    // `tailscaleAppURLLookup` defaults to never finding the app: every state
    // but host-window-14 renders deterministically, independent of whether
    // Tailscale happens to be installed on the machine running this script.
    @MainActor
    func hostWindow(
        status: HostOperatorStatus,
        tailscaleAppURLLookup: @escaping @MainActor () -> URL? = { nil },
        onOpenTailscaleApp: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> HostSetupWindowController {
        HostSetupWindowController(
            status: status,
            onRevealPairingCode: {},
            onStop: {},
            onOpenPermissionSettings: { _ in },
            tailscaleAppURLLookup: tailscaleAppURLLookup,
            onOpenTailscaleApp: onOpenTailscaleApp,
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
    }

    @MainActor
    func hostWindowContent(_ controller: HostSetupWindowController) -> NSView {
        guard let content = stored("window", of: controller, as: NSWindow.self).contentView else {
            fail("the host window has no content view")
        }
        return content
    }

    let noRows: [HostScreenArmingPresentation.PairedMachineRow] = []
    let onePairedRow: [HostScreenArmingPresentation.PairedMachineRow] = [
        HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xAB]),
            deviceName: "Kestrel MacBook Pro",
            isSharingRealScreen: false,
            credentialSummary: nil,
            blockedReason: HostScreenArmingPresentation.noCredentialNotice(deviceName: "Kestrel MacBook Pro")
        )
    ]
    let twoPairedRows: [HostScreenArmingPresentation.PairedMachineRow] = [
        HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xAB]),
            deviceName: "Kestrel MacBook Pro",
            isSharingRealScreen: true,
            credentialSummary: HostScreenArmingPresentation.words(for: .hardwareBound, deviceName: "Kestrel MacBook Pro"),
            blockedReason: nil,
            sharedDisplaysLine: "May share Built-in Display."
        ),
        HostScreenArmingPresentation.PairedMachineRow(
            devicePublicKey: Data([0xCD]),
            deviceName: "Kestrel MacBook Air",
            isSharingRealScreen: false,
            credentialSummary: nil,
            blockedReason: HostScreenArmingPresentation.noCredentialNotice(deviceName: "Kestrel MacBook Air")
        )
    ]

    // A machine that gave its own name at pairing, next to one still only known
    // by its key -- built through `pairedMachineRows` itself, the same
    // production path `sensoriumd` calls, so the card title and the small
    // key-fingerprint line beneath it are exactly what a real approved-
    // devices store produces, named and unnamed.
    let namedDeviceKey = Data([0x5D, 0xB7, 0x42, 0xA2, 0x01])
    let unnamedLegacyDeviceKey = Data([0x5D, 0xB7, 0x42, 0xA2, 0x02])
    let namedAndUnnamedRows = HostScreenArmingPresentation.pairedMachineRows(
        approvedDevices: [
            (namedDeviceKey, "kestrel-mbp", .hardwareBound),
            (unnamedLegacyDeviceKey, nil, nil)
        ],
        arming: HostScreenArming()
    )

    // One machine sharing two external displays -- same kind, so both would
    // read "External Display" alone, told apart here by where they sit
    // relative to the main display, the same disambiguation
    // `sharedDisplaysLine` applies to any pair that collides.
    let sameNameDisplaysKey = Data([0xEE])
    let sameNameMainDisplay = DisplaySnapshot(
        id: 1, pixelWidth: 1512, pixelHeight: 982, modeWidth: 1512, modeHeight: 982,
        modePixelWidth: 3024, modePixelHeight: 1964, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982),
        online: true, builtin: true, main: true, vendorNumber: 0x01, modelNumber: 0x01
    )
    let sameNameLeftDisplay = DisplaySnapshot(
        id: 2, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
        modePixelWidth: 1920, modePixelHeight: 1080, bounds: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
        online: true, builtin: false, main: false, vendorNumber: 0x02, modelNumber: 0x02
    )
    let sameNameRightDisplay = DisplaySnapshot(
        id: 3, pixelWidth: 1920, pixelHeight: 1080, modeWidth: 1920, modeHeight: 1080,
        modePixelWidth: 1920, modePixelHeight: 1080, bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080),
        online: true, builtin: false, main: false, vendorNumber: 0x03, modelNumber: 0x03
    )
    let sameNameDisplaysRows = HostScreenArmingPresentation.pairedMachineRows(
        approvedDevices: [(sameNameDisplaysKey, "Kestrel MacBook Pro", .hardwareBound)],
        arming: HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: sameNameDisplaysKey,
                deviceName: "Kestrel MacBook Pro",
                armedDisplays: [sameNameLeftDisplay, sameNameRightDisplay].map(HostScreenDisplayIdentity.init),
                minimumCredentialStrength: .hardwareBound,
                armedAt: Date()
            )
        ]),
        activeDisplays: [sameNameMainDisplay, sameNameLeftDisplay, sameNameRightDisplay]
    )

    // An armed device whose credential-strength snapshot predates this machine
    // capturing one -- `needsRearmingNotice`, checked here for wrapping.
    let needsRearmingKey = Data([0x33])
    let needsRearmingRows = HostScreenArmingPresentation.pairedMachineRows(
        approvedDevices: [(needsRearmingKey, "Kestrel MacBook Pro", .hardwareBound)],
        arming: HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: needsRearmingKey,
                deviceName: "Kestrel MacBook Pro",
                armedDisplays: [],
                armedAt: Date()
            )
        ])
    )

    let hostWindowStates: [(
        String, String, HostOperatorStatus, [HostScreenArmingPresentation.PairedMachineRow]
    )] = [
        (
            "host-window-1-no-address-found",
            "auto-detection found no tailnet address — Tailscale is probably not running",
            HostOperatorStatus(
                connection: .notHosting,
                permissions: granted,
                problem: HostStartupProblemCopy.noTailnetAddress
            ),
            noRows
        ),
        (
            "host-window-3-ready-no-machines-paired",
            "reachable and ready, nobody connected, no machine has paired yet, Show Pairing Code offered",
            HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            noRows
        ),
        (
            "host-window-4-pairing-code-shown",
            "a pairing code revealed on request, with its countdown, in place of the Show Pairing Code button",
            HostOperatorStatus(
                connection: .hosting(address: "203.0.113.42"),
                pairing: .showing(code: "418297", expiresAt: issued.addingTimeInterval(272)),
                permissions: granted
            ),
            noRows
        ),
        (
            "host-window-5-waiting-for-pairing",
            "an approved device finishing its own connection, before it has ever been shown as connected",
            HostOperatorStatus(connection: .pairingApproved(deviceName: "Kestrel MacBook Pro"), permissions: granted),
            noRows
        ),
        (
            "host-window-6-connected",
            "a connected client, virtual display only, with the Stop button that ends the session immediately",
            HostOperatorStatus(connection: .serving(peerName: "Kestrel MacBook Pro"), permissions: granted),
            twoPairedRows
        ),
        (
            "host-window-7-connected-host-screen",
            "a connected client sharing this machine's own host screen, distinct eyebrow and detail from a virtual display",
            HostOperatorStatus(
                connection: .servingHostScreen(peerName: "Kestrel MacBook Pro", displayLabel: "Built-in Display"),
                permissions: granted
            ),
            twoPairedRows
        ),
        (
            "host-window-8-screen-recording-not-granted",
            "the one failure a person can act on: Screen Recording not granted, with a button that opens the permission",
            HostOperatorStatus(
                connection: .hosting(address: "203.0.113.42"),
                permissions: HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .granted)
            ),
            noRows
        ),
        (
            "host-window-9-paired-machines-none",
            "ready, with the Paired machines section showing its own empty state",
            HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            noRows
        ),
        (
            "host-window-10-paired-machines-one-blocked",
            "one paired machine, sharing blocked, the row saying why in plain words on its own line",
            HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            onePairedRow
        ),
        (
            "host-window-11-paired-machines-two",
            "two paired machines, one sharing its host screen, one not yet able to",
            HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            twoPairedRows
        ),
        (
            "host-window-17-paired-machines-named-and-unnamed",
            "one paired machine titled by the name it gave, with its key on a small line underneath, next to one still"
                + " only known by its key fingerprint",
            HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            namedAndUnnamedRows
        ),
        (
            "host-window-18-paired-machines-same-name-displays",
            "one machine sharing two displays that would otherwise both read \u{201c}External Display\u{201d}, told apart"
                + " by where each sits relative to the main display",
            HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            sameNameDisplaysRows
        ),
        (
            "host-window-19-paired-machines-needs-rearming",
            "an armed device whose credential-strength snapshot predates this machine capturing one, saying what"
                + " happened and what to do about it",
            HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted),
            needsRearmingRows
        ),
        (
            "host-window-20-connected-with-pairing-code",
            "a code revealed while a machine is already connected: the connection, its Stop button, and the code "
                + "with its own Hide code control, all on screen at once",
            HostOperatorStatus(
                connection: .serving(peerName: "Kestrel MacBook Pro"),
                pairing: .showing(code: "418297", expiresAt: issued.addingTimeInterval(272)),
                permissions: granted
            ),
            twoPairedRows
        )
    ]
    for (prefix, description, status, rows) in hostWindowStates {
        let controller = hostWindow(status: status)
        controller.updatePairedMachines(rows)
        write(
            render(hostWindowContent(controller)),
            named: "\(prefix).png",
            state: "HostSetupWindowController — \(description); 360pt wide at the height its content needs;"
                + " no stream pass, it never leaves the host"
        )
    }

    // The no-address state again, this time with Tailscale found installed:
    // the "Open Tailscale" button. Neither closure below launches anything —
    // the lookup returns a fake file URL and the open action is a no-op,
    // the same injected-closure pattern every other host-window state uses
    // for its own permission or pairing actions.
    do {
        let controller = hostWindow(
            status: HostOperatorStatus(
                connection: .notHosting,
                permissions: granted,
                problem: HostStartupProblemCopy.noTailnetAddress
            ),
            tailscaleAppURLLookup: { URL(fileURLWithPath: "/Applications/Tailscale.app") },
            onOpenTailscaleApp: { _ in }
        )
        controller.updatePairedMachines(noRows)
        write(
            render(hostWindowContent(controller)),
            named: "host-window-14-no-address-tailscale-installed.png",
            state: "HostSetupWindowController — the no-address state with Tailscale found installed, showing the"
                + " Open Tailscale button; 360pt wide at the height its content needs; no stream pass, it never"
                + " leaves the host"
        )
    }

    // Sensorium Host cannot read its own key, so the window offers the
    // button that fixes it.
    do {
        let controller = hostWindow(
            status: HostOperatorStatus(
                connection: .notHosting,
                permissions: granted,
                identityProblem: .cannotReadKey
            )
        )
        controller.updatePairedMachines(noRows)
        write(
            render(hostWindowContent(controller)),
            named: "host-window-15-identity-needs-replacing.png",
            state: "HostSetupWindowController — Sensorium Host cannot read its own key, showing the Make a new"
                + " key button; 360pt wide at the height its content"
                + " needs; no stream pass, it never leaves the host"
        )
    }

    // The "last screen session" line, with a history, in its two distinct
    // outcomes.
    let lastSessionStates: [(String, String, String?)] = [
        (
            "host-window-12-last-session-clean-stop",
            "the last host-screen session ended with the Stop control, showing device, display, and both times",
            HostScreenSessionLogPresentation.line(for: HostScreenSessionRecord(
                deviceName: "Kestrel MacBook Pro",
                displayLabel: "Built-in Display",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                outcome: .stopped(at: Date(timeIntervalSince1970: 1_700_001_800))
            ))
        ),
        (
            "host-window-13-last-session-not-clean",
            "the last host-screen session was reconciled from a crash: no invented stop time, said plainly instead",
            HostScreenSessionLogPresentation.line(for: HostScreenSessionRecord(
                deviceName: "Kestrel MacBook Pro",
                displayLabel: "Built-in Display",
                startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                outcome: .endedWithoutCleanStop
            ))
        )
    ]
    for (prefix, description, lastSessionLine) in lastSessionStates {
        let controller = hostWindow(status: HostOperatorStatus(connection: .hosting(address: "203.0.113.42"), permissions: granted))
        controller.updatePairedMachines(twoPairedRows)
        controller.updateLastHostScreenSession(lastSessionLine)
        write(
            render(hostWindowContent(controller)),
            named: "\(prefix).png",
            state: "HostSetupWindowController — \(description); 360pt wide at the height its content needs;"
                + " no stream pass, it never leaves the host"
        )
    }

    // The badge -- the one window Sensorium places on a physical display --
    // naming the connected device and display, with a Stop button, expanded
    // (the first few seconds of a session) and
    // shrunk (the rest of it). Like the host window above, this never
    // leaves the host and gets no stream pass.
    @MainActor
    func badgeContent(expanded: Bool) -> NSView {
        let state = HostScreenBadgeState(
            content: HostScreenBadgeContent(deviceName: "Kestrel MacBook Pro", displayLabel: "Built-in Display"),
            startsExpanded: expanded
        )
        let controller = HostScreenBadgeWindowController(state: state)
        guard let content = stored("window", of: controller, as: NSWindow.self).contentView else {
            fail("the host-screen badge window has no content view")
        }
        return content
    }
    write(
        render(badgeContent(expanded: true)),
        named: "host-screen-badge-1-expanded.png",
        state: "HostScreenBadgeWindowController — expanded, the first few seconds of a session (docs/host-screen-design.md §6.4);"
            + " no stream pass, it never leaves the host"
    )
    write(
        render(badgeContent(expanded: false)),
        named: "host-screen-badge-2-shrunk.png",
        state: "HostScreenBadgeWindowController — shrunk, for the rest of the session; no stream pass, it never leaves the host"
    )

    // The collapsed corner pill: dragged out of the way and clicked once,
    // it drops to a dot, the device name, and Stop -- no eyebrow, no display
    // line, the full second line carried instead by the pill's own tooltip.
    @MainActor
    func collapsedBadgeContent() -> NSView {
        let state = HostScreenBadgeState(
            content: HostScreenBadgeContent(deviceName: "Kestrel MacBook Pro", displayLabel: "Built-in Display"),
            startsCollapsed: true
        )
        let controller = HostScreenBadgeWindowController(state: state, restoresPersistedLayout: false)
        guard let content = stored("window", of: controller, as: NSWindow.self).contentView else {
            fail("the host-screen badge window has no content view")
        }
        return content
    }
    write(
        render(collapsedBadgeContent()),
        named: "host-screen-badge-3-collapsed.png",
        state: "HostScreenBadgeWindowController — collapsed to its corner pill after a click; no stream pass, it never leaves the host"
    )

    // Design §6.2's "somebody is home, ask them" prompt. Content is fixed
    // at construction, so this only ever constructs one -- `ask()` (which
    // would block on a real modal session) is never called here, the same
    // "constructed but never shown" boundary the pairing window below draws
    // for the same reason.
    @MainActor
    func presencePromptContent(deviceName: String, displayLabel: String) -> NSView {
        let controller = HostScreenPresencePromptWindowController(
            content: HostScreenBadgeContent(deviceName: deviceName, displayLabel: displayLabel)
        )
        guard let content = stored("window", of: controller, as: NSWindow.self).contentView else {
            fail("the host-screen presence prompt window has no content view")
        }
        return content
    }
    let presencePromptStates: [(String, String, String, String)] = [
        (
            "host-screen-presence-prompt-1-short",
            "Kestrel MacBook Pro",
            "Built-in Display",
            "a short device name and display label, the common case"
        ),
        (
            "host-screen-presence-prompt-2-long-device-name",
            "Alex Kestrel-Whitfield\u{2019}s Sixteen-Inch MacBook Pro (2024, Space Black)",
            "Built-in Display",
            "a device name long enough to test the headline's own three-line wrap"
        ),
        (
            "host-screen-presence-prompt-3-long-display-label",
            "Kestrel MacBook Pro",
            "LG UltraFine 5K Display, connected over Thunderbolt 3 (Left of Built-in Display)",
            "a display label long enough to test the subtitle's own three-line wrap"
        )
    ]
    for (name, deviceName, displayLabel, description) in presencePromptStates {
        write(
            render(presencePromptContent(deviceName: deviceName, displayLabel: displayLabel)),
            named: "\(name).png",
            state: "HostScreenPresencePromptWindowController — docs/host-screen-design.md §6.2's host-screen presence prompt, "
                + "Allow/Don't Allow, thirty-second timeout, \(description); no stream pass, it never leaves the "
                + "host. ask()/runModal() are never called here -- only the window is built, the same "
                + "\"constructed but never shown\" boundary the pairing window below draws."
        )
    }

    // The launch window, in every state a person meets it in. Constructed but
    // never shown: `show()` is the only thing that orders it in front of
    // anyone, and nothing here calls it -- the same boundary the presence
    // prompt above draws.
    @MainActor
    func machinesWindow(
        hosts: [SavedHost] = [],
        pair: (@MainActor (ViewerPairingDevice?, ViewerPairingSubmission) async -> ViewerPairingResult)? = nil,
        tailscaleAppURLLookup: @escaping @MainActor () -> URL? = { nil },
        onOpenTailscaleApp: @escaping @MainActor (URL) -> Void = { _ in }
    ) -> YourMachinesWindowController {
        let controller = YourMachinesWindowController(
            store: InMemorySavedHostStore(hosts: hosts),
            tailscaleAppURLLookup: tailscaleAppURLLookup,
            onOpenTailscaleApp: onOpenTailscaleApp
        )
        controller.pair = pair
        return controller
    }

    @MainActor
    func machinesContent(_ controller: YourMachinesWindowController) -> NSView {
        guard let content = stored("window", of: controller, as: NSWindow.self).contentView else {
            fail("the Your machines window has no content view")
        }
        return content
    }

    let miniHost = SavedHost(
        displayName: "Mac mini",
        host: "mini.tail1234.ts.net",
        port: 7777,
        hostPublicKey: Data([1]),
        tlsCertificateHash: Data([1, 1]),
        lastConnectedAt: Date(timeIntervalSince1970: 9_000)
    )
    let studioHost = SavedHost(
        displayName: "Mac Studio",
        host: "studio.tail1234.ts.net",
        port: 7777,
        hostPublicKey: Data([2]),
        tlsCertificateHash: Data([2, 2]),
        lastConnectedAt: Date(timeIntervalSince1970: 1_000)
    )
    let tailnetRows = [
        TailnetDevicePickerRow(peer: TailnetPeer(
            id: "1", displayName: "Mac mini", magicDNSName: "mini.tail1234.ts.net",
            tailnetIPv4: "100.64.1.2", tailnetIPv6: nil, isOnline: true, isThisMachine: false
        )),
        TailnetDevicePickerRow(peer: TailnetPeer(
            id: "2", displayName: "Mac Studio", magicDNSName: "studio.tail1234.ts.net",
            tailnetIPv4: "100.64.1.7", tailnetIPv6: nil, isOnline: false, isThisMachine: false
        )),
        TailnetDevicePickerRow(peer: TailnetPeer(
            id: "3", displayName: "iPhone", magicDNSName: nil,
            tailnetIPv4: "100.64.1.3", tailnetIPv6: nil, isOnline: false, isThisMachine: false
        ))
    ]

    let noMachines = machinesWindow()
    write(
        render(machinesContent(noMachines)),
        named: "viewer-machines-1-empty.png",
        state: "YourMachinesWindowController with nothing paired yet — one sentence and the accent Add a machine;"
            + " 460pt wide at the height the content asks for; no stream pass"
    )

    // The online/offline note on a saved row comes from the same `tailscale
    // status` fetch the add step's own list does, so it is loaded here rather
    // than injected -- the fixture shows exactly what a real answer produces.
    let machinesList = machinesWindow(hosts: [miniHost, studioHost])
    machinesList.loadTailnet = { .devices(tailnetRows) }
    machinesList.showAddAMachine()
    pumpUntil(
        { stored("reachability", of: machinesList, as: [Data: Bool].self).isEmpty == false },
        description: "the tailnet answer behind the online/offline notes"
    )
    machinesList.showList()
    write(
        render(machinesContent(machinesList)),
        named: "viewer-machines-2-list.png",
        state: "YourMachinesWindowController listing two saved machines, most recently connected first, each with"
            + " the address it was paired at and what tailscale status says about it"
    )

    // The click, then the first attempt it starts -- the same two steps the
    // client makes, so the fixture shows what a real click produces.
    machinesList.connectRequested(hostPublicKey: miniHost.hostPublicKey)
    machinesList.connectStarted(hostPublicKey: miniHost.hostPublicKey)
    write(
        render(machinesContent(machinesList)),
        named: "viewer-machines-3-connecting.png",
        state: "YourMachinesWindowController while one row is dialling — that row says so in place of its"
            + " address and offers Cancel; every other row stays clickable"
    )

    machinesList.attemptFailed(reason: "no answer")
    write(
        render(machinesContent(machinesList)),
        named: "viewer-machines-4-failed.png",
        state: "YourMachinesWindowController after an attempt failed and the retry policy is about to dial"
            + " again — the row names the attempt and why it did not connect"
    )

    // The add step's first screen, and every state the tailnet answer can put
    // in it. Rows inside this same window, never a window of their own.
    // `tailscaleAppURLLookup` defaults to never finding the app, so every
    // state but the one built to show the Open Tailscale button renders the
    // same whether or not Tailscale is installed on the machine running this.
    let addStates: [(String, TailnetDevicePickerState, String)] = [
        (
            "viewer-add-1-picker",
            .devices(tailnetRows),
            "one online and two offline devices — every tailnet peer is listed, whether or not it is"
                + " running Sensorium, which the subtext says outright"
        ),
        ("viewer-add-1b-picker-loading", .loading, "while the fetch is in flight"),
        (
            "viewer-add-1c-picker-tailscaled-unreachable",
            .unreachable(reason: TailnetDevicePickerFetchError.tailscaledUnreachable.reason),
            "when tailscaled could not be asked at all — the reason, and the way on without it"
        ),
        (
            "viewer-add-1e-picker-tailscale-not-installed",
            .unreachable(reason: TailnetDevicePickerFetchError.tailscaleNotInstalled.reason),
            "when no candidate tailscale executable path exists at all — a different reason, and the"
                + " same way on"
        ),
        (
            "viewer-add-1f-picker-no-other-devices",
            .noOtherDevices,
            "for a tailnet with nothing else on it yet"
        )
    ]
    for (name, state, description) in addStates {
        let window = machinesWindow(hosts: [miniHost])
        window.apply(deviceList: state)
        write(
            render(machinesContent(window)),
            named: "\(name).png",
            state: "YourMachinesWindowController on the add step, \(description)"
        )
    }

    let tailscaleInstalled = machinesWindow(
        hosts: [miniHost],
        tailscaleAppURLLookup: { URL(fileURLWithPath: "/Applications/Tailscale.app") }
    )
    tailscaleInstalled.apply(
        deviceList: .unreachable(reason: TailnetDevicePickerFetchError.tailscaledUnreachable.reason)
    )
    write(
        render(machinesContent(tailscaleInstalled)),
        named: "viewer-add-1d-picker-tailscaled-unreachable-tailscale-installed.png",
        state: "YourMachinesWindowController on the add step when tailscaled could not be asked and Tailscale"
            + " is installed — the button that opens it is offered only then"
    )

    let codeStep = machinesWindow(hosts: [miniHost])
    codeStep.showCodeStep(for: ViewerPairingDevice(address: "mini.tail1234.ts.net", name: "Mac mini"))
    write(
        render(machinesContent(codeStep)),
        named: "viewer-add-2-code.png",
        state: "YourMachinesWindowController on the add step's second screen — the machine is already known, so"
            + " only the code is asked for, with the optional name below it"
    )

    let manualStep = machinesWindow(hosts: [miniHost])
    manualStep.showCodeStep(for: nil)
    write(
        render(machinesContent(manualStep)),
        named: "viewer-add-3-code-manual.png",
        state: "YourMachinesWindowController on the same screen reached by typing an address by hand — the"
            + " address field is added above the code, and nothing else moves"
    )

    /// Types into the real fields and hands the controller the same delegate
    /// callback the field editor gives it, which is what rebuilds the form and
    /// re-runs every validation message on screen. A field left out is left
    /// exactly as the step itself filled it.
    @MainActor
    func fill(
        _ controller: YourMachinesWindowController,
        address: String? = nil,
        code: String? = nil,
        name: String? = nil
    ) {
        if let address {
            stored("addressField", of: controller, as: NSTextField.self).stringValue = address
        }
        if let code {
            stored("codeField", of: controller, as: NSTextField.self).stringValue = code
        }
        if let name {
            stored("nameField", of: controller, as: NSTextField.self).stringValue = name
        }
        controller.controlTextDidChange(
            Notification(name: NSControl.textDidChangeNotification, object: nil)
        )
    }

    let refused = machinesWindow(hosts: [miniHost]) { _, _ in .failed(.refused(reason: "invalid-code")) }
    refused.showCodeStep(for: ViewerPairingDevice(address: "studio.tail1234.ts.net", name: "Mac Studio"))
    fill(refused, code: "418297")
    // `submit` is private, invoked the same way this script already drives
    // other windows' own actions: Objective-C dispatch, no window on screen.
    let submit = NSSelectorFromString("submit")
    guard refused.responds(to: submit) else {
        fail("YourMachinesWindowController does not answer -submit")
    }
    refused.perform(submit)
    pumpUntil(
        { stored("isPairing", of: refused, as: Bool.self) == false },
        description: "the pairing attempt to settle"
    )
    write(
        render(machinesContent(refused)),
        named: "viewer-add-4-pairing-failed.png",
        state: "YourMachinesWindowController after the other machine refused the code (wire reason invalid-code)"
            + " — ViewerPairingFailureCopy under the field, and the code kept for another try"
    )

    // The viewer's own screen for a key it cannot read: no user ever runs a
    // command, so this offers its fix instead of naming a CLI flag.
    // Constructed but never shown -- `run()` is the only thing that orders
    // it in front of anyone, and this preview never calls it.
    // Mirrors `Sources/Sensorium/main.swift`'s own branch: the
    // non-destructive "Try again" is the Return-key default, and making a
    // new key sits below it, since that is not something Return should ever
    // fire by accident.
    @MainActor
    func identityFailureContent(for failure: ViewerIdentityFailure) -> NSView {
        let copy = ViewerStartupFailureCopy.copy(for: failure)
        let controller = ViewerMessageWindowController(
            eyebrow: "CANNOT START",
            headline: copy.headline,
            detail: copy.detail + "\n\n" + copy.replaceConsequence,
            actionTitle: copy.retryButtonTitle,
            actionIsDefault: true,
            secondaryActionTitle: copy.replaceButtonTitle,
            dismissTitle: "Quit Sensorium"
        )
        guard let content = stored("window", of: controller, as: NSWindow.self).contentView else {
            fail("the identity-failure window has no content view")
        }
        return content
    }
    write(
        render(identityFailureContent(for: .unreadable(
            reason: "the stored key is malformed"
        ))),
        named: "viewer-identity-1-key-unreadable.png",
        state: "ViewerMessageWindowController for a key file this app cannot read -- the exact defect report"
            + " -- offering Try again, then Make a new key, instead of naming a CLI flag; no stream pass, it"
            + " never leaves the viewer's own machine"
    )

    // The viewer's window opens at half the canvas in points, which on a
    // Retina MacBook is one backing pixel per streamed pixel at 1.0x.
    let viewerSize = NSSize(
        width: CGFloat(canvas.logicalWidth) / 2,
        height: CGFloat(canvas.logicalHeight) / 2
    )
    // Every state here belongs to a session that has already had a picture in
    // it: a first dial is reported on the launch window's own row, and this
    // overlay is never on screen before then.
    var viewerStates: [(String, String, ViewerSessionStatus)] = []

    var machine = ViewerSessionStateMachine(hostName: "mac-mini")
    viewerStates.append(("viewer-status-1-connecting", "first connect, before any frame", machine.status))
    machine.handle(.connectStarted)

    // A first attempt that never answers before the retry policy dials
    // again: the connecting panel names which attempt failed and why.
    var failedFirstConnect = ViewerSessionStateMachine(hostName: "mac-mini")
    failedFirstConnect.handle(.connectStarted)
    let connectingAfterFailure = failedFirstConnect.handle(
        .attemptFailed(reasonLine: ViewerSessionFailureCopy.line(for: .unreachable, hostLabel: "mac-mini"))
    )
    viewerStates.append((
        "viewer-status-1b-connecting-after-failure",
        "first connect, one attempt already failed and not yet redialled",
        connectingAfterFailure
    ))

    machine.handle(.canvasReady)
    viewerStates.append((
        "viewer-status-2-lost",
        "session dropped, last frame frozen underneath",
        machine.handle(.sessionEnded)
    ))
    viewerStates.append((
        "viewer-status-3-reconnecting",
        "redialling after a drop",
        machine.handle(.connectStarted)
    ))
    viewerStates.append((
        "viewer-status-4-gave-up",
        "reconnection abandoned",
        machine.handle(.gaveUp)
    ))

    // The .ended phase: a host-screen connect that never became a session.
    // One overlay per reason HostScreenRefusalCopy names, plus the
    // unrecognised-reason fallback -- the same "render every named reason"
    // precedent the Displays-menu refusal banner set below.
    let hostScreenEndedReasons: [(String, String)] = [
        ("canvas-session-active", "canvas-session-active"),
        ("not-allowed", "host-screen-not-allowed"),
        ("presence-check-required", "host-screen-presence-check-required"),
        ("presence-declined", "host-screen-presence-declined"),
        ("presence-unanswered", "host-screen-presence-unanswered"),
        ("needs-rearming", "host-screen-needs-rearming"),
        ("credential-unknown", "host-screen-credential-unknown"),
        ("display-unavailable", "host-screen-display-unavailable"),
        ("retry-needs-person", "host-screen-retry-needs-person"),
        ("resume-refused", "host-screen-resume-refused"),
        ("session-active", "host-screen-session-active"),
        ("unrecognised-reason", "a-reason-this-build-has-never-seen")
    ]
    // "host-screen-retry-needs-person" and "host-screen-resume-refused" can
    // only be sent for a resume attempt, which only exists once a session
    // has already gone live -- unlike the other reasons here, which can
    // refuse the very first connect.
    let reasonsAfterALiveSession: Set<String> = [
        "host-screen-retry-needs-person",
        "host-screen-resume-refused"
    ]
    for (index, (slug, reason)) in hostScreenEndedReasons.enumerated() {
        var endedMachine = ViewerSessionStateMachine(hostName: "mac-mini")
        if reasonsAfterALiveSession.contains(reason) {
            endedMachine.handle(.connectStarted)
            endedMachine.handle(.canvasReady)
        }
        let status = endedMachine.handle(
            .hostScreenConnectEnded(
                reasonLine: HostScreenRefusalCopy.line(reason: reason),
                offersPairAgain: HostScreenRefusalCopy.offersPairAgain(reason: reason)
            )
        )
        viewerStates.append((
            "viewer-status-\(5 + index)-ended-\(slug)",
            "a host-screen connect that never became a session, reason \"\(reason)\"",
            status
        ))
    }

    // Every overlay above names the host in its headline (ux-spec's "Every
    // error names the machine by its name"), and the reason line never repeats
    // it; a long name is the wrap risk that check exists for, so one
    // long-name pass each for two reasons checks the shape most likely to
    // break.
    let longHostName = "Alexandria-Whitfield-Sinclairs-MacBook-Pro-16-inch-M4-Max"
    for (slug, reason) in [
        ("credential-unknown", "host-screen-credential-unknown"),
        ("not-allowed", "host-screen-not-allowed")
    ] {
        var endedMachine = ViewerSessionStateMachine(hostName: longHostName)
        let status = endedMachine.handle(
            .hostScreenConnectEnded(
                reasonLine: HostScreenRefusalCopy.line(reason: reason),
                offersPairAgain: HostScreenRefusalCopy.offersPairAgain(reason: reason)
            )
        )
        viewerStates.append((
            "viewer-status-14-ended-long-name-\(slug)",
            "a host-screen connect that never became a session, reason \"\(reason)\", long machine name to check wrap",
            status
        ))
    }

    // A certificate pin or host key mismatch stops the retry loop outright --
    // see ClientReconnectDriver's own no-auto-redial branch for it -- instead
    // of redialling forever.
    do {
        var unverifiedMachine = ViewerSessionStateMachine(hostName: "mac-mini")
        unverifiedMachine.handle(.connectStarted)
        let status = unverifiedMachine.handle(
            .unverifiedHostConnectEnded(
                reasonLine: ViewerSessionFailureCopy.line(for: .unverifiedHost, hostLabel: "mac-mini")
            )
        )
        viewerStates.append((
            "viewer-status-15-unverified-host",
            "a dial that stopped because the host did not prove it is the machine this one paired with",
            status
        ))
    }

    for (prefix, description, status) in viewerStates {
        let overlay = ViewerSessionStatusOverlay()
        overlay.frame = NSRect(origin: .zero, size: viewerSize)
        overlay.apply(status)
        let chrome = render(overlay)
        let frame = syntheticFrame(width: chrome.width, height: chrome.height)
        writePasses(
            composite(chrome, over: frame),
            prefix: prefix,
            state: "ViewerSessionStatusOverlay — \(description); \"\(status.headline)\""
                + "; frame underneath is synthetic"
        ) { _, scale in
            // Only the picture is streamed. The overlay is drawn locally by the
            // viewer and stays sharp however bad the stream is.
            composite(chrome, over: resampleThroughStream(frame, scale: scale, canvasScale: canvas.scale))
        }
    }

    // The HUD is chrome on the viewer's own machine, like the overlay above it, so
    // it gets one pass at the width it is pinned to and the height its rows
    // come to.
    var clientMetrics = SessionMetrics()
    for (stage, milliseconds) in [
        (SessionMetricStage.receive, 8.4),
        (.decode, 3.1),
        (.present, 1.7),
        (.endToEnd, 21.6)
    ] {
        clientMetrics.record(
            stage: stage,
            startedAtNanoseconds: 0,
            endedAtNanoseconds: Int64(milliseconds * 1_000_000)
        )
    }

    func hostSample(
        appliedStreamScale: Double?,
        sustainableScaleCeiling: Double?,
        clampedFromUserChoice: Double? = nil,
        framesPerSecond: Double = 59,
        appliedFramesPerSecond: Int? = nil,
        qualityScale: Double? = nil,
        fidelityLimitReason: String? = nil
    ) -> SurfaceTelemetrySample {
        SurfaceTelemetrySample(
            surfaceID: 0,
            capture: StageLatencySample(p50Nanoseconds: 4_100_000, p95Nanoseconds: 7_800_000),
            encode: StageLatencySample(p50Nanoseconds: 6_300_000, p95Nanoseconds: 11_200_000),
            send: StageLatencySample(p50Nanoseconds: 2_200_000, p95Nanoseconds: 5_400_000),
            framesPerSecond: framesPerSecond,
            encoderInputDropped: 0,
            globalAdmissionDropped: 0,
            sendQueueDropped: 0,
            appliedStreamScale: appliedStreamScale,
            sustainableScaleCeiling: sustainableScaleCeiling,
            clampedFromUserChoice: clampedFromUserChoice,
            appliedFramesPerSecond: appliedFramesPerSecond,
            qualityScale: qualityScale,
            fidelityLimitReason: fidelityLimitReason
        )
    }

    func streamReading(scale: Double?) -> ClientStreamReading {
        ClientStreamReading(
            pixelWidth: scale.map { Int(Double(canvas.logicalWidth) * $0) },
            pixelHeight: scale.map { Int(Double(canvas.logicalHeight) * $0) },
            bitsPerSecond: 41_800_000
        )
    }

    var liveMachine = ViewerSessionStateMachine(hostName: "Mac mini")
    liveMachine.handle(.connectStarted)
    let liveSession = liveMachine.handle(.canvasReady)

    // The address every fixture below dials, and the healthy fixture's own
    // trend history: 30 ticks, oldest first, so `viewer-hud-1-healthy.png`
    // shows all three sparklines rather than the two-sample minimum.
    let previewHostAddress = "mini.tail1234.ts.net:7777"
    let healthyEndToEndLatencyTrend = (0..<30).map { 20.0 + 3.0 * sin(Double($0) / 4.0) }
    let healthyVideoInBitrateTrend = (0..<30).map { 41_800_000.0 + 2_500_000.0 * sin(Double($0) / 5.0 + 1) }
    let healthyFpsTrend = (0..<30).map { 59.0 - 1.5 * sin(Double($0) / 6.0 + 2) }

    let hudStates: [(String, String, SessionHUDSnapshot)] = [
        (
            "viewer-hud-1-healthy",
            "live, hardware decode, and the host honouring the scale asked for",
            SessionHUDSnapshot(
                surfaceID: 0,
                availability: .fresh(hostSample(appliedStreamScale: 2.0, sustainableScaleCeiling: nil)),
                clientMetrics: clientMetrics,
                stream: streamReading(scale: 2.0),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                hostName: "Mac mini",
                hostAddress: previewHostAddress,
                endToEndLatencyTrend: SessionHUDTrend(samples: healthyEndToEndLatencyTrend),
                videoInBitrateTrend: SessionHUDTrend(samples: healthyVideoInBitrateTrend),
                fpsTrend: SessionHUDTrend(samples: healthyFpsTrend)
            )
        ),
        (
            "viewer-hud-2-held-below",
            "the host applying 1.50x against a 2.00x request, at its own measured ceiling",
            SessionHUDSnapshot(
                surfaceID: 0,
                availability: .fresh(hostSample(appliedStreamScale: 1.5, sustainableScaleCeiling: 1.5)),
                clientMetrics: clientMetrics,
                stream: streamReading(scale: 1.5),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                hostName: "Mac mini",
                hostAddress: previewHostAddress
            )
        ),
        (
            "viewer-hud-3-old-host",
            "a host that sends neither applied scale nor ceiling — unknown, not held below",
            SessionHUDSnapshot(
                surfaceID: 0,
                availability: .fresh(hostSample(appliedStreamScale: nil, sustainableScaleCeiling: nil)),
                clientMetrics: clientMetrics,
                stream: streamReading(scale: 2.0),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                hostName: "Mac mini",
                hostAddress: previewHostAddress
            )
        ),
        (
            "viewer-hud-4-stale",
            "the host stopped sending — every host-measured number is the last one it sent",
            SessionHUDSnapshot(
                surfaceID: 0,
                availability: .stale(hostSample(appliedStreamScale: 1.5, sustainableScaleCeiling: 1.5)),
                clientMetrics: clientMetrics,
                stream: streamReading(scale: 1.5),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                hostName: "Mac mini",
                hostAddress: previewHostAddress
            )
        ),
        (
            "viewer-hud-5-software-decoder",
            "no hardware decoder — this machine is decoding in software",
            SessionHUDSnapshot(
                surfaceID: 0,
                availability: .fresh(hostSample(appliedStreamScale: 2.0, sustainableScaleCeiling: nil)),
                clientMetrics: clientMetrics,
                stream: streamReading(scale: 2.0),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .softwareFallback,
                hostName: "Mac mini",
                hostAddress: previewHostAddress
            )
        ),
        (
            "viewer-hud-8-pointer-captured",
            "captured-pointer mode (Cmd-Shift-G) — the panel names the exit gesture, which was otherwise invisible",
            SessionHUDSnapshot(
                surfaceID: 0,
                availability: .fresh(hostSample(appliedStreamScale: 2.0, sustainableScaleCeiling: nil)),
                clientMetrics: clientMetrics,
                stream: streamReading(scale: 2.0),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                isPointerCaptured: true,
                hostName: "Mac mini",
                hostAddress: previewHostAddress
            )
        ),
        (
            "viewer-hud-10-fidelity-limited",
            "the link holding frame rate and encoder quality down as well as the scale, with the panel"
                + " naming which part of the path cannot keep up",
            SessionHUDSnapshot(
                surfaceID: 0,
                availability: .fresh(hostSample(
                    appliedStreamScale: 1.5,
                    sustainableScaleCeiling: 1.5,
                    framesPerSecond: 29.6,
                    appliedFramesPerSecond: 30,
                    qualityScale: 0.75,
                    fidelityLimitReason: FidelityLimitReason.link
                )),
                clientMetrics: clientMetrics,
                stream: streamReading(scale: 1.5),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                hostName: "Mac mini",
                hostAddress: previewHostAddress
            )
        ),
        (
            "viewer-hud-11-fidelity-limited-by-encoder",
            "the streaming machine's own encoder as the limit, named by that machine rather than as \"this machine\","
                + " which everywhere else on this panel means the machine the panel is drawn on",
            SessionHUDSnapshot(
                surfaceID: 0,
                availability: .fresh(hostSample(
                    appliedStreamScale: 1.5,
                    sustainableScaleCeiling: 1.5,
                    framesPerSecond: 44.2,
                    appliedFramesPerSecond: 45,
                    qualityScale: 1.0,
                    fidelityLimitReason: FidelityLimitReason.encoder
                )),
                clientMetrics: clientMetrics,
                stream: streamReading(scale: 1.5),
                requestedStreamScale: 2.0,
                streamScalePreference: .automatic,
                decoder: .hardwareAccelerated,
                hostName: "Mac mini",
                hostAddress: previewHostAddress
            )
        ),
        (
            "viewer-hud-9-fixed-choice-clamped",
            "a fixed 2.00x choice the host's own measured ceiling held back to 1.75x",
            SessionHUDSnapshot(
                surfaceID: 0,
                availability: .fresh(hostSample(
                    appliedStreamScale: 1.75,
                    sustainableScaleCeiling: 1.75,
                    clampedFromUserChoice: 2.0
                )),
                clientMetrics: clientMetrics,
                stream: streamReading(scale: 1.75),
                requestedStreamScale: 2.0,
                streamScalePreference: .fixed(2.0),
                decoder: .hardwareAccelerated,
                hostName: "Mac mini",
                hostAddress: previewHostAddress
            )
        )
    ]

    for (prefix, description, snapshot) in hudStates {
        let hud = SessionHUDView()
        hud.apply(session: liveSession)
        hud.apply(telemetry: snapshot)
        hud.layoutSubtreeIfNeeded()
        hud.frame = NSRect(origin: .zero, size: hud.fittingSize)
        write(
            render(hud),
            named: "\(prefix).png",
            state: "SessionHUDView — \(description); \(Int(SessionHUDView.panelWidth))pt wide at its own"
                + " fitting height; no stream pass, it is drawn on the viewer's machine"
        )
    }

    // Where it actually sits. `ClientCanvasWindowController` pins the panel to
    // the top-left of the canvas view with the same inset used here, and puts
    // the session-status overlay above it -- so a dropped session's buttons
    // are never behind a panel of numbers. Both are reproduced here rather
    // than asserted, because the real placement needs a window server.
    @MainActor
    func hudOverCanvas(status: ViewerSessionStatus?) -> CGImage {
        // The pin, resolved by Auto Layout exactly as the window controller
        // resolves it, so the offset below is measured rather than assumed.
        let container = NSView(frame: NSRect(origin: .zero, size: viewerSize))
        let pinned = SessionHUDView()
        pinned.apply(session: status ?? liveSession)
        pinned.apply(telemetry: hudStates[1].2)
        container.addSubview(pinned)
        NSLayoutConstraint.activate([
            pinned.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: ViewerDesign.Space.xs),
            pinned.topAnchor.constraint(equalTo: container.topAnchor, constant: ViewerDesign.Space.xs)
        ])
        container.layoutSubtreeIfNeeded()
        // Rendered on its own and placed, rather than cached as a subview:
        // `cacheDisplay` on a nested view does not composite it opaquely, and
        // a panel that looks translucent here when it is not in a window
        // would misrepresent it. Position and z-order are still the real
        // ones -- the pin is the same constraint pair the window controller
        // uses, read back off the laid-out frame.
        // The same status the overlay gets: the window hands both the one
        // state, so a preview that gave the HUD a live session behind a lost
        // one depicted a screen the product cannot produce.
        let hud = SessionHUDView()
        hud.apply(session: status ?? liveSession)
        hud.apply(telemetry: hudStates[1].2)
        hud.layoutSubtreeIfNeeded()
        hud.frame = NSRect(origin: .zero, size: hud.fittingSize)
        let panel = render(hud)
        // Backing pixels per point, read off the render rather than assumed.
        let scale = CGFloat(panel.width) / hud.frame.width
        let frame = syntheticFrame(
            width: Int(viewerSize.width * scale),
            height: Int(viewerSize.height * scale)
        )
        var canvas = place(panel, over: frame, in: CGRect(
            x: pinned.frame.minX * scale,
            y: pinned.frame.minY * scale,
            width: hud.frame.width * scale,
            height: hud.frame.height * scale
        ))
        if let status {
            let overlay = ViewerSessionStatusOverlay()
            overlay.frame = NSRect(origin: .zero, size: viewerSize)
            overlay.apply(status)
            canvas = composite(render(overlay), over: canvas)
        }
        return canvas
    }

    write(
        hudOverCanvas(status: nil),
        named: "viewer-hud-6-over-canvas.png",
        state: "SessionHUDView pinned to the canvas view's top-left corner, \(Int(ViewerDesign.Space.xs))pt in,"
            + " over a synthetic frame — a live session shows no status overlay"
    )
    var lostMachine = ViewerSessionStateMachine(hostName: "Mac mini")
    lostMachine.handle(.connectStarted)
    lostMachine.handle(.canvasReady)
    write(
        hudOverCanvas(status: lostMachine.handle(.gaveUp)),
        named: "viewer-hud-7-under-session-panel.png",
        state: "the same HUD with a lost session over it — the status panel and its buttons are above the"
            + " HUD, never behind it"
    )

    // ViewerTransientNoticeView: the banner a "Displays" increase refusal
    // shows, in every reason DisplayCountRefusalCopy names, plus the
    // fallback. Drawn on the viewer's
    // own machine, like the HUD above it, so it gets one pass and no stream
    // pass.
    let noticeStates: [(String, String, String)] = [
        (
            "viewer-notice-1-host-screen-active",
            "host-screen-session-active",
            "a host-screen session's own cap on a second display"
        ),
        (
            "viewer-notice-2-exceeds-host-limit",
            "display-count-exceeds-host-limit",
            "the operator's own cap on how many displays this connection may open"
        ),
        (
            "viewer-notice-3-creation-in-progress",
            CanvasRefusalReason.creationInProgress,
            "the single-flight creation gate, busy with another request"
        ),
        (
            "viewer-notice-4-change-failed",
            "display-count-change-failed",
            "a setup failure outside the creation gate"
        ),
        (
            "viewer-notice-5-unrecognised-reason",
            "a-reason-this-build-has-never-seen",
            "a reason this build has never seen, quoted verbatim rather than translated"
        )
    ]
    for (prefix, reason, description) in noticeStates {
        let notice = ViewerTransientNoticeView()
        notice.show(DisplayCountRefusalCopy.line(reason: reason, hostLabel: "mac-mini"))
        notice.layoutSubtreeIfNeeded()
        notice.frame = NSRect(origin: .zero, size: notice.fittingSize)
        write(
            render(notice),
            named: "\(prefix).png",
            state: "ViewerTransientNoticeView — \(description); shown as a banner over the canvas, drawn on"
                + " the viewer's own machine; no stream pass"
        )
    }

    // ShortcutStripView: the row of system shortcuts across the top of the
    // session window, in the three states it has -- closed, with only the
    // handle that opens it; open, with its buttons; and the one question Lock
    // Screen asks first. Reached through the real methods a person's own
    // pointer, chord and click go through, never by setting state directly.
    // Pinned across the top edge by the same three constraints the window
    // controller uses, over a synthetic frame. Drawn on the viewer's own
    // machine, like the HUD and the banner above it, so it gets one pass and
    // no stream pass.
    @MainActor
    func stripOverCanvas(open: Bool, confirming: ShortcutStripAction?, pinned: Bool = false) -> CGImage {
        let container = NSView(frame: NSRect(origin: .zero, size: viewerSize))
        let strip = pinned
            ? ShortcutStripView(hostName: "Mac mini", pinMemoryStore: InMemoryShortcutStripPinMemoryStore(isPinned: true))
            : ShortcutStripView(hostName: "Mac mini")
        container.addSubview(strip)
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            strip.topAnchor.constraint(equalTo: container.topAnchor)
        ])
        strip.phaseChanged(.live)
        if open, !pinned {
            strip.toggleRequested()
        }
        if let confirming {
            strip.press(confirming)
        }
        container.layoutSubtreeIfNeeded()
        // Rendered on its own and placed, for the reason `hudOverCanvas`
        // gives: `cacheDisplay` on a nested view does not composite it
        // opaquely. The position is the laid-out one, read back off the
        // frame rather than assumed.
        let bar = render(strip)
        let scale = CGFloat(bar.width) / strip.frame.width
        let frame = syntheticFrame(
            width: Int(viewerSize.width * scale),
            height: Int(viewerSize.height * scale)
        )
        return place(bar, over: frame, in: CGRect(
            x: strip.frame.minX * scale,
            y: strip.frame.minY * scale,
            width: strip.frame.width * scale,
            height: strip.frame.height * scale
        ))
    }

    write(
        stripOverCanvas(open: false, confirming: nil),
        named: "viewer-shortcuts-0-handle.png",
        state: "ShortcutStripView closed, which is how a live session leaves it — the handle at the top"
            + " centre is the whole of what sits over the picture until it is hovered or clicked"
    )
    write(
        stripOverCanvas(open: true, confirming: nil),
        named: "viewer-shortcuts-1-shown.png",
        state: "the same strip opened from that handle — every shortcut this machine would otherwise take"
            + " for itself, sent to the machine being worked on"
    )
    write(
        stripOverCanvas(open: true, confirming: nil, pinned: true),
        named: "viewer-shortcuts-1b-pinned.png",
        state: "the same strip pinned open — the hover handle pill above it is gone, since pinning already"
            + " found the strip without it"
    )
    write(
        stripOverCanvas(open: true, confirming: .lockScreen),
        named: "viewer-shortcuts-2-confirming-lock.png",
        state: "the same strip after Lock Screen was pressed — the row is replaced by the one question a"
            + " disruptive shortcut asks before it fires"
    )
}

// MARK: - index.txt

let formatter = ISO8601DateFormatter()
var lines = [
    "Sensorium UI previews — \(formatter.string(from: Date()))",
    "",
    "Rendered offscreen from the production view types in Sources/ by",
    "Scripts/render-ui-previews.swift. No window, no display, no capture.",
    "",
    "Fonts resolved during this run:"
]
lines += fontNotes
lines += [
    "",
    "Canvas: \(canvas.logicalWidth)x\(canvas.logicalHeight) logical at scale \(canvas.scale)"
        + " (VirtualCanvasConfiguration.remoteDefault).",
    "Passes per view:",
    "  natural      the view as drawn, at the renderer's backing scale.",
    "  stream1.0x   resampled down to a \(canvas.logicalWidth)x\(canvas.logicalHeight) stream and back up.",
    "  stream1.5x   resampled down to a \(canvas.logicalWidth * 2 / 3)x\(canvas.logicalHeight * 2 / 3) stream"
        + " and back up (what the Mac mini settles at under load).",
    "  Resampling only — no H.264 quantisation, no motion, no bitrate. Real",
    "  streamed text is at best this legible, never better.",
    "  For the viewer overlay only the frame underneath is resampled, because",
    "  the overlay is drawn locally and never crosses the wire.",
    "",
    "Three surfaces have one pass and no stream passes at all: the host's menu-",
    "bar panel, the viewer's pairing window and the viewer's session HUD. All",
    "three are drawn on the screen of the machine the person is sitting at and never",
    "cross the wire, so a downscale would be a lie about them. Each is rendered",
    "at the size it really appears at -- 288pt wide for the panel, 460pt for the",
    "window, 320pt for the HUD, each at the height its own content asks for --",
    "because a small panel blown up to canvas size flatters type nobody ever",
    "sees that big. The pairing window's images are its content view; the title",
    "bar around it is macOS's, not ours.",
    "",
    "The Displays-menu refusal banner (ViewerTransientNoticeView) gets the same",
    "one-pass, no-stream-pass treatment for the same reason -- it is drawn on",
    "the viewer's own machine -- but at its own fitting size, which is not fixed:",
    "it grows and wraps with the sentence it shows.",
    "",
    "non-bg is the fraction of pixels that differ from the most common colour:",
    "the check that the file is a picture and not one flat rectangle.",
    "",
    "Caveats, so nothing here is read for more than it is:",
    "  The launcher's selected row is drawn in its inactive treatment (grey fill,",
    "  not the accent) in every launcher image but image 7. Nothing here has a",
    "  window, so nothing can be first responder, and the view only marks the",
    "  list active when the query field actually takes the keyboard. Image 7",
    "  forces it by calling the delegate method AppKit calls at that moment.",
    "  The viewer's connecting overlay is opaque by design, so its stream passes",
    "  are byte-identical to the natural one: there is no picture underneath yet.",
    "",
    "Not covered by this run:",
    "  CanvasSurfaceView — draws nothing of its own; its picture is a Metal layer.",
    "  AnimatedMeasurementContentView — measurement pattern, not session UI.",
    "  The View menu's captured-pointer title, its Clipboard item's checked state,",
    "  the Display menu's resolution picker, the Displays menu's count picker, and",
    "  the Screen menu's virtual/host-screen picker — NSMenu has no offscreen",
    "  cacheDisplay path the way NSView does, so none of these is a PNG here. Their",
    "  content is ViewerMenuPlan.pointerCaptureTitle, ClipboardSharingToggle,",
    "  DisplayScaleMenuPlan, DisplayCountMenuPlan, and ScreenMenuPlan, all pure and",
    "  covered by SensoriumClientTestRunner.",
    "",
    pad("FILE", 46) + padLeft("BYTES", 10) + "  " + pad("PIXELS", 11) + padLeft("NON-BG", 7)
        + padLeft("COLOURS", 9) + "  STATE"
]
for entry in index {
    lines.append(
        pad(entry.file, 46) + padLeft("\(entry.bytes)", 10) + "  " + pad(entry.pixels, 11)
            + padLeft(String(format: "%.3f", entry.report.nonBackgroundFraction), 7)
            + padLeft("\(entry.report.distinctColors)", 9) + "  " + entry.state
    )
}

do {
    try lines.joined(separator: "\n").appending("\n")
        .write(to: outputDirectory.appendingPathComponent("index.txt"), atomically: true, encoding: .utf8)
} catch {
    fail("could not write index.txt: \(error)")
}

print("\n\(index.count) PNGs and index.txt in \(outputDirectory.path)")
guard blanks.isEmpty else {
    fail("blank or near-blank output: \(blanks.joined(separator: ", "))")
}

#else

// MARK: - Bootstrap: build the package, then recompile this file against it

let repositoryRoot = URL(
    fileURLWithPath: #filePath,
    relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
).standardizedFileURL.deletingLastPathComponent().deletingLastPathComponent()

func run(_ launchPath: String, _ arguments: [String], failureMessage: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [launchPath] + arguments
    process.currentDirectoryURL = repositoryRoot
    do {
        try process.run()
    } catch {
        FileHandle.standardError.write(Data("render-ui-previews: \(launchPath): \(error)\n".utf8))
        exit(1)
    }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        FileHandle.standardError.write(Data("render-ui-previews: \(failureMessage)\n".utf8))
        exit(process.terminationStatus)
    }
}

let build = repositoryRoot.appendingPathComponent(".build/debug")

/// SwiftPM leaves the object files of deleted and renamed sources behind, and
/// linking those duplicates every symbol they define. Only objects that still
/// have a source file are taken.
func objects(target: String, sourceExtension: String, objectSuffix: String) -> [String] {
    let sources = repositoryRoot.appendingPathComponent("Sources/\(target)")
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: sources.path)) ?? [])
        .filter { $0.hasSuffix(sourceExtension) }
        .sorted()
    let found = names.compactMap { name -> String? in
        let object = build.appendingPathComponent("\(target).build/\(name)\(objectSuffix)").path
        return FileManager.default.fileExists(atPath: object) ? object : nil
    }
    if found.isEmpty {
        FileHandle.standardError.write(Data("render-ui-previews: no built objects for \(target)\n".utf8))
        exit(1)
    }
    return found
}

// The two library targets only. Building the whole package would also build
// every executable target, and a preview run has no reason to fail because an
// executable target elsewhere in the package does not compile.
for target in ["SensoriumHost", "SensoriumClient"] {
    print("render-ui-previews: building \(target)…")
    run("swift", ["build", "--target", target], failureMessage: "swift build --target \(target) failed")
}

let moduleMap = build.appendingPathComponent("SensoriumVirtualDisplayBridge.build/module.modulemap").path
guard FileManager.default.fileExists(atPath: moduleMap) else {
    FileHandle.standardError.write(Data("render-ui-previews: no module map at \(moduleMap)\n".utf8))
    exit(1)
}

let binary = FileManager.default.temporaryDirectory
    .appendingPathComponent("sensorium-render-ui-previews").path
var compile = [
    "-o", binary,
    // The views are internal to their modules; only a testable import reaches
    // the real types, and reaching the real types is the whole point.
    "-I", build.appendingPathComponent("Modules").path,
    "-Xcc", "-fmodule-map-file=\(moduleMap)",
    URL(fileURLWithPath: #filePath, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .standardizedFileURL.path
]
for target in ["SensoriumCore", "SensoriumHost", "SensoriumClient"] {
    compile += objects(target: target, sourceExtension: ".swift", objectSuffix: ".o")
}
compile += objects(target: "SensoriumVirtualDisplayBridge", sourceExtension: ".m", objectSuffix: ".o")

print("render-ui-previews: compiling the renderer…")
run("swiftc", compile, failureMessage: "compiling the renderer failed")
run(binary, Array(CommandLine.arguments.dropFirst()), failureMessage: "rendering failed")

#endif

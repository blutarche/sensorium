import AppKit
import SensoriumCore
import CoreGraphics
import Foundation

// Opt-in benchmark load: draws a bouncing block on the session-owned virtual
// canvas so ScreenCaptureKit has motion to deliver. Refuses to run anywhere
// but a 1920×1200 non-builtin display — it must never draw on a physical
// workstation screen.
//
//   usage: SensoriumCanvasExerciser <displayID> <seconds>
@MainActor
final class PatternView: NSView {
    var blockOrigin = CGPoint.zero

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        NSColor.white.setFill()
        NSRect(x: blockOrigin.x, y: blockOrigin.y, width: 240, height: 240).fill()
    }
}

let arguments = CommandLine.arguments
guard arguments.count == 3,
      let displayID = UInt32(arguments[1]),
      let seconds = Double(arguments[2]),
      seconds > 0, seconds <= 120 else {
    print("usage: SensoriumCanvasExerciser <displayID> <seconds 1-120>")
    exit(2)
}
setvbuf(stdout, nil, _IOLBF, 0)

let bounds = CGDisplayBounds(displayID)
guard CGDisplayIsBuiltin(displayID) == 0,
      Int(bounds.width) == 1920,
      Int(bounds.height) == 1200 else {
    print("refusing: display \(displayID) is not a 1920x1200 non-builtin canvas (bounds \(bounds))")
    exit(2)
}

let phase = TestPatternPhase(
    canvasWidth: 1920,
    canvasHeight: 1200,
    blockWidth: 240,
    blockHeight: 240,
    speedPointsPerSecond: 900
)

let window = NSWindow(
    contentRect: bounds,
    styleMask: [.borderless],
    backing: .buffered,
    defer: false
)
window.setFrame(bounds, display: true)
window.level = .normal
let view = PatternView(frame: NSRect(origin: .zero, size: bounds.size))
window.contentView = view
window.makeKeyAndOrderFront(nil)
print("exerciser drawing on display \(displayID) for \(seconds)s")

let startedAt = Date()
let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { _ in
    MainActor.assumeIsolated {
        let elapsed = Date().timeIntervalSince(startedAt)
        if elapsed >= seconds {
            print("exerciser finished after \(String(format: "%.1f", elapsed))s")
            exit(0)
        }
        let position = phase.position(atSeconds: elapsed)
        view.blockOrigin = CGPoint(x: position.x, y: position.y)
        view.needsDisplay = true
    }
}
RunLoop.main.add(timer, forMode: .common)
RunLoop.main.run()

import Foundation
import SensoriumHost

func mark(_ text: String) {
    print(text)
    fflush(stdout)
}

enum PreflightError: Error, CustomStringConvertible {
    case explicitOptInRequired
    case insufficientBaseline(Int)
    case virtualOnlySmokeRequiresOneReadableDisplay
    case unexpectedDisplayCount(Int)
    case unexpectedDisplayDimensions(Int, Int)
    case unexpectedLogicalDimensions(Int, Int)
    case unexpectedBackingMetrics(Int, Int, Int)
    case physicalTopologyChanged
    case noPhysicalDisplayEvidence(Int)
    case displaysLeftOnlineAfterRelease([UInt32])

    var description: String {
        switch self {
        case .explicitOptInRequired:
            return "refusing: pass --run or --virtual-only-smoke for the explicit opt-in preflight"
        case .insufficientBaseline(let count):
            return "refusing: baseline has \(count) active display(s); restore and verify the physical workstation first"
        case .virtualOnlySmokeRequiresOneReadableDisplay:
            return "refusing: virtual-only smoke mode requires exactly one 1920x1200 external display baseline"
        case .unexpectedDisplayCount(let count):
            return "expected one new display, observed \(count) new display(s)"
        case .unexpectedDisplayDimensions(let width, let height):
            return "new display dimensions were \(width)x\(height), expected 3840x2400 backing pixels"
        case .unexpectedLogicalDimensions(let width, let height):
            return "new display logical dimensions were \(width)x\(height), expected 1920x1200"
        case .unexpectedBackingMetrics(let width, let height, let scale):
            return "virtual display backing metrics were \(width)x\(height) scale \(scale), expected 3840x2400 scale 2"
        case .noPhysicalDisplayEvidence(let active):
            guard active > 0 else {
                return "refusing: no active displays at all; an empty baseline cannot prove physical preservation"
            }
            return "refusing: every active display carries Sensorium's own canvas vendor ID (0x434C). A baseline with no display this host did not create cannot prove physical preservation"
        case .physicalTopologyChanged:
            return "physical display IDs or modes changed during preflight"
        case .displaysLeftOnlineAfterRelease(let ids):
            let named = ids.map { "display \($0)" }.joined(separator: ", ")
            return "the canvas it created is still online after release: \(named)"
        }
    }
}

func require(_ condition: @autoclosure () -> Bool, _ error: PreflightError) throws {
    guard condition() else { throw error }
}

/// Kept for the life of the process: a signal source that is released stops
/// delivering.
@MainActor
private var terminationSignalSources: [any DispatchSourceSignal] = []

/// Without this, `Ctrl-C` during the preflight kills the process where it
/// stands and leaves the virtual display it just created online, with no
/// owner and no way to remove it, until the machine restarts -- exactly the
/// leak `CanvasShutdown` exists to prevent in the real host.
@MainActor
private func installTerminationSignalHandlers(canvasShutdown: CanvasShutdown) {
    for number in [SIGINT, SIGTERM] {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated {
                canvasShutdown.releaseEverything()
            }
            Foundation.exit(0)
        }
        source.resume()
        terminationSignalSources.append(source)
    }
}

func stableTopology(_ displays: [DisplaySnapshot]) -> [UInt32: String] {
    Dictionary(uniqueKeysWithValues: displays.map { display in
        (
            display.id,
            "\(display.pixelWidth)x\(display.pixelHeight)@\(display.bounds.origin.x),\(display.bounds.origin.y),\(display.bounds.size.width),\(display.bounds.size.height)|\(display.online)|\(display.builtin)|\(display.main)"
        )
    })
}

@main
struct SensoriumVirtualDisplayPreflight {
    static func main() async {
        do {
            try await run()
            print("PASS: virtual display created, observed, released, and physical baseline preserved")
        } catch {
            print("PREFLIGHT BLOCKED: \(error)")
            Foundation.exit(2)
        }
    }

    @MainActor
    private static func run() async throws {
        mark("preflight: start")
        let arguments = Set(CommandLine.arguments)
        try require(arguments.contains("--run") || arguments.contains("--virtual-only-smoke"), .explicitOptInRequired)

        mark("preflight: baseline")
        let baseline = DisplayInventory.active()
        let onlineBaseline = DisplayInventory.online()
        mark("baseline topology: \(stableTopology(baseline))")
        mark("baseline active IDs: \(baseline.map { $0.id }.sorted())")
        mark("baseline online IDs: \(onlineBaseline.map { $0.id }.sorted())")
        let virtualOnlySmoke = arguments.contains("--virtual-only-smoke")
        if virtualOnlySmoke {
            try require(
                baseline.count == 1 && baseline[0].pixelWidth == 1920 && baseline[0].pixelHeight == 1200 && !baseline[0].builtin,
                .virtualOnlySmokeRequiresOneReadableDisplay
            )
        } else {
            let evidence = PhysicalDisplayEvidence(displays: baseline)
            try require(evidence.hasPhysicalDisplay, .noPhysicalDisplayEvidence(baseline.count))
            try require(evidence.isPreservationTestable, .insufficientBaseline(baseline.count))
        }
        mark("preflight: session")
        let baselineByID = Dictionary(uniqueKeysWithValues: baseline.map { ($0.id, $0) })

        let canvasShutdown = CanvasShutdown()
        installTerminationSignalHandlers(canvasShutdown: canvasShutdown)
        let adapter = CoreGraphicsVirtualDisplayAdapter(
            surface: CanvasSurfaceID.allCases[0],
            shutdown: canvasShutdown,
            log: mark
        )
        let session = VirtualDisplaySession(adapter: adapter)
        mark("preflight: start session")
        do {
            let handle = try session.start(owner: CanvasOwnerToken(), configuration: .remoteDefault)
            let during = DisplayInventory.active()
            let newDisplays = during.filter { baselineByID[$0.id] == nil }
            try require(newDisplays.count == 1, .unexpectedDisplayCount(newDisplays.count))
            if let display = newDisplays.first {
                try require(
                    display.pixelWidth == 1920 && display.pixelHeight == 1200,
                    .unexpectedLogicalDimensions(display.pixelWidth, display.pixelHeight)
                )
            }
            let metrics = try adapter.metrics(for: handle)
            try require(
                metrics.maxPixelsWide == 3840 && metrics.maxPixelsHigh == 2400 && metrics.hiDPIScale == 2,
                .unexpectedBackingMetrics(metrics.maxPixelsWide, metrics.maxPixelsHigh, metrics.hiDPIScale)
            )
            session.stop()
        } catch {
            session.stop()
            throw error
        }

        let onlineBaselineIDs = Set(onlineBaseline.map { $0.id })
        var final = DisplayInventory.active()
        var finalOnline = DisplayInventory.online()
        for _ in 0..<50
        where stableTopology(final) != stableTopology(baseline)
            || Set(finalOnline.map { $0.id }) != onlineBaselineIDs {
            try? await Task.sleep(for: .milliseconds(100))
            final = DisplayInventory.active()
            finalOnline = DisplayInventory.online()
        }
        mark("final topology: \(stableTopology(final))")
        mark("final active IDs: \(final.map { $0.id }.sorted())")
        mark("final online IDs: \(finalOnline.map { $0.id }.sorted())")
        try require(stableTopology(final) == stableTopology(baseline), .physicalTopologyChanged)

        let leakedOnline = DisplayInventory.newlyOnlineIDs(baseline: onlineBaseline, current: finalOnline)
        try require(leakedOnline.isEmpty, .displaysLeftOnlineAfterRelease(leakedOnline))
    }
}
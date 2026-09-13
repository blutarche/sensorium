import Foundation
import SensoriumCore
import SensoriumHost

/// The host side of `viewerTelemetry`: accepted, gated like every other
/// post-authentication message, kept per surface, and acted on by nothing
/// yet. What reads it is a separate change; storing it is what makes that
/// change possible without the host having to guess at the far end.
@MainActor
func runViewerTelemetryReceiptTests() async {
    let surfaceZero = CanvasSurfaceID.allCases[0]
    let surfaceOne = CanvasSurfaceID.allCases[1]

    func reading(surfaceID: UInt32, presentedFramesPerSecond: Double) -> ViewerTelemetrySample {
        ViewerTelemetrySample(
            surfaceID: surfaceID,
            endToEnd: StageLatencySample(p50Nanoseconds: 21_000_000, p95Nanoseconds: 34_000_000),
            receive: StageLatencySample(p50Nanoseconds: 8_000_000, p95Nanoseconds: 15_000_000),
            decode: StageLatencySample(p50Nanoseconds: 3_000_000, p95Nanoseconds: 5_000_000),
            presentedFramesPerSecond: presentedFramesPerSecond,
            decodedFramesPerSecond: 59.9,
            receivedBitsPerSecond: 41_800_000
        )
    }

    // Gated exactly like `viewerFocus` and `streamScalePreference`: this is
    // evidence the host will steer its own encoder by, so an unauthenticated
    // peer never gets to supply it.
    let unauthenticated = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        requireAuthentication: true,
        keyConfinement: .unconfined
    )
    expectThrows(
        HostSessionControllerError.authenticationRequired,
        { _ = try unauthenticated.handle(.viewerTelemetry(reading(surfaceID: 0, presentedFramesPerSecond: 59))) },
        "an unauthenticated peer cannot tell this host what its own link looks like"
    )

    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        keyConfinement: .unconfined
    )
    let now = Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000
    expect(
        controller.latestViewerTelemetry(for: surfaceZero, atSeconds: now) == nil,
        "a session no viewer has reported on yet holds no reading at all"
    )

    let first = reading(surfaceID: 0, presentedFramesPerSecond: 59)
    expect(
        try! controller.handle(.viewerTelemetry(first)) == nil,
        "a viewer's reading is accepted and answered with nothing -- it is not a request"
    )
    let afterFirst = Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000
    expect(
        controller.latestViewerTelemetry(for: surfaceZero, atSeconds: afterFirst) == first,
        "the reading the viewer sent is the reading this host holds for that surface"
    )
    expect(
        controller.latestViewerTelemetry(for: surfaceOne, atSeconds: afterFirst) == nil,
        "one surface's reading is never handed back for the other"
    )

    let second = reading(surfaceID: 1, presentedFramesPerSecond: 28)
    _ = try! controller.handle(.viewerTelemetry(second))
    let afterSecond = Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000
    expect(
        controller.latestViewerTelemetry(for: surfaceOne, atSeconds: afterSecond) == second
            && controller.latestViewerTelemetry(for: surfaceZero, atSeconds: afterSecond) == first,
        "each surface keeps its own latest reading"
    )

    // A surfaceID outside the wire's cap: dropped, not fatal. Unlike a
    // routing key, a measurement grants nothing and steers nothing on its
    // own, so there is nothing here worth ending an authenticated session
    // over.
    var outOfRangeSurvived = true
    do {
        _ = try controller.handle(.viewerTelemetry(reading(surfaceID: 99, presentedFramesPerSecond: 1)))
    } catch {
        outOfRangeSurvived = false
    }
    expect(
        outOfRangeSurvived,
        "a reading naming a surface this session cannot have is survivable, not a dropped session"
    )
    let afterOutOfRange = Double(MonotonicClock.nowNanoseconds()) / 1_000_000_000
    expect(
        controller.latestViewerTelemetry(for: surfaceZero, atSeconds: afterOutOfRange) == first,
        "an out-of-range reading displaces nothing that was already held"
    )

    print("PASS: a viewer's own reading is accepted, gated and kept per surface")
}

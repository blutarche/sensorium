#if os(Linux)
import Foundation
import SensoriumLinuxHost

/// With no compositor to reach, the host learns at launch that it cannot
/// show the indicator, and so offers no host screen.
private func testTheProbeReportsNoDisplayWhenNoCompositorAnswers() throws {
    let problem = LayerShellSupport.probe(displayName: "sensorium-no-such-display-\(UUID().uuidString)")
    guard case .noDisplay? = problem else {
        throw CheckFailure("an unreachable compositor reads as no display, saw \(String(describing: problem))")
    }
}

func layerShellProbeTests() -> [(String, () throws -> Void)] { [
    ("the indicator probe reports no display when no compositor answers", testTheProbeReportsNoDisplayWhenNoCompositorAnswers)
] }
#endif

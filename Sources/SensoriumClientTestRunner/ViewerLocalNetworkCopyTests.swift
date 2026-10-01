import Foundation
import SensoriumClient

/// A host that answers only over Tailscale is silent to a viewer dialling a
/// .local name, so the copy for an unreachable machine names the host
/// setting that changes that.
func testViewerLocalNetworkCopyTests() {
    let line = ViewerSessionFailureCopy.line(for: .unreachable, hostLabel: "Studio")
    expect(
        line.contains(".local") && line.contains("\u{201C}Allow connections from this network\u{201D}"),
        "an unreachable machine's copy names the host setting for a .local name, got: \(line)"
    )
    expect(
        line.contains("Sensorium Host is running"),
        "and still says what to go check first, got: \(line)"
    )
    print("PASS: an unreachable machine's copy names the host setting a .local name needs")
}

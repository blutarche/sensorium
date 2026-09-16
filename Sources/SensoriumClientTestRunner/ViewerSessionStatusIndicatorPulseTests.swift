import Foundation
import SensoriumClient
import SensoriumCore

/// `indicatorPulses` says which states the overlay's tone dot pulses for --
/// only the two states where an attempt is actually under way, so waiting
/// reads as active work and every settled state (`live`, `lost`, `ended`)
/// reads as still.
func testViewerSessionStatusIndicatorPulseTests() {
    var machine = ViewerSessionStateMachine(hostName: "Studio")
    expect(machine.status.indicatorPulses, "connecting pulses, got \(machine.status.phase)")

    machine.handle(.canvasReady)
    expect(!machine.status.indicatorPulses, "live does not pulse, got \(machine.status.phase)")

    machine.handle(.sessionEnded)
    expect(!machine.status.indicatorPulses, "lost does not pulse, got \(machine.status.phase)")

    machine.handle(.retryRequested)
    expect(machine.status.indicatorPulses, "reconnecting pulses, got \(machine.status.phase)")

    machine.handle(.stopRequested)
    expect(!machine.status.indicatorPulses, "stopped does not pulse, got \(machine.status.phase)")

    print("PASS: the overlay's tone dot pulses only while connecting or reconnecting")
}

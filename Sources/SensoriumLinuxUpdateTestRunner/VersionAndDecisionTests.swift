import Foundation
import SensoriumLinuxUpdate

func testVersionsParseStrictlyAndCompareNumerically() {
    let version = LinuxUpdateVersion("0.10.2")
    expect(version?.major == 0 && version?.minor == 10 && version?.patch == 2, "0.10.2 parses into its three parts")
    expect(version?.description == "0.10.2", "a version prints the way it was written")
    for bad in ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.02.3", "1.2.03", "1..3", "1.2.", ".1.2", "1.2.x", "+1.2.3", "-1.2.3", "1.2.3 ", " 1.2.3", "1.2.3-beta", "1234567890.0.0", "١.٢.٣"] {
        expect(LinuxUpdateVersion(bad) == nil, "\"\(bad)\" is not a release version")
    }
    expect(LinuxUpdateVersion("0.0.0") != nil, "zero parts are allowed when written as a single 0")
    expect(LinuxUpdateVersion("0.9.0")! < LinuxUpdateVersion("0.10.0")!, "versions compare numerically, not as text")
    expect(LinuxUpdateVersion("1.0.0")! > LinuxUpdateVersion("0.99.99")!, "the major part decides first")
    expect(LinuxUpdateVersion("0.5.14")! == LinuxUpdateVersion("0.5.14")!, "equal versions are equal")
}

func testDecisionTableFirstMatchingRowDecides() {
    let running = LinuxUpdateVersion("0.5.0")!
    func decide(_ offered: String, highest: String?) -> LinuxUpdateDecision {
        LinuxUpdateDecision.decide(
            offered: LinuxUpdateVersion(offered)!,
            running: running,
            highestSeen: highest.map { LinuxUpdateVersion($0)! }
        )
    }
    expect(decide("0.6.0", highest: nil) == .update, "a newer release is an update")
    expect(decide("0.5.0", highest: nil) == .upToDate, "the running version is up to date")
    expect(decide("0.5.0", highest: "0.5.0") == .upToDate, "the running version is up to date when it is also the highest seen")
    expect(
        decide("0.5.1", highest: "0.6.0") == .wentBackwards(highestSeen: LinuxUpdateVersion("0.6.0")!),
        "a version below the highest seen is a failed check, even when it is newer than the running one"
    )
    expect(
        decide("0.4.0", highest: "0.5.0") == .wentBackwards(highestSeen: LinuxUpdateVersion("0.5.0")!),
        "an older release below the highest seen is a failed check"
    )
    expect(decide("0.4.0", highest: nil) == .upToDate, "an older release that matches no row installs nothing")
    expect(decide("0.6.0", highest: "0.6.0") == .update, "the highest seen offered again is still an update")
}

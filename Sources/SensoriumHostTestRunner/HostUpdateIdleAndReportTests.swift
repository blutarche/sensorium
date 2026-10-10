import Foundation
import SensoriumHost
import SensoriumUpdate

/// The host installs only while it is listening with no session live, no
/// pairing approved or under way, and no pairing code on screen.
func runHostUpdateIdleRuleTests() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
    func status(_ connection: HostConnectionState, pairing: HostPairingState = .idle) -> HostOperatorStatus {
        HostOperatorStatus(connection: connection, pairing: pairing, permissions: granted)
    }

    expect(
        HostUpdateIdleRule.isIdle(status(.hosting(address: "100.64.1.2")), now: now),
        "listening with nobody connected is idle"
    )
    expect(
        !HostUpdateIdleRule.isIdle(status(.serving(peerName: "Kestrel Laptop")), now: now),
        "a session on a virtual display is live"
    )
    expect(
        !HostUpdateIdleRule.isIdle(
            status(.servingHostScreen(peerName: "Kestrel Laptop", displayLabel: "Built-in Display")),
            now: now
        ),
        "a host-screen session is live"
    )
    expect(
        !HostUpdateIdleRule.isIdle(status(.pairingApproved(deviceName: "Kestrel Laptop")), now: now),
        "an approved pairing still finishing its connection is a pairing in progress"
    )
    expect(
        !HostUpdateIdleRule.isIdle(status(.notHosting), now: now),
        "a host that is not listening cannot hand over to a version that reports ready once it listens"
    )
    expect(
        !HostUpdateIdleRule.isIdle(
            status(.hosting(address: "100.64.1.2"), pairing: .showing(code: "418297", expiresAt: now.addingTimeInterval(60))),
            now: now
        ),
        "a pairing code on screen is a pairing in progress"
    )
    expect(
        !HostUpdateIdleRule.isIdle(
            status(
                .hosting(address: "100.64.1.2"),
                pairing: .showing(code: "418297", expiresAt: now.addingTimeInterval(60), requestingDeviceName: "Kestrel Laptop")
            ),
            now: now
        ),
        "a code a machine has asked for is a pairing in progress"
    )
    expect(
        HostUpdateIdleRule.isIdle(
            status(.hosting(address: "100.64.1.2"), pairing: .showing(code: "418297", expiresAt: now.addingTimeInterval(-1))),
            now: now
        ),
        "an expired code is no longer on screen, so it holds nothing up"
    )
    print("PASS: the idle rule holds only while listening, with no session, pairing or code on screen")

    var watch = HostUpdateIdleWatch()
    expect(!watch.observe(status(.notHosting), now: now), "not listening yet is not an ending")
    expect(watch.observe(status(.hosting(address: "100.64.1.2")), now: now), "starting to listen makes the host idle")
    expect(!watch.observe(status(.hosting(address: "100.64.1.2")), now: now), "staying idle reports nothing new")
    expect(!watch.observe(status(.serving(peerName: "Kestrel Laptop")), now: now), "a session starting is not idle")
    expect(
        !watch.observe(status(.serving(peerName: "Kestrel Laptop")), now: now),
        "a ping tick during the session reports nothing"
    )
    expect(watch.observe(status(.hosting(address: "100.64.1.2")), now: now), "the session ending makes the host idle")
    expect(
        !watch.observe(
            status(.hosting(address: "100.64.1.2"), pairing: .showing(code: "418297", expiresAt: now.addingTimeInterval(60))),
            now: now
        ),
        "a code shown is not idle"
    )
    expect(watch.observe(status(.hosting(address: "100.64.1.2")), now: now), "the code hidden makes the host idle")
    expect(!watch.observe(status(.pairingApproved(deviceName: "Kestrel Laptop")), now: now), "an approval is not idle")
    expect(watch.observe(status(.hosting(address: "100.64.1.2")), now: now), "the pairing finishing makes the host idle")

    let hostingStatus = status(.hosting(address: "100.64.1.2"))
    let expiry = now.addingTimeInterval(60)
    let showingStatus = status(.hosting(address: "100.64.1.2"), pairing: .showing(code: "418297", expiresAt: expiry))
    expect(
        HostUpdateIdleWatch.recheckDate(for: showingStatus, now: now) == expiry,
        "a code showing with a future expiry is looked at again when it expires"
    )
    expect(
        HostUpdateIdleWatch.recheckDate(for: showingStatus, now: expiry) == nil,
        "an expired code needs no later look"
    )
    expect(HostUpdateIdleWatch.recheckDate(for: hostingStatus, now: now) == nil, "no code needs no later look")
    expect(
        HostUpdateIdleWatch.recheckDate(for: status(.serving(peerName: "Kestrel Laptop")), now: now) == nil,
        "a live session needs no later look"
    )
    var expiryWatch = HostUpdateIdleWatch()
    expect(!expiryWatch.observe(showingStatus, now: now), "a code showing is not idle")
    expect(
        expiryWatch.observe(showingStatus, now: expiry.addingTimeInterval(1)),
        "the same status after the code expires reports the host idle"
    )
    print("PASS: the idle watch reports each moment a session or pairing ends, and nothing else")
}

/// The old version's baseline and the new version's ready report are built
/// by the same function from the same sources, so an unchanged host reports
/// identical values.
func runHostUpdateReadyReportTests() {
    let version = UpdateVersion("0.4.0")!
    let certificateHash = Data((0..<32).map { UInt8($0) })
    let firstKey = Data(repeating: 0xA1, count: 32)
    let secondKey = Data(repeating: 0x07, count: 32)
    let listening = HostListeningValues(
        tailnetAddress: "100.64.1.2",
        port: 7777,
        interfaceName: "utun4",
        allowsLocalNetwork: false
    )
    let permissions = HostPermissionRequestResult(screenCapture: .granted, accessibility: .approvalRequired)

    func report(keys: Set<Data>, listening: HostListeningValues = listening) -> UpdateReadyReport {
        HostUpdateReadyReport.make(
            version: version,
            permissions: permissions,
            loginItemStatus: UpdateReadyReport.LoginItemStatus.enabled,
            certificateHash: certificateHash,
            approvedDeviceKeys: keys,
            listening: listening
        )
    }

    let baseline = report(keys: [firstKey, secondKey])
    let again = report(keys: [secondKey, firstKey])
    expect(baseline == again, "two reports from the same state are identical")
    expect(
        again.mismatch(comparedWith: baseline, expectedVersion: version) == nil,
        "the installer accepts a report built from the same state as its baseline"
    )
    print("PASS: two reports built from the same state are identical and accepted")

    expect(baseline.version == version, "the report names the running version")
    expect(baseline.screenRecordingGranted == true, "Screen Recording is read from the gate")
    expect(baseline.accessibilityGranted == false, "Accessibility is read from the gate")
    expect(baseline.loginItemStatus == UpdateReadyReport.LoginItemStatus.enabled, "the login item status is carried")
    expect(
        baseline.host?.identityFingerprint == "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f",
        "the identity fingerprint is the TLS certificate hash in lowercase hex, got \(baseline.host?.identityFingerprint ?? "nil")"
    )
    expect(baseline.host?.tailnetAddress == "100.64.1.2", "the address the listener serves on is carried")
    expect(baseline.host?.port == 7777, "the port is carried")
    expect(baseline.host?.interfaceName == "utun4", "the interface is carried")
    expect(baseline.host?.allowsLocalNetwork == false, "the local network setting is carried")
    print("PASS: the report carries every value the handoff compares")

    expect(
        HostUpdateReadyReport.pairedMachinesDigest([])
            == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        "no paired machine is the SHA-256 of nothing"
    )
    let added = report(keys: [firstKey, secondKey, Data(repeating: 0x55, count: 32)])
    expect(
        added.host?.pairedMachinesDigest != baseline.host?.pairedMachinesDigest,
        "pairing one more machine changes the paired machines digest"
    )
    expect(
        added.mismatch(comparedWith: baseline, expectedVersion: version) == "host",
        "the installer refuses a report whose paired machines differ"
    )
    expect(
        report(keys: [firstKey]).host?.pairedMachinesDigest != baseline.host?.pairedMachinesDigest,
        "removing a machine changes the digest too"
    )
    print("PASS: a paired machine added or removed changes the report, and the installer refuses it")

    let opened = report(
        keys: [firstKey, secondKey],
        listening: HostListeningValues(tailnetAddress: "100.64.1.2", port: 7777, interfaceName: nil, allowsLocalNetwork: true)
    )
    expect(
        opened.mismatch(comparedWith: baseline, expectedVersion: version) == "host",
        "a version listening on every interface instead of the tailnet's is refused"
    )
    print("PASS: a change in how the host listens is refused")

    expect(
        HostListeningValues.current(
            tailnetAddress: "100.64.1.2",
            port: 7777,
            allowsLocalNetwork: false,
            interfaceName: { address in address == "100.64.1.2" ? "utun4" : nil }
        ) == listening,
        "scoped to the tailnet, the interface is the one that owns the address"
    )
    var looked = false
    expect(
        HostListeningValues.current(
            tailnetAddress: "100.64.1.2",
            port: 7777,
            allowsLocalNetwork: true,
            interfaceName: { _ in looked = true; return "utun4" }
        ).interfaceName == nil,
        "with the local network allowed the listener is on every interface, so none is named"
    )
    expect(!looked, "no interface is looked up for an unscoped listener")
    print("PASS: the listening values name the interface only when the listener is scoped to one")
}

#if os(Linux)
import Foundation
import SensoriumClient
import SensoriumCore
import SensoriumHost
import SensoriumLinuxHost
import SensoriumLinuxUpdate

private func hex(_ data: Data) -> String {
    data.map { String(format: "%02x", $0) }.joined()
}

@MainActor
private func testTheHostReportsHowItServesAndWhenItIsIdle() async {
    let rig = RuntimeRig()
    expect(rig.runtime.servingValues() == nil, "a host that has not started serves nothing")
    expect(!rig.runtime.isIdleForUpdate(), "and is not idle")
    await rig.start()
    do {
        let tls = try FileHostTLSIdentityStore(
            url: rig.folder.appendingPathComponent(LinuxHostDataFiles.tlsIdentity), commonName: "Sensorium Host"
        ).loadOrCreate()
        let device = try FileDeviceIdentityStore(url: rig.folder.appendingPathComponent(LinuxHostDataFiles.deviceIdentity)).loadOrCreate()
        guard let alone = rig.runtime.servingValues() else {
            return expect(false, "a listening host says how it serves")
        }
        expect(alone.tlsCertificateFingerprint == hex(tls.certificateHash), "it names the certificate viewers pin")
        expect(alone.deviceIdentityFingerprint == hex(device.publicKey), "and the key pairing signs with")
        expect(alone.listenAddress == "127.0.0.1" && alone.port == rig.port, "and where it listens, saw \(alone)")
        expect(alone.screenSharingAllowed, "and that screen sharing is allowed")
        expect(rig.runtime.isIdleForUpdate(), "a listening host with nobody connected is idle")

        let now = Date()
        rig.runtime.showPairingCode()
        expect(!rig.runtime.isIdleForUpdate(now: now), "a pairing code on screen holds an update back")
        guard case let .showing(_, expiresAt, _) = rig.runtime.state.pairing else {
            return expect(false, "the code is showing")
        }
        expect(rig.runtime.updateIdleRecheckDate(now: now) == expiresAt, "until it expires")
        expect(rig.runtime.isIdleForUpdate(now: expiresAt.addingTimeInterval(1)), "after which it holds nothing up")
        rig.runtime.hidePairingCode()
        expect(rig.runtime.isIdleForUpdate(now: now), "nor does a hidden code")
        expect(rig.runtime.updateIdleRecheckDate(now: now) == nil, "and there is nothing to wait for")

        let viewer = try await rig.pairViewer(named: "Kestrel Laptop")
        let paired = rig.runtime.servingValues()
        expect(paired?.pairedMachinesDigest != alone.pairedMachinesDigest, "a new paired machine changes the digest")

        var changes = 0
        rig.runtime.onActivityChange = { changes += 1 }
        await expectEventually("the pairing connection has closed") { rig.runtime.isIdleForUpdate() }
        let link = try await connectViewer(viewer, port: rig.port)
        await expectEventually("a connected viewer holds an update back") { !rig.runtime.isIdleForUpdate() }
        let suspended = await rig.runtime.suspendForUpdate()
        expect(suspended == nil, "a busy host does not stop serving for an update")
        expect(rig.runtime.servingValues() != nil, "and keeps listening")
        let before = changes
        await link.connection.close()
        await expectEventually("a host whose last viewer left is idle again") { rig.runtime.isIdleForUpdate() }
        expect(changes > before, "and says its activity changed")
    } catch {
        expect(false, "the host's serving values were read, threw \(error)")
    }
    await rig.finish()
}

@MainActor
private func testAnIdleHostStopsServingForAnUpdateAndResumesIfItFails() async {
    let rig = RuntimeRig()
    await rig.start()
    do {
        let viewer = try await rig.pairViewer(named: "Kestrel Laptop")
        await expectEventually("the pairing connection has closed") { rig.runtime.isIdleForUpdate() }
        let serving = rig.runtime.servingValues()
        let oldPort = rig.port
        let baseline = await rig.runtime.suspendForUpdate()
        expect(baseline != nil && baseline == serving, "an idle host stops serving and says how it served, saw \(String(describing: baseline))")
        expect(rig.runtime.servingValues() == nil, "it no longer listens")
        expect(!rig.runtime.isIdleForUpdate(), "and is not idle while it hands over")
        expect(rig.runtime.state.grant == .needed, "and has closed its screen-sharing grant for the new version to open")
        let refused: Bool
        do {
            _ = try await connectViewer(viewer, port: oldPort, timeout: 2)
            refused = false
        } catch {
            refused = true
        }
        expect(refused, "a viewer that dials during the handover is refused")

        await rig.runtime.resumeAfterUpdate()
        await expectEventually("the grant is restored") { rig.runtime.state.grant == .allowed && rig.runtime.offersHostScreen }
        expect(rig.opener.interactiveOpenCount == 0, "without a dialog")
        guard let resumed = rig.runtime.servingValues(), let baseline else {
            return expect(false, "a resumed host serves again")
        }
        expect(
            resumed.tlsCertificateFingerprint == baseline.tlsCertificateFingerprint
                && resumed.deviceIdentityFingerprint == baseline.deviceIdentityFingerprint
                && resumed.pairedMachinesDigest == baseline.pairedMachinesDigest
                && resumed.listenAddress == baseline.listenAddress,
            "with the same identities, paired machines and address"
        )
        let link = try await connectViewer(viewer, port: rig.port)
        let outcome = try await link.client.connect(deviceName: viewer.name, target: .offeredHostScreen(preferredDisplayIdentity: nil))
        guard case .hostScreen = outcome else {
            return expect(false, "the paired viewer reaches the host screen again, got \(outcome)")
        }
        await link.client.disconnect()
    } catch {
        expect(false, "the handover's stop and resume ran, threw \(error)")
    }
    await rig.finish()
}

@MainActor
private func testAnUpdateRelaunchLeavesTheScreenAsItWas() async {
    // Idle for longer than the session is old reads as an automatic login.
    let launched = RuntimeRig(sessionAge: 60)
    launched.activity.set(idleSeconds: 3_600)
    await launched.start()
    expect(launched.relocker.relockCount == 1, "a launch into an untouched session locks the screen")
    await launched.finish()

    let relaunched = RuntimeRig(sessionAge: 60)
    relaunched.activity.set(idleSeconds: 3_600)
    await relaunched.start(isUpdateRelaunch: true)
    expect(relaunched.relocker.relockCount == 0, "a relaunch for an update does not")
    await relaunched.finish()
}

func hostUpdateRuntimeTests() -> [NamedTest] { [
    ("the host reports how it serves and when it is idle", testTheHostReportsHowItServesAndWhenItIsIdle),
    ("an idle host stops serving for an update and resumes if it fails", testAnIdleHostStopsServingForAnUpdateAndResumesIfItFails),
    ("an update relaunch leaves the screen as it was", testAnUpdateRelaunchLeavesTheScreenAsItWas)
] }
#endif

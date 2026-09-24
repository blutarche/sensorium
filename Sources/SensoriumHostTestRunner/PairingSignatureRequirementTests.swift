import Foundation
import SensoriumCore
import SensoriumHost

/// A pairing code proves only that someone read six digits off this host.
/// The request's own signature is what proves the machine sending it holds
/// the identity key it asks this host to write, and it is required: nothing
/// pairs, and so nothing is armed for host screen, without one.
@MainActor
func runPairingSignatureRequirementTests() async {
    do {
        let hostIdentity = try! DeviceIdentity.generate()
        let device = try! DeviceIdentity.generate()
        let approvedStore = InMemoryApprovedDeviceStore()
        let pairing = HostPairingService(hostIdentity: hostIdentity, approvedStore: approvedStore)
        pairing.issueCode(code: "424242")

        // Signed, but over a request asking for something else: the same
        // machine, the same code, a different name. Refused before the code
        // is looked at at all.
        let liftedSignature = try! device.sign(SensoriumFrameCodec.pairRequestTranscript(
            deviceName: "Another Laptop",
            clientPublicKey: device.publicKey,
            code: "424242"
        ))
        let lifted = pairing.handlePairRequest(
            deviceName: "Kestrel Laptop Pro",
            publicKey: device.publicKey,
            code: "424242",
            signature: liftedSignature
        )
        expect(
            lifted == .pairRejected(reason: "invalid-request"),
            "a pairing request whose proof does not cover it is rejected -- got \(lifted)"
        )
        expect(
            !pairing.isApproved(device.publicKey) && approvedStore.load().isEmpty,
            "a request that failed to prove possession approves nothing"
        )

        let signature = try! device.sign(SensoriumFrameCodec.pairRequestTranscript(
            deviceName: "Kestrel Laptop Pro",
            clientPublicKey: device.publicKey,
            code: "424242"
        ))
        let approved = pairing.handlePairRequest(
            deviceName: "Kestrel Laptop Pro",
            publicKey: device.publicKey,
            code: "424242",
            signature: signature
        )
        guard case .pairApproved = approved else {
            expect(false, "the same code still pairs for a request that proves possession -- got \(approved)")
            return
        }
        expect(
            pairing.isApproved(device.publicKey)
                && approvedStore.name(for: device.publicKey) == "Kestrel Laptop Pro",
            "a proven request pairs the machine and records the name it gave"
        )

        print("PASS: a pairing request whose proof does not cover it is rejected before the code is spent, and a proven one still pairs")
    }

    do {
        // On the wire the same rule ends the connection rather than merely
        // refusing: a request carrying a signature it cannot back up is
        // exactly what an authenticated hello with an unverifiable
        // signature is, and is treated the same way.
        let hostIdentity = try! DeviceIdentity.generate()
        let device = try! DeviceIdentity.generate()
        let pairing = HostPairingService(hostIdentity: hostIdentity)
        pairing.issueCode(code: "135790")
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            pairing: pairing,
            keyConfinement: .unconfined
        )
        let wrongKeySignature = try! DeviceIdentity.generate().sign(
            SensoriumFrameCodec.pairRequestTranscript(
                deviceName: "Kestrel Laptop Pro",
                clientPublicKey: device.publicKey,
                code: "135790"
            )
        )
        expectThrows(
            HostSessionControllerError.invalidAuthentication,
            {
                _ = try controller.handle(.pairRequest(
                    deviceName: "Kestrel Laptop Pro",
                    publicKey: device.publicKey,
                    code: "135790",
                    signature: wrongKeySignature
                ))
            },
            "a pairRequest signed by a key other than the one it names ends the connection"
        )
        expect(
            !pairing.isApproved(device.publicKey),
            "and approves nothing, so the code it carried is still there for the machine that really holds the key"
        )

        print("PASS: a pairRequest whose signature does not verify against the key it names ends the connection and approves nothing")
    }
}

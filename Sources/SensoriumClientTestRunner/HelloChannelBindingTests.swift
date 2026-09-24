import Foundation
import SensoriumClient
import SensoriumCore

/// The viewer already pins the host's TLS certificate when it dials. The
/// hello it then sends says which certificate that was, and signs it: a host
/// that receives this hello cannot present it to a second host the same
/// viewer is armed on, because the second host's certificate is a different
/// one and the signature covers the first.
@MainActor
func testAuthenticatedHelloNamesThePinnedCertificate() async {
    let identity = try! DeviceIdentity.generate()
    let pin = Data(repeating: 0xA5, count: 32)
    let transport = ScriptedClientTransport(
        responses: [
            .hostScreenRefused(reason: "host-screen-not-allowed"),
            .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
        ],
        pinnedHostCertificateHash: pin
    )
    let controller = ClientSessionController(transport: transport, identity: identity)
    _ = try! await controller.connect(deviceName: "Laptop")

    guard case let .authenticatedHello(version, name, publicKey, certificateHash, signature)? =
            await transport.sent.first else {
        print("FAIL: the viewer sent no authenticated hello at all")
        Foundation.exit(1)
    }
    guard certificateHash == pin else {
        print("FAIL: the hello named \(String(describing: certificateHash)) instead of the certificate the viewer pinned")
        Foundation.exit(1)
    }
    guard DeviceIdentity.verify(
        signature: signature,
        message: SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: version,
            deviceName: name,
            publicKey: publicKey,
            hostCertificateHash: pin
        ),
        publicKey: identity.publicKey
    ) else {
        print("FAIL: the hello's signature does not cover the certificate the viewer pinned")
        Foundation.exit(1)
    }

    // A link with nothing pinned -- the one-time pairing dial -- says so
    // rather than inventing a certificate, and signs that instead.
    let unpinnedTransport = ScriptedClientTransport(responses: [
        .hostScreenRefused(reason: "host-screen-not-allowed"),
        .canvasReady(displayID: 42, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil, surfaceID: nil)
    ])
    let unpinnedController = ClientSessionController(transport: unpinnedTransport, identity: identity)
    _ = try! await unpinnedController.connect(deviceName: "Laptop")
    guard case let .authenticatedHello(_, _, _, unpinnedHash, unpinnedSignature)? =
            await unpinnedTransport.sent.first,
          unpinnedHash == nil,
          DeviceIdentity.verify(
            signature: unpinnedSignature,
            message: SensoriumFrameCodec.authenticatedHelloTranscript(
                protocolVersion: 1,
                deviceName: "Laptop",
                publicKey: identity.publicKey,
                hostCertificateHash: nil
            ),
            publicKey: identity.publicKey
          ) else {
        print("FAIL: a hello over a link with no pinned certificate did not say so and sign it")
        Foundation.exit(1)
    }

    print("PASS: the viewer's hello names and signs the host certificate it pinned for that link")
}

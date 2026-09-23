import Foundation
import SensoriumCore
import SensoriumHost

/// A hello proves the viewer holds its key. On its own it does not say which
/// host it was meant for, and a host a viewer once paired with could present
/// the hello it received to any other host that viewer is armed on. Binding
/// the host's own TLS certificate into the signed transcript is what makes a
/// hello worth exactly one host.
@MainActor
func runHelloChannelBindingHostTests() async {
    let ownCertificateHash = Data(repeating: 0xA5, count: 32)
    let otherHostCertificateHash = Data(repeating: 0x5A, count: 32)
    let device = try! DeviceIdentity.generate()

    func controller(hostCertificateHash: Data?) -> HostSessionController {
        HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [device.publicKey],
            requireAuthentication: true,
            keyConfinement: .unconfined,
            hostCertificateHash: hostCertificateHash
        )
    }

    func hello(namingCertificate certificateHash: Data?) -> SensoriumMessage {
        .authenticatedHello(
            protocolVersion: 1,
            deviceName: "Kestrel Laptop Pro",
            publicKey: device.publicKey,
            hostCertificateHash: certificateHash,
            signature: try! device.sign(SensoriumFrameCodec.authenticatedHelloTranscript(
                protocolVersion: 1,
                deviceName: "Kestrel Laptop Pro",
                publicKey: device.publicKey,
                hostCertificateHash: certificateHash
            ))
        )
    }

    do {
        expectThrows(
            HostSessionControllerError.invalidAuthentication,
            { _ = try controller(hostCertificateHash: ownCertificateHash).handle(hello(namingCertificate: otherHostCertificateHash)) },
            "a hello signed for another host's certificate is refused here, however well it verifies"
        )
        expectThrows(
            HostSessionControllerError.invalidAuthentication,
            { _ = try controller(hostCertificateHash: ownCertificateHash).handle(hello(namingCertificate: nil)) },
            "a hello that names no certificate at all is refused by a host that has one"
        )
        func admits(_ hostCertificateHash: Data?, _ hello: SensoriumMessage) -> Bool {
            do {
                _ = try controller(hostCertificateHash: hostCertificateHash).handle(hello)
                return true
            } catch {
                return false
            }
        }
        expect(
            admits(ownCertificateHash, hello(namingCertificate: ownCertificateHash)),
            "a hello naming this host's own certificate is accepted"
        )

        // A link with no certificate -- a plain TCP connection -- expects a
        // hello that says exactly that, and nothing else.
        expect(
            admits(nil, hello(namingCertificate: nil)),
            "a host with no certificate accepts the hello that names none"
        )
        expectThrows(
            HostSessionControllerError.invalidAuthentication,
            { _ = try controller(hostCertificateHash: nil).handle(hello(namingCertificate: ownCertificateHash)) },
            "and refuses one claiming a certificate it does not have"
        )

        print("PASS: an authenticated hello is admitted only by the host whose own certificate it names and signs")
    }
}

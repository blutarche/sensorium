import CryptoKit
import Foundation
import SensoriumClient
import SensoriumCore

/// Always throws -- stands in for a machine that cannot register a presence
/// credential (design §6.3's "may not register for host screen" case)
/// without ever constructing `SecureEnclavePresenceCredential`, which this
/// file must never do; see that type's own doc comment.
private final class FailingPresenceCredentialProviding: PresenceCredentialProviding, @unchecked Sendable {
    let strength = PresenceCredentialStrength.hardwareBound
    private(set) var registerCallCount = 0

    func register() async throws -> PresenceCredentialRegistration {
        registerCallCount += 1
        throw PresenceCredentialRegistrationError.noSecureEnclave
    }

    func sign(challenge: Data) async throws -> Data {
        throw PresenceCredentialRegistrationError.noSecureEnclave
    }
}

private func temporaryPresenceCredentialRecordURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-presence-credential-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("presence-credential.json")
}

/// Checks the one `pairRequest` a pairing sends: its four values, and the
/// proof of possession the host needs before it will replace what an
/// already-paired machine has on file. The signature is verified rather
/// than compared byte for byte -- what matters is that it verifies against
/// this machine's own identity key over this exact request.
@MainActor
private func expectPairRequest(
    _ sent: [SensoriumMessage],
    deviceName: String,
    identity: DeviceIdentity,
    code: String,
    presenceCredential: PresenceCredentialRegistration?,
    _ message: String
) {
    guard sent.count == 1,
          case let .pairRequest(sentName, sentKey, sentCode, sentCredential, sentSignature) = sent[0] else {
        expect(false, "\(message) -- got \(sent)")
        return
    }
    expect(
        sentName == deviceName && sentKey == identity.publicKey && sentCode == code && sentCredential == presenceCredential,
        message
    )
    guard let sentSignature else {
        expect(false, "the pairRequest carries a proof that this machine holds the identity key it names")
        return
    }
    expect(
        DeviceIdentity.verify(
            signature: sentSignature,
            message: SensoriumFrameCodec.pairRequestTranscript(
                deviceName: deviceName,
                clientPublicKey: identity.publicKey,
                code: code,
                presenceCredential: presenceCredential
            ),
            publicKey: identity.publicKey
        ),
        "the proof verifies against this machine's own identity key over the exact request it sent"
    )
}

@MainActor
func testPresenceCredentialTests() async {
    do {
        // register -> sign -> verify, the whole round trip a
        // software credential can prove without touching CryptoKit's
        // SecureEnclave namespace at all.
        let credential = SoftwarePresenceCredential()
        let registration = try! await credential.register()
        let challenge = Data("session-challenge".utf8)
        let signature = try! await credential.sign(challenge: challenge)

        // The same routine `PresenceCredentialVerifier.supportedCredentialFormat`
        // pins (Sources/SensoriumHost/PresenceCredentialVerifier.swift): raw
        // P-256 ECDSA over the raw challenge bytes. This runner cannot import
        // SensoriumHost (Package.swift gives it only SensoriumClient), so the
        // verification itself is done directly against CryptoKit here rather
        // than through the real verifier.
        let publicKey = try! P256.Signing.PublicKey(rawRepresentation: registration.publicKey)
        let ecdsaSignature = try! P256.Signing.ECDSASignature(rawRepresentation: signature)

        expect(
            registration.credentialFormat == "apple-secure-enclave-p256",
            "a software credential reports the one format the host verifier checks -- the format names the routine, not the strength"
        )
        expect(registration.strength == "softwarePresence", "an in-memory key never claims the hardware-bound tier")
        expect(
            publicKey.isValidSignature(ecdsaSignature, for: challenge),
            "the signature register() and sign() produce together verifies against the registered public key, exactly as PresenceCredentialVerifier checks it"
        )
        expect(
            !publicKey.isValidSignature(ecdsaSignature, for: Data("a different challenge".utf8)),
            "the same signature does not verify against a challenge it was never made for"
        )

        print("PASS: a software credential's register-sign round trip verifies with the same P-256 ECDSA routine the host's PresenceCredentialVerifier uses")
    }

    do {
        // A device with no way to register still pairs -- design
        // §6.3: "Pairing itself never requires a credential."
        let identity = try! DeviceIdentity.generate()
        let hostIdentity = try! DeviceIdentity.generate()
        let signature = try! hostIdentity.sign(SensoriumFrameCodec.pairApprovalTranscript(
            deviceName: "MacBook",
            clientPublicKey: identity.publicKey,
            tlsCertificateHash: nil
        ))
        let transport = ScriptedClientTransport(responses: [
            .pairApproved(hostPublicKey: hostIdentity.publicKey, tlsCertificateHash: nil, signature: signature)
        ])
        let failingProvider = FailingPresenceCredentialProviding()
        let controller = ClientSessionController(
            transport: transport,
            identity: identity,
            credentialProvider: failingProvider
        )

        let approval = try! await controller.pair(deviceName: "MacBook", code: "424242")

        guard case .failed = approval.presenceCredentialRegistration else {
            expect(false, "a provider that throws must resolve to .failed, never .notOffered or .registered")
            return
        }
        expect(failingProvider.registerCallCount == 1, "pair() attempts registration exactly once per pairing")
        expectPairRequest(
            await transport.sent,
            deviceName: "MacBook",
            identity: identity,
            code: "424242",
            presenceCredential: nil,
            "a failed registration sends no presenceCredential at all on the wire -- not an empty or placeholder one"
        )

        print("PASS: a registration failure never fails pairing, and sends pairRequest with no presence credential")
    }

    do {
        // A device that can register includes the result on the wire.
        let identity = try! DeviceIdentity.generate()
        let hostIdentity = try! DeviceIdentity.generate()
        let signature = try! hostIdentity.sign(SensoriumFrameCodec.pairApprovalTranscript(
            deviceName: "MacBook",
            clientPublicKey: identity.publicKey,
            tlsCertificateHash: nil
        ))
        let transport = ScriptedClientTransport(responses: [
            .pairApproved(hostPublicKey: hostIdentity.publicKey, tlsCertificateHash: nil, signature: signature)
        ])
        let softwareCredential = SoftwarePresenceCredential()
        let expectedRegistration = try! await softwareCredential.register()
        let controller = ClientSessionController(
            transport: transport,
            identity: identity,
            credentialProvider: softwareCredential
        )

        let approval = try! await controller.pair(deviceName: "MacBook", code: "424242")

        expect(
            approval.presenceCredentialRegistration == .registered(expectedRegistration),
            "a successful registration reaches PairingApproval unchanged"
        )
        expectPairRequest(
            await transport.sent,
            deviceName: "MacBook",
            identity: identity,
            code: "424242",
            presenceCredential: expectedRegistration,
            "the registered credential is included on the pairRequest that goes out"
        )

        print("PASS: a successful registration is included in the pairRequest and reported back on PairingApproval")
    }

    do {
        // A persisted record reloads unchanged, so a re-pair can
        // reuse it instead of registering fresh.
        let url = temporaryPresenceCredentialRecordURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let record = PersistedPresenceCredential(
            credentialID: Data([0x01, 0x02, 0x03]),
            publicKey: Data([0x04, 0x05, 0x06]),
            credentialFormat: "apple-secure-enclave-p256",
            strength: "hardwareBound"
        )
        PresenceCredentialRecordStore(url: url).save(record)

        // A second, independent store instance at the same URL -- the shape
        // a fresh launch's re-pair actually constructs, not the same Swift
        // value handed back to itself.
        let reloaded = PresenceCredentialRecordStore(url: url).load()
        expect(reloaded == record, "a store pointed at the same file reloads exactly what was saved")

        print("PASS: a persisted presence credential record reloads unchanged from a fresh store instance")
    }

    do {
        // The private key's own wrapped blob lives beside the record
        // it belongs to, so a viewer that is rebuilt and relaunched
        // from a new location still offers the key it registered.
        let url = temporaryPresenceCredentialRecordURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let blob = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let record = PersistedPresenceCredential(
            credentialID: Data([0x01, 0x02, 0x03]),
            publicKey: Data([0x04, 0x05, 0x06]),
            credentialFormat: "apple-secure-enclave-p256",
            strength: "hardwareBound",
            wrappedPrivateKey: blob
        )
        PresenceCredentialRecordStore(url: url).save(record)

        let reloaded = PresenceCredentialRecordStore(url: url).load()
        expect(
            reloaded?.wrappedPrivateKey == blob,
            "the wrapped key blob reloads with the record it belongs to, so the same key is offered after a relaunch"
        )
        expect(reloaded == record, "the record reloads whole, blob included")

        print("PASS: a presence credential record carries its own wrapped key blob across a relaunch")
    }

    do {
        // The file holds a key blob, so it is readable and writable
        // by this user and nobody else, and so is the directory the
        // store creates for it.
        let url = temporaryPresenceCredentialRecordURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        PresenceCredentialRecordStore(url: url).save(PersistedPresenceCredential(
            credentialID: Data([0x01]),
            publicKey: Data([0x02]),
            credentialFormat: "apple-secure-enclave-p256",
            strength: "hardwareBound",
            wrappedPrivateKey: Data([0x03, 0x04])
        ))

        let filePermissions = (try! FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        expect(
            filePermissions == 0o600,
            "the record file is readable and writable by this user alone -- got \(String(filePermissions, radix: 8))"
        )
        let directoryPermissions = (try! FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path
        )[.posixPermissions] as! NSNumber).intValue
        expect(
            directoryPermissions == 0o700,
            "a directory the store creates for the record is this user's alone -- got \(String(directoryPermissions, radix: 8))"
        )

        // Saving again over an existing file keeps it that way: the second
        // write is the one an ordinary re-registration performs.
        PresenceCredentialRecordStore(url: url).save(PersistedPresenceCredential(
            credentialID: Data([0x05]),
            publicKey: Data([0x06]),
            credentialFormat: "apple-secure-enclave-p256",
            strength: "hardwareBound",
            wrappedPrivateKey: Data([0x07])
        ))
        let rewritten = (try! FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber).intValue
        expect(
            rewritten == 0o600,
            "a record written over an earlier one is still this user's alone -- got \(String(rewritten, radix: 8))"
        )

        print("PASS: the presence credential record file and the directory the store creates for it are readable by this user alone")
    }

    do {
        // A record written before the blob was kept here reads back
        // with none, which is exactly the signal to register fresh.
        let url = temporaryPresenceCredentialRecordURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let withoutBlob = """
        {"credentialID":"AQID","publicKey":"BAUG","credentialFormat":"apple-secure-enclave-p256","strength":"hardwareBound"}
        """
        try! Data(withoutBlob.utf8).write(to: url)

        let reloaded = PresenceCredentialRecordStore(url: url).load()
        expect(
            reloaded?.credentialID == Data([0x01, 0x02, 0x03]) && reloaded?.wrappedPrivateKey == nil,
            "a stored record with no wrapped key still decodes, reporting no key rather than failing to load at all"
        )

        print("PASS: a stored presence credential record with no wrapped key decodes, reporting none")
    }

    do {
        // Nothing on disk yet is the precondition register() uses to
        // decide to create a fresh credential rather than reuse one.
        let url = temporaryPresenceCredentialRecordURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let missing = PresenceCredentialRecordStore(url: url).load()
        expect(missing == nil, "a store whose file was never written reports no record, not a decoding failure disguised as one")

        print("PASS: a missing persisted record reads back as nil, the signal register() uses to register fresh")
    }

    do {
        // The pairing window's sentence about a host screen is for
        // the person, never the wire: it says whether this machine can
        // confirm that a person is at it, with no mention of a
        // credential, an enclave, or a keystore.
        let tail = "so a host can only allow it to see a virtual display, never a host screen."
        expect(
            PresenceCredentialRegistrationCopy.line(for: PresenceCredentialRegistrationError.noSecureEnclave)
                == "This machine cannot confirm that a person is at it, \(tail)",
            "a machine with no way to hold the key says it cannot confirm a person is at it -- got "
                + PresenceCredentialRegistrationCopy.line(for: PresenceCredentialRegistrationError.noSecureEnclave)
        )
        expect(
            PresenceCredentialRegistrationCopy.line(for: PresenceCredentialRegistrationError.keystoreFailed(reason: "declined"))
                == "This machine could not set up a way to confirm that a person is at it right now, \(tail)",
            "a keystore failure reads as a right-now failure, not a permanent one -- got "
                + PresenceCredentialRegistrationCopy.line(for: PresenceCredentialRegistrationError.keystoreFailed(reason: "declined"))
        )
        struct UnrelatedError: Error {}
        expect(
            PresenceCredentialRegistrationCopy.line(for: UnrelatedError())
                == "This machine could not set up a way to confirm that a person is at it, \(tail)",
            "any other error still reads as a sentence about confirming a person, not the error itself -- got "
                + PresenceCredentialRegistrationCopy.line(for: UnrelatedError())
        )
        expect(
            PresenceCredentialRegistrationCopy.successLine
                == "This machine can confirm that a person is at it, so a host may allow it to see a host screen.",
            "success says what the host may now allow, with no credential vocabulary -- got "
                + PresenceCredentialRegistrationCopy.successLine
        )
        for line in [
            PresenceCredentialRegistrationCopy.line(for: PresenceCredentialRegistrationError.noSecureEnclave),
            PresenceCredentialRegistrationCopy.line(for: PresenceCredentialRegistrationError.keystoreFailed(reason: "declined")),
            PresenceCredentialRegistrationCopy.line(for: UnrelatedError()),
            PresenceCredentialRegistrationCopy.successLine
        ] {
            expect(
                !line.localizedCaseInsensitiveContains("credential"),
                "no pairing-window sentence uses the word \u{201C}credential\u{201D} -- got \(line)"
            )
        }

        print("PASS: every registration sentence says whether this machine can confirm a person is at it, in plain words")
    }
}

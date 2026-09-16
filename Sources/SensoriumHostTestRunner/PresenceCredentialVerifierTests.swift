import CoreGraphics
import CryptoKit
import Foundation
import SensoriumCore
import SensoriumHost

/// The real presence-bound credential -- design §6.3, CLAUDE.md's own
/// invariant paragraphs. Every key here is a CryptoKit software key
/// generated in-process; no test touches the Security framework, Keychain,
/// LocalAuthentication, or the Secure Enclave. The viewer's hardware- or
/// OS-held credential is out of scope here; what this covers is the same
/// P-256-over-challenge signature routine either would produce.
@MainActor
private func hostScreenTestDisplay(id: UInt32 = 7) -> DisplaySnapshot {
    DisplaySnapshot(
        id: id,
        pixelWidth: 5120,
        pixelHeight: 2880,
        modeWidth: 2560,
        modeHeight: 1440,
        modePixelWidth: 5120,
        modePixelHeight: 2880,
        bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        online: true,
        builtin: false,
        main: false,
        vendorNumber: 1552,
        modelNumber: 40
    )
}

private func register(
    _ store: InMemoryApprovedDeviceStore,
    devicePublicKey: Data,
    credentialID: Data,
    signingKey: P256.Signing.PrivateKey,
    strength: HostScreenCredentialStrength,
    credentialFormat: String = PresenceCredentialVerifier.supportedCredentialFormat
) {
    store.setPresenceCredential(
        PresenceCredentialRecord(
            credentialID: credentialID,
            publicKey: signingKey.publicKey.rawRepresentation,
            credentialFormat: credentialFormat,
            strength: strength
        ),
        for: devicePublicKey
    )
}

@MainActor
func runPresenceCredentialVerifierTests() async {
    do {
        // A good signature over the exact challenge verifies
        let store = InMemoryApprovedDeviceStore()
        let devicePublicKey = Data(repeating: 0xAB, count: 8)
        let credentialID = Data([0x01, 0x02])
        let signingKey = P256.Signing.PrivateKey()
        register(store, devicePublicKey: devicePublicKey, credentialID: credentialID, signingKey: signingKey, strength: .hardwareBound)
        let verifier = PresenceCredentialVerifier(approvedDeviceStore: store)
        let challenge = Data(repeating: 0xCD, count: 32)
        let signature = try! signingKey.signature(for: challenge)
        let proof = HostScreenPresenceProof.signed(
            credentialID: credentialID,
            credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
            signature: signature.rawRepresentation
        )
        expect(
            verifier.verify(proof: proof, devicePublicKey: devicePublicKey, minimumStrength: .hardwareBound, challenge: challenge),
            "a genuine signature by the registered key, over the exact challenge issued, verifies"
        )
        print("PASS: a CryptoKit-generated key's genuine signature over the issued challenge verifies")
    }

    do {
        // A signature from the wrong key is refused
        let store = InMemoryApprovedDeviceStore()
        let devicePublicKey = Data(repeating: 0xAB, count: 8)
        let credentialID = Data([0x01, 0x02])
        let registeredKey = P256.Signing.PrivateKey()
        let impostorKey = P256.Signing.PrivateKey()
        register(store, devicePublicKey: devicePublicKey, credentialID: credentialID, signingKey: registeredKey, strength: .hardwareBound)
        let verifier = PresenceCredentialVerifier(approvedDeviceStore: store)
        let challenge = Data(repeating: 0xCD, count: 32)
        let signature = try! impostorKey.signature(for: challenge)
        let proof = HostScreenPresenceProof.signed(
            credentialID: credentialID,
            credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
            signature: signature.rawRepresentation
        )
        expect(
            !verifier.verify(proof: proof, devicePublicKey: devicePublicKey, minimumStrength: .hardwareBound, challenge: challenge),
            "a signature from a key other than the one registered for this device is refused"
        )
        print("PASS: a signature made by the wrong key is refused")
    }

    do {
        // A signature over a different challenge is refused
        let store = InMemoryApprovedDeviceStore()
        let devicePublicKey = Data(repeating: 0xAB, count: 8)
        let credentialID = Data([0x01, 0x02])
        let signingKey = P256.Signing.PrivateKey()
        register(store, devicePublicKey: devicePublicKey, credentialID: credentialID, signingKey: signingKey, strength: .hardwareBound)
        let verifier = PresenceCredentialVerifier(approvedDeviceStore: store)
        let issuedChallenge = Data(repeating: 0xCD, count: 32)
        let otherChallenge = Data(repeating: 0xEF, count: 32)
        let signature = try! signingKey.signature(for: otherChallenge)
        let proof = HostScreenPresenceProof.signed(
            credentialID: credentialID,
            credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
            signature: signature.rawRepresentation
        )
        expect(
            !verifier.verify(proof: proof, devicePublicKey: devicePublicKey, minimumStrength: .hardwareBound, challenge: issuedChallenge),
            "a genuine signature over a different challenge than the one this offer issued is refused -- otherwise an old signature could be replayed against a new offer"
        )
        print("PASS: a genuine signature over a different challenge is refused")
    }

    do {
        // Strength below the minimum is refused regardless of the proof
        // `HostScreenPresenceProof` has no field for a device to name its own
        // strength; this proves what actually gates is the registered
        // record's own strength, checked before the signature is even
        // examined for its own sake -- a perfectly genuine signature over
        // the exact challenge still refuses.
        let store = InMemoryApprovedDeviceStore()
        let devicePublicKey = Data(repeating: 0xAB, count: 8)
        let credentialID = Data([0x01, 0x02])
        let signingKey = P256.Signing.PrivateKey()
        register(store, devicePublicKey: devicePublicKey, credentialID: credentialID, signingKey: signingKey, strength: .softwarePresence)
        let verifier = PresenceCredentialVerifier(approvedDeviceStore: store)
        let challenge = Data(repeating: 0xCD, count: 32)
        let signature = try! signingKey.signature(for: challenge)
        let proof = HostScreenPresenceProof.signed(
            credentialID: credentialID,
            credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
            signature: signature.rawRepresentation
        )
        expect(
            !verifier.verify(proof: proof, devicePublicKey: devicePublicKey, minimumStrength: .hardwareBound, challenge: challenge),
            "a registered software-presence credential is refused against a hardware-bound minimum, even with a genuine signature over the exact challenge"
        )
        expect(
            verifier.verify(proof: proof, devicePublicKey: devicePublicKey, minimumStrength: .softwarePresence, challenge: challenge),
            "the same credential and signature verify once the minimum no longer exceeds what was actually registered"
        )
        expect(
            !verifier.verify(proof: proof, devicePublicKey: devicePublicKey, minimumStrength: nil, challenge: challenge),
            "a nil minimum is never any strength is acceptable -- it is only ever a device armed before a snapshot was taken, and that refuses too, with a genuine signature and a genuinely registered credential"
        )
        print("PASS: a strength below the minimum refuses a genuine signature, a matching minimum verifies it, and a nil minimum refuses outright")
    }

    do {
        // An unregistered device, unrecognised format, and mismatched credentialID all refuse
        let store = InMemoryApprovedDeviceStore()
        let devicePublicKey = Data(repeating: 0xAB, count: 8)
        let credentialID = Data([0x01, 0x02])
        let signingKey = P256.Signing.PrivateKey()
        register(store, devicePublicKey: devicePublicKey, credentialID: credentialID, signingKey: signingKey, strength: .hardwareBound)
        let verifier = PresenceCredentialVerifier(approvedDeviceStore: store)
        let challenge = Data(repeating: 0xCD, count: 32)
        let signature = try! signingKey.signature(for: challenge)

        let unregisteredDevice = Data(repeating: 0x99, count: 8)
        expect(
            !verifier.verify(
                proof: .signed(credentialID: credentialID, credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat, signature: signature.rawRepresentation),
                devicePublicKey: unregisteredDevice, minimumStrength: nil, challenge: challenge
            ),
            "a device with no registered credential at all is refused, not treated as having none to check"
        )

        expect(
            !verifier.verify(
                proof: .signed(credentialID: credentialID, credentialFormat: "fido2-ctap2", signature: signature.rawRepresentation),
                devicePublicKey: devicePublicKey, minimumStrength: nil, challenge: challenge
            ),
            "a credentialFormat this host does not recognise refuses structurally rather than attempting to verify it"
        )

        expect(
            !verifier.verify(
                proof: .signed(credentialID: Data([0xFF]), credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat, signature: signature.rawRepresentation),
                devicePublicKey: devicePublicKey, minimumStrength: nil, challenge: challenge
            ),
            "a credentialID that does not match what was registered for this device is refused"
        )

        expect(
            !verifier.verify(
                proof: .resumeTicket(Data([0x01])),
                devicePublicKey: devicePublicKey, minimumStrength: nil, challenge: challenge
            ),
            "a resume-ticket proof shape is refused by this verifier -- HostSessionController never routes one here, but the verifier itself has no signed proof to check"
        )

        print("PASS: an unregistered device, an unrecognised credential format, a mismatched credentialID, and a resume-ticket shape are all refused")
    }

    await runPresenceCredentialControllerIntegrationTests()
    await runPresenceCredentialPairingCeremonyTests()
    await runArmTimeMinimumStrengthSnapshotTests()
    await runPairingRequestedHookTests()
    await runOnDeviceApprovedHookTests()
    await runPairRequestCannotOverwriteAnotherDevicesCredentialTests()
    await runRePairWithProofOfPossessionReplacesCredentialTests()
}

/// A valid one-time code proves only that a person read it off this host,
/// never that the connection redeeming it holds the private key it offers
/// -- `PairingAuthority.issue` takes no key at issue time, and a
/// `pairRequest` carrying no signature says nothing about who sent it.
/// Without this check, anyone holding any currently valid code could
/// overwrite an unrelated, already-approved device's registered credential
/// just by naming its public key, breaking that device's own host-screen
/// access and, combined with a nil minimum, opening a downgrade path.
@MainActor
private func runPairRequestCannotOverwriteAnotherDevicesCredentialTests() async {
    do {
        // A valid but unrelated code cannot overwrite device A's credential.
        let hostIdentity = try! DeviceIdentity.generate()
        let deviceA = try! DeviceIdentity.generate()
        let store = InMemoryApprovedDeviceStore()
        let pairing = HostPairingService(hostIdentity: hostIdentity, approvedStore: store)

        let aCode = pairing.issueCode(code: "111111")
        let aCredentialID = Data([0xA1])
        let aKey = P256.Signing.PrivateKey()
        let aReply = pairing.handlePairRequest(
            deviceName: "Kestrel MacBook Pro",
            publicKey: deviceA.publicKey,
            code: aCode,
            presenceCredential: PresenceCredentialRegistration(
                credentialID: aCredentialID,
                publicKey: aKey.publicKey.rawRepresentation,
                credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
                strength: "hardwareBound"
            )
        )
        guard case .pairApproved = aReply else {
            expect(false, "device A's own first pairing, with a valid code, approves")
            return
        }
        let aCredentialBefore = store.presenceCredential(for: deviceA.publicKey)
        expect(aCredentialBefore?.credentialID == aCredentialID, "device A's own credential is on file after its own pairing")

        // A second, entirely valid code -- issued for some unrelated
        // pairing, never for device A -- redeemed with device A's own
        // public key (which is not secret; an eavesdropper or a device
        // that merely observed it in a wire message has it) and a fresh,
        // attacker-chosen credential. `connectionProvenPublicKey` is `nil`:
        // this stands in for a connection that never proved it holds
        // device A's private key, exactly what an attacker's connection
        // cannot fake.
        let attackerCode = pairing.issueCode(code: "222222")
        let attackerCredentialID = Data([0xEE])
        let attackerKey = P256.Signing.PrivateKey()
        let attackerReply = pairing.handlePairRequest(
            deviceName: "Kestrel MacBook Pro",
            publicKey: deviceA.publicKey,
            code: attackerCode,
            presenceCredential: PresenceCredentialRegistration(
                credentialID: attackerCredentialID,
                publicKey: attackerKey.publicKey.rawRepresentation,
                credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
                strength: "hardwareBound"
            ),
            connectionProvenPublicKey: nil
        )
        expect(
            { if case .pairApproved = attackerReply { return true } else { return false } }(),
            "the code itself is genuinely valid, so the pairing part still succeeds -- only the credential write is refused"
        )
        expect(
            store.presenceCredential(for: deviceA.publicKey) == aCredentialBefore,
            "device A's own registered credential is byte-for-byte unchanged -- a valid code for an unrelated pairing, replayed with A's public key and no proof of possessing it, never overwrites what A itself registered"
        )

        print("PASS: a valid code redeemed with another device's already-approved public key cannot overwrite its registered credential")
    }

    do {
        // A valid but unrelated code cannot overwrite device A's own
        // recorded name either. Lower severity than the credential (a
        // display name is not a security boundary), but the same guard
        // governs both.
        let hostIdentity = try! DeviceIdentity.generate()
        let deviceA = try! DeviceIdentity.generate()
        let store = InMemoryApprovedDeviceStore()
        let pairing = HostPairingService(hostIdentity: hostIdentity, approvedStore: store)

        let aCode = pairing.issueCode(code: "555555")
        let aReply = pairing.handlePairRequest(deviceName: "Kestrel MacBook Pro", publicKey: deviceA.publicKey, code: aCode)
        guard case .pairApproved = aReply else {
            expect(false, "device A's own first pairing, with a valid code, approves")
            return
        }
        expect(store.name(for: deviceA.publicKey) == "Kestrel MacBook Pro", "device A's own name is on file after its own pairing")

        // A second, entirely valid code redeemed with device A's own public
        // key and an attacker-chosen name, no proof of possession.
        let attackerCode = pairing.issueCode(code: "666666")
        let attackerReply = pairing.handlePairRequest(deviceName: "Definitely Not A Trap", publicKey: deviceA.publicKey, code: attackerCode)
        expect(
            { if case .pairApproved = attackerReply { return true } else { return false } }(),
            "the code itself is genuinely valid, so the pairing part still succeeds -- only the name write is refused"
        )
        expect(
            store.name(for: deviceA.publicKey) == "Kestrel MacBook Pro",
            "device A's own recorded name is unchanged -- a valid code for an unrelated pairing, replayed with A's public key and no proof of possessing it, never renames what A itself registered"
        )

        print("PASS: a valid code redeemed with another device's already-approved public key cannot overwrite its recorded name")
    }

    do {
        // The device's own connection can still rename itself.
        let hostIdentity = try! DeviceIdentity.generate()
        let deviceA = try! DeviceIdentity.generate()
        let store = InMemoryApprovedDeviceStore()
        let pairing = HostPairingService(hostIdentity: hostIdentity, approvedStore: store)

        let firstCode = pairing.issueCode(code: "777777")
        _ = pairing.handlePairRequest(deviceName: "Kestrel MacBook Pro", publicKey: deviceA.publicKey, code: firstCode)

        let secondCode = pairing.issueCode(code: "888888")
        let secondReply = pairing.handlePairRequest(
            deviceName: "Kestrel MacBook Pro (renamed)",
            publicKey: deviceA.publicKey,
            code: secondCode,
            connectionProvenPublicKey: deviceA.publicKey
        )
        guard case .pairApproved = secondReply else {
            expect(false, "device A's own re-pair, with a valid code, approves")
            return
        }
        expect(
            store.name(for: deviceA.publicKey) == "Kestrel MacBook Pro (renamed)",
            "a connection that has actually proven it holds device A's own key can still rename itself -- only who may write the name is restricted, not whether A itself still can"
        )

        print("PASS: a connection that has proven possession of its own key can still rename itself")
    }

    do {
        // The device's own connection can still refresh its own credential.
        let hostIdentity = try! DeviceIdentity.generate()
        let deviceA = try! DeviceIdentity.generate()
        let store = InMemoryApprovedDeviceStore()
        let pairing = HostPairingService(hostIdentity: hostIdentity, approvedStore: store)

        let firstCode = pairing.issueCode(code: "333333")
        let firstKey = P256.Signing.PrivateKey()
        _ = pairing.handlePairRequest(
            deviceName: "Kestrel MacBook Pro",
            publicKey: deviceA.publicKey,
            code: firstCode,
            presenceCredential: PresenceCredentialRegistration(
                credentialID: Data([0x01]),
                publicKey: firstKey.publicKey.rawRepresentation,
                credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
                strength: "softwarePresence"
            )
        )

        // Device A's own connection: this time proven, on this exact
        // connection, to hold A's own private key -- the same fact an
        // `authenticatedHello` earlier on the same connection establishes,
        // which `HostSessionController` passes through as
        // `connectionProvenPublicKey`.
        let secondCode = pairing.issueCode(code: "444444")
        let secondKey = P256.Signing.PrivateKey()
        let secondReply = pairing.handlePairRequest(
            deviceName: "Kestrel MacBook Pro",
            publicKey: deviceA.publicKey,
            code: secondCode,
            presenceCredential: PresenceCredentialRegistration(
                credentialID: Data([0x02]),
                publicKey: secondKey.publicKey.rawRepresentation,
                credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
                strength: "hardwareBound"
            ),
            connectionProvenPublicKey: deviceA.publicKey
        )
        guard case .pairApproved = secondReply else {
            expect(false, "device A's own re-pair, with a valid code, approves")
            return
        }
        expect(
            store.presenceCredential(for: deviceA.publicKey)?.credentialID == Data([0x02]),
            "a connection that has actually proven it holds device A's own key can still refresh A's own credential -- the fix narrows who may write it, not whether A itself still can"
        )

        print("PASS: a connection that has proven possession of its own key can still refresh its own credential")
    }
}

/// ux-spec.md's "Shown the moment a new machine asks to pair" needs to know
/// the moment happened before `sensoriumd` can act on it -- this is that
/// hook's own contract, independent of what wires it.
@MainActor
private func runPairingRequestedHookTests() async {
    let hostIdentity = try! DeviceIdentity.generate()
    let deviceIdentity = try! DeviceIdentity.generate()
    let pairing = HostPairingService(hostIdentity: hostIdentity)
    let code = pairing.issueCode(code: "246810")
    var requestedNames: [String] = []
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        requireAuthentication: true,
        pairing: pairing,
        onPairingRequested: { requestedNames.append($0) },
        keyConfinement: .unconfined
    )

    _ = try! controller.handle(.pairRequest(deviceName: "Kestrel MacBook Pro", publicKey: deviceIdentity.publicKey, code: "000000"))
    expect(
        requestedNames == ["Kestrel MacBook Pro"],
        "the hook fires with the request's own device name before the wrong code is even looked at"
    )

    _ = try! controller.handle(.pairRequest(deviceName: "Kestrel MacBook Pro", publicKey: deviceIdentity.publicKey, code: code))
    expect(
        requestedNames == ["Kestrel MacBook Pro", "Kestrel MacBook Pro"],
        "the hook fires again on the same device's later, correct attempt -- it is not a one-shot latch"
    )

    print("PASS: HostSessionController's onPairingRequested hook fires with the requesting device's own name on every pairRequest, correct code or not")

    // pairIntent: the same hook, no other effect
    // The true "shown the moment a new machine asks to pair" moment -- earlier
    // than pairRequest, which already carries a typed code, and this
    // device has nothing else to offer yet: no key, no code, nothing
    // authentication could even check.
    requestedNames.removeAll()
    let intentReply = try! controller.handle(.pairIntent(deviceName: "Kestrel MacBook Air"))
    expect(
        requestedNames == ["Kestrel MacBook Air"],
        "pairIntent fires the same hook, with its own device name"
    )
    expect(intentReply == nil, "pairIntent has no reply of its own -- it is a one-way notice, not a request awaiting an answer")
    expect(
        !controller.isSessionAuthenticatedAndActive,
        "pairIntent has no other effect -- it does not authenticate, approve, or open anything by itself"
    )

    print("PASS: pairIntent fires the same onPairingRequested hook and has no other effect")
}

/// `HostPairingService.onDeviceApproved` is `sensoriumd`'s only signal that
/// a device just finished pairing, and its own paired-machines list is
/// rebuilt from the approved store, not from the reply this call returns --
/// so the callback is only a safe reload point if the store it reads
/// already carries the new key, name, and presence credential by the
/// moment it fires. This asserts that ordering directly, from inside the
/// callback itself, rather than trusting it as a byproduct of some other
/// assertion.
@MainActor
private func runOnDeviceApprovedHookTests() async {
    let hostIdentity = try! DeviceIdentity.generate()
    let deviceIdentity = try! DeviceIdentity.generate()
    let store = InMemoryApprovedDeviceStore()
    let credentialID = Data([0x09])
    let credentialKey = P256.Signing.PrivateKey()
    var approvedNames: [String] = []
    var keysAtCallback: Set<Data> = []
    var nameAtCallback: String?
    var credentialAtCallback: PresenceCredentialRecord?
    var isNewDeviceAtCallback: [Bool] = []
    let pairing = HostPairingService(
        hostIdentity: hostIdentity,
        approvedStore: store,
        onDeviceApproved: { approval in
            approvedNames.append(approval.deviceName)
            isNewDeviceAtCallback.append(approval.isNewDevice)
            keysAtCallback = store.load()
            nameAtCallback = store.name(for: deviceIdentity.publicKey)
            credentialAtCallback = store.presenceCredential(for: deviceIdentity.publicKey)
        }
    )
    let code = pairing.issueCode(code: "135790")
    let reply = pairing.handlePairRequest(
        deviceName: "Kestrel MacBook Pro",
        publicKey: deviceIdentity.publicKey,
        code: code,
        presenceCredential: PresenceCredentialRegistration(
            credentialID: credentialID,
            publicKey: credentialKey.publicKey.rawRepresentation,
            credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
            strength: "hardwareBound"
        )
    )
    guard case .pairApproved = reply else {
        expect(false, "a fresh device's own first pairing, with a valid code, approves")
        return
    }
    expect(approvedNames == ["Kestrel MacBook Pro"], "onDeviceApproved fires exactly once, with the approved device's own name")
    expect(
        keysAtCallback.contains(deviceIdentity.publicKey),
        "the approved store already carries the new key by the time onDeviceApproved fires, so a caller reloading a paired-machines list from the callback sees it"
    )
    expect(nameAtCallback == "Kestrel MacBook Pro", "...and already carries the device's own name")
    expect(
        credentialAtCallback?.credentialID == credentialID,
        "...and already carries its registered presence credential"
    )
    expect(isNewDeviceAtCallback == [true], "a key's own first approval reports isNewDevice true, so a caller can arm host screen for it at once")

    // The same key, approved again through a second ceremony: the approved
    // store already held it, so this pairing must not arm host screen a
    // second time and silently undo an earlier "turn off" for this device.
    let secondCode = pairing.issueCode(code: "246801")
    let secondReply = pairing.handlePairRequest(
        deviceName: "Kestrel MacBook Pro",
        publicKey: deviceIdentity.publicKey,
        code: secondCode,
        connectionProvenPublicKey: deviceIdentity.publicKey
    )
    guard case .pairApproved = secondReply else {
        expect(false, "a device re-pairing with a valid code and proof of its own key still approves")
        return
    }
    expect(
        isNewDeviceAtCallback == [true, false],
        "an already-approved key's second approval reports isNewDevice false, so re-pairing never re-arms a device the person already turned off"
    )

    print("PASS: onDeviceApproved fires only once the approved store already reflects the new key, name, and presence credential, and reports isNewDevice honestly across a re-pair")
}

/// Arming snapshots the registered credential's strength as
/// `minimumCredentialStrength`, so a later, weaker re-pair cannot widen
/// what was approved. `nil`, meaning a device armed before the snapshot
/// existed, refuses rather than accepting any strength. All three
/// scenarios are driven through a live `HostSessionController` with the
/// real `PresenceCredentialVerifier`, constructing the arming record
/// directly with the strength it would have snapshotted -- this file
/// exercises the verifier and controller, not the coordinator that
/// actually takes the snapshot (`sensoriumd`'s `HostScreenArmingCoordinator.toggle`).
@MainActor
private func runArmTimeMinimumStrengthSnapshotTests() async {
    func makeController(
        deviceKey: Data,
        display: DisplaySnapshot,
        minimumCredentialStrength: HostScreenCredentialStrength?,
        store: InMemoryApprovedDeviceStore
    ) -> HostSessionController {
        let arming = HostScreenArming(devices: [
            HostScreenDeviceArming(
                devicePublicKey: deviceKey,
                deviceName: "Kestrel MacBook Pro",
                minimumCredentialStrength: minimumCredentialStrength,
                armedAt: Date()
            )
        ])
        return HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [deviceKey],
            requireAuthentication: true,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { arming },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenPresenceProofVerifier: PresenceCredentialVerifier(approvedDeviceStore: store),
            hostScreenLocalActivitySignal: AlwaysIdleActivitySignal()
        )
    }

    @MainActor
    func requestOutcome(_ controller: HostSessionController, deviceKey: Data, deviceIdentity: DeviceIdentity, signingKey: P256.Signing.PrivateKey, credentialID: Data) -> SensoriumMessage {
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey)
        _ = try! controller.handle(.authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! deviceIdentity.sign(transcript)
        ))
        guard case let .hostScreenList(displays, challenge) = try! controller.offerHostScreenList(), let entry = displays.first else {
            expect(false, "the fixture's offer names at least one display")
            return .goodbye(reason: "test-setup-failed")
        }
        let signature = try! signingKey.signature(for: challenge)
        let proof = HostScreenPresenceProof.signed(
            credentialID: credentialID, credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat, signature: signature.rawRepresentation
        )
        return try! controller.handle(.hostScreenRequest(token: entry.opaqueToken, presence: proof))!
    }

    do {
        // Armed at hardware, re-paired at software: refused
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let store = InMemoryApprovedDeviceStore()
        let credentialID = Data([0x01])
        let softwareKey = P256.Signing.PrivateKey()
        register(store, devicePublicKey: identity.publicKey, credentialID: credentialID, signingKey: softwareKey, strength: .softwarePresence)
        let controller = makeController(deviceKey: identity.publicKey, display: display, minimumCredentialStrength: .hardwareBound, store: store)
        let outcome = requestOutcome(controller, deviceKey: identity.publicKey, deviceIdentity: identity, signingKey: softwareKey, credentialID: credentialID)
        expect(
            outcome == .hostScreenRefused(reason: "host-screen-credential-unknown"),
            "armed at a hardware-bound minimum, a device that re-paired at the weaker software-presence strength is refused even with a genuine signature from the newly registered key"
        )
        print("PASS: armed at hardware, re-paired at software -- the request is refused")
    }

    do {
        // Armed at software, re-paired at hardware: admitted
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let store = InMemoryApprovedDeviceStore()
        let credentialID = Data([0x02])
        let hardwareKey = P256.Signing.PrivateKey()
        register(store, devicePublicKey: identity.publicKey, credentialID: credentialID, signingKey: hardwareKey, strength: .hardwareBound)
        let controller = makeController(deviceKey: identity.publicKey, display: display, minimumCredentialStrength: .softwarePresence, store: store)
        let outcome = requestOutcome(controller, deviceKey: identity.publicKey, deviceIdentity: identity, signingKey: hardwareKey, credentialID: credentialID)
        expect(
            { if case .hostScreenReady = outcome { return true } else { return false } }(),
            "armed at a software-presence minimum, a device that re-paired at the stronger hardware-bound strength is admitted"
        )
        print("PASS: armed at software, re-paired at hardware -- the request is admitted")
    }

    do {
        // A legacy nil-minimum record: refused, naming re-arming
        let identity = try! DeviceIdentity.generate()
        let display = hostScreenTestDisplay()
        let store = InMemoryApprovedDeviceStore()
        let credentialID = Data([0x03])
        let signingKey = P256.Signing.PrivateKey()
        register(store, devicePublicKey: identity.publicKey, credentialID: credentialID, signingKey: signingKey, strength: .hardwareBound)
        let controller = makeController(deviceKey: identity.publicKey, display: display, minimumCredentialStrength: nil, store: store)
        let outcome = requestOutcome(controller, deviceKey: identity.publicKey, deviceIdentity: identity, signingKey: signingKey, credentialID: credentialID)
        expect(
            outcome == .hostScreenRefused(reason: "host-screen-needs-rearming"),
            "a device armed before minimumCredentialStrength was ever snapshotted is refused with a cause naming re-arming, not the generic credential-unknown reason -- even though the signature offered is entirely genuine"
        )
        print("PASS: a legacy nil-minimum arming record is refused with a cause that names re-arming")
    }
}

/// Wires the real `PresenceCredentialVerifier` (not a fake) into a live
/// `HostSessionController`, proving the single-use challenge holds for the
/// actual verification path, not only for the generic fake exercised in
/// `HostScreenSessionControllerAdmissionTests.swift`.
@MainActor
private func runPresenceCredentialControllerIntegrationTests() async {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let display = hostScreenTestDisplay()
    let store = InMemoryApprovedDeviceStore()
    let credentialID = Data([0x07])
    let signingKey = P256.Signing.PrivateKey()
    register(store, devicePublicKey: deviceKey, credentialID: credentialID, signingKey: signingKey, strength: .hardwareBound)

    let arming = HostScreenArming(devices: [
        HostScreenDeviceArming(
            devicePublicKey: deviceKey,
            deviceName: "Kestrel MacBook Pro",
            minimumCredentialStrength: .hardwareBound,
            armedAt: Date()
        )
    ])
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        approvedPublicKeys: [deviceKey],
        requireAuthentication: true,
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { arming },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenPresenceProofVerifier: PresenceCredentialVerifier(approvedDeviceStore: store),
        hostScreenLocalActivitySignal: AlwaysIdleActivitySignal()
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey)
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))

    guard case let .hostScreenList(displays, challenge) = try! controller.offerHostScreenList(), let entry = displays.first else {
        expect(false, "the fixture's offer names at least one display")
        return
    }
    let signature = try! signingKey.signature(for: challenge)
    let proof = HostScreenPresenceProof.signed(
        credentialID: credentialID, credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat, signature: signature.rawRepresentation
    )

    // The first attempt here is deliberately a garbage signature, not the
    // genuine one above: this connection's own live-surface guard would
    // otherwise refuse a *second* request outright once the first admits,
    // masking whatever the challenge's own single-use bookkeeping would
    // have said. Failing the first attempt keeps this test isolated to
    // that bookkeeping -- `HostScreenMixedSessionTests.swift` already
    // covers the live-surface guard on its own terms.
    let garbageProof = HostScreenPresenceProof.signed(
        credentialID: credentialID, credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat, signature: Data([0xFF, 0xFF])
    )
    let first = try! controller.handle(.hostScreenRequest(token: entry.opaqueToken, presence: garbageProof))
    expect(
        first == .hostScreenRefused(reason: "host-screen-credential-unknown"),
        "a garbage signature over the offer's own challenge is refused, admitting nothing"
    )

    // The challenge this offer minted was consumed by the first attempt,
    // whether or not it was going to succeed (design: "fails safe"). The
    // token itself survives a failed presence check -- only a fresh offer
    // wipes it -- so this second attempt, with the genuine signature,
    // still reaches the challenge check, and finds no challenge left.
    let replay = try! controller.handle(.hostScreenRequest(token: entry.opaqueToken, presence: proof))
    expect(
        replay == .hostScreenRefused(reason: "host-screen-credential-unknown"),
        "a genuine signature over an already-consumed challenge still refuses -- the first, failed attempt already spent it"
    )

    print("PASS: the real verifier's challenge does not survive one use, so a later genuine signature over it still refuses")
}

/// CLAUDE.md: "that rule is enforced by requiring the pairing ceremony to
/// change the registered key, never by trusting the strength a device
/// reports." Proves both halves empirically: an ordinary re-pair that
/// registers nothing leaves what is on file untouched, a re-pair that
/// registers a new credential replaces it wholesale (key and strength
/// together, never one alone), and raising the arming record's own minimum
/// -- with no new pairing -- turns an already-genuine signature from what
/// remains registered into a refusal.
@MainActor
private func runPresenceCredentialPairingCeremonyTests() async {
    let hostIdentity = try! DeviceIdentity.generate()
    let deviceIdentity = try! DeviceIdentity.generate()
    let store = InMemoryApprovedDeviceStore()
    let pairing = HostPairingService(hostIdentity: hostIdentity, approvedStore: store)

    let firstCredentialID = Data([0x01])
    let firstKey = P256.Signing.PrivateKey()
    let firstCode = pairing.issueCode(code: "111111")
    let firstReply = pairing.handlePairRequest(
        deviceName: "MacBook",
        publicKey: deviceIdentity.publicKey,
        code: firstCode,
        presenceCredential: PresenceCredentialRegistration(
            credentialID: firstCredentialID,
            publicKey: firstKey.publicKey.rawRepresentation,
            credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
            strength: "softwarePresence"
        )
    )
    guard case .pairApproved = firstReply else {
        expect(false, "the first pairing attempt, with a valid code, approves")
        return
    }
    let afterFirstPairing = store.presenceCredential(for: deviceIdentity.publicKey)
    expect(
        afterFirstPairing?.credentialID == firstCredentialID && afterFirstPairing?.strength == .softwarePresence,
        "pairing with a presence-credential registration records exactly what was offered"
    )

    // An ordinary re-pair -- no presenceCredential offered -- leaves the
    // registered credential exactly as it was.
    let secondCode = pairing.issueCode(code: "222222")
    let secondReply = pairing.handlePairRequest(deviceName: "MacBook", publicKey: deviceIdentity.publicKey, code: secondCode)
    guard case .pairApproved = secondReply else {
        expect(false, "a re-pair with a valid code approves")
        return
    }
    expect(
        store.presenceCredential(for: deviceIdentity.publicKey) == afterFirstPairing,
        "a re-pair that offers no presence credential does not touch the one already registered"
    )

    // A re-pair that DOES offer a new credential replaces the old one
    // wholesale -- this is the one and only path that can ever change what
    // is on file.
    let secondCredentialID = Data([0x02])
    let secondKey = P256.Signing.PrivateKey()
    let thirdCode = pairing.issueCode(code: "333333")
    let thirdReply = pairing.handlePairRequest(
        deviceName: "MacBook",
        publicKey: deviceIdentity.publicKey,
        code: thirdCode,
        presenceCredential: PresenceCredentialRegistration(
            credentialID: secondCredentialID,
            publicKey: secondKey.publicKey.rawRepresentation,
            credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
            strength: "hardwareBound"
        ),
        // This is device A's own connection re-pairing itself, not an
        // impostor -- see runPairRequestCannotOverwriteAnotherDevicesCredentialTests
        // for the negative case this same guard exists to refuse.
        connectionProvenPublicKey: deviceIdentity.publicKey
    )
    guard case .pairApproved = thirdReply else {
        expect(false, "a re-pair offering a new presence credential, with a valid code, approves")
        return
    }
    let afterReplacement = store.presenceCredential(for: deviceIdentity.publicKey)
    expect(
        afterReplacement?.credentialID == secondCredentialID
            && afterReplacement?.publicKey == secondKey.publicKey.rawRepresentation
            && afterReplacement?.strength == .hardwareBound,
        "a fresh pairing ceremony replaces the registered credential wholesale -- key and strength together"
    )

    // Raising the arming record's own minimum, with no new pairing, is
    // what "invalidates the registered key until a new pairing registers a
    // new one" means in practice: the credential on file (still the
    // hardware-bound one just registered) genuinely satisfies a
    // hardware-bound minimum today...
    let verifier = PresenceCredentialVerifier(approvedDeviceStore: store)
    let challenge = Data(repeating: 0x5A, count: 32)
    let signature = try! secondKey.signature(for: challenge)
    let proof = HostScreenPresenceProof.signed(
        credentialID: secondCredentialID, credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat, signature: signature.rawRepresentation
    )
    expect(
        verifier.verify(proof: proof, devicePublicKey: deviceIdentity.publicKey, minimumStrength: .hardwareBound, challenge: challenge),
        "the credential just registered by pairing genuinely satisfies a hardware-bound minimum"
    )

    // ...but nothing on the wire can raise what was actually registered: a
    // device cannot satisfy a still-higher minimum than the strength it
    // registered by resending a higher label. There is no acceptable
    // strength above hardwareBound to raise the minimum to, so this proves
    // the negative the other direction -- registering the weaker tier again
    // (a fresh pairing ceremony, the only path that can ever change what is
    // on file) demonstrably drops what a hardware-bound minimum will accept,
    // even though the signature is just as genuine.
    let fourthCode = pairing.issueCode(code: "444444")
    let fourthReply = pairing.handlePairRequest(
        deviceName: "MacBook",
        publicKey: deviceIdentity.publicKey,
        code: fourthCode,
        presenceCredential: PresenceCredentialRegistration(
            credentialID: secondCredentialID,
            publicKey: secondKey.publicKey.rawRepresentation,
            credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
            strength: "softwarePresence"
        ),
        connectionProvenPublicKey: deviceIdentity.publicKey
    )
    guard case .pairApproved = fourthReply else {
        expect(false, "a re-pair re-registering the same key at a weaker reported strength, with a valid code, approves")
        return
    }
    expect(
        !verifier.verify(proof: proof, devicePublicKey: deviceIdentity.publicKey, minimumStrength: .hardwareBound, challenge: challenge),
        "the very same signature and key, once re-registered at a weaker reported strength, no longer satisfies a hardware-bound minimum -- the recorded strength is what pairing wrote, never what a message could claim"
    )

    print("PASS: only a pairing ceremony writes the registered credential, and the recorded strength, never a wire claim, is what a minimum is checked against")
}

/// Well past `HostScreenPresenceRule.recommendedPresenceThreshold`, so the
/// presence-check rule reads "nobody has touched the host recently" and lets
/// an otherwise-admissible request proceed -- the same fixed reading
/// `HostScreenSessionControllerAdmissionTests.swift`'s own fake defaults to.
private final class AlwaysIdleActivitySignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

/// The pairing ceremony is the only path that can replace an already-paired
/// machine's registered credential. The viewer sends its `pairRequest` on a
/// fresh connection with no `authenticatedHello` ahead of it, so the host has
/// no proven key of its own to match against; the request's own signature
/// supplies exactly the proof of possession that connection is missing,
/// without weakening the guard for a request that cannot produce one.
@MainActor
private func runRePairWithProofOfPossessionReplacesCredentialTests() async {
    let hostIdentity = try! DeviceIdentity.generate()
    let device = try! DeviceIdentity.generate()
    let store = InMemoryApprovedDeviceStore()
    let pairing = HostPairingService(hostIdentity: hostIdentity, approvedStore: store)
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        requireAuthentication: true,
        pairing: pairing,
        keyConfinement: .unconfined
    )

    func registration(_ identifier: UInt8, _ key: P256.Signing.PrivateKey) -> PresenceCredentialRegistration {
        PresenceCredentialRegistration(
            credentialID: Data([identifier]),
            publicKey: key.publicKey.rawRepresentation,
            credentialFormat: PresenceCredentialVerifier.supportedCredentialFormat,
            strength: "hardwareBound"
        )
    }

    func request(
        deviceName: String = "MacBook",
        code: String,
        credential: PresenceCredentialRegistration,
        signedBy signer: DeviceIdentity?
    ) -> SensoriumMessage {
        let signature = signer.map {
            try! $0.sign(SensoriumFrameCodec.pairRequestTranscript(
                deviceName: deviceName,
                clientPublicKey: device.publicKey,
                code: code,
                presenceCredential: credential
            ))
        }
        return .pairRequest(
            deviceName: deviceName,
            publicKey: device.publicKey,
            code: code,
            presenceCredential: credential,
            signature: signature
        )
    }

    let firstKey = P256.Signing.PrivateKey()
    let firstCode = pairing.issueCode(code: "111111")
    let firstReply = try! controller.handle(request(code: firstCode, credential: registration(0x01, firstKey), signedBy: device))
    guard case .pairApproved = firstReply else {
        expect(false, "a first pairing with a valid code approves")
        return
    }
    expect(
        store.presenceCredential(for: device.publicKey)?.credentialID == Data([0x01]),
        "the first pairing registers the credential it offered"
    )

    // A machine that predates the proof: already approved, offering a new
    // credential, proving nothing. Today's behaviour is kept exactly --
    // the pairing succeeds and what is on file is untouched.
    let unsignedKey = P256.Signing.PrivateKey()
    let unsignedCode = pairing.issueCode(code: "222222")
    let unsignedReply = try! controller.handle(
        request(code: unsignedCode, credential: registration(0x02, unsignedKey), signedBy: nil)
    )
    guard case .pairApproved = unsignedReply else {
        expect(false, "a re-pair with a valid code but no proof still approves -- pairing itself is not what the proof gates")
        return
    }
    expect(
        store.presenceCredential(for: device.publicKey)?.credentialID == Data([0x01]),
        "a re-pair that proves nothing leaves an already-approved machine's registered credential exactly as it was"
    )

    // The same machine, this time proving it holds the key it names: the
    // registration is replaced wholesale, which is what makes "Pair again"
    // actually fix a credential the host no longer recognises.
    let replacementKey = P256.Signing.PrivateKey()
    let replacementCode = pairing.issueCode(code: "333333")
    let replacementReply = try! controller.handle(
        request(code: replacementCode, credential: registration(0x03, replacementKey), signedBy: device)
    )
    guard case .pairApproved = replacementReply else {
        expect(false, "a re-pair carrying a valid proof approves")
        return
    }
    let replaced = store.presenceCredential(for: device.publicKey)
    expect(
        replaced?.credentialID == Data([0x03]) && replaced?.publicKey == replacementKey.publicKey.rawRepresentation,
        "a re-pair that proves possession of the machine's own identity key replaces the registered credential wholesale"
    )

    // A machine the person renamed since it paired is still that machine,
    // and it proves so with the same key: one ceremony records the new name
    // and the new credential together, rather than making them pair twice
    // to get both.
    let renamedKey = P256.Signing.PrivateKey()
    let renamedCode = pairing.issueCode(code: "555555")
    let renamedReply = try! controller.handle(request(
        deviceName: "Kestrel",
        code: renamedCode,
        credential: registration(0x05, renamedKey),
        signedBy: device
    ))
    guard case .pairApproved = renamedReply else {
        expect(false, "a renamed machine's proven re-pair approves")
        return
    }
    expect(
        store.name(for: device.publicKey) == "Kestrel",
        "a proven re-pair records the name the machine now reports"
    )
    expect(
        store.presenceCredential(for: device.publicKey)?.credentialID == Data([0x05]),
        "the same proven request also replaces the registered credential -- a proven key is the same machine whatever it is now called"
    )

    // A forged proof is not a weaker proof: the request is refused outright,
    // the same way an authenticatedHello whose signature does not verify is.
    let forgedKey = P256.Signing.PrivateKey()
    let forgedCode = pairing.issueCode(code: "444444")
    let impostor = try! DeviceIdentity.generate()
    expectThrows(
        HostSessionControllerError.invalidAuthentication,
        { _ = try controller.handle(request(code: forgedCode, credential: registration(0x04, forgedKey), signedBy: impostor)) },
        "a pairRequest whose proof does not verify against the key it names is refused, never treated as an unproven one"
    )
    expect(
        store.presenceCredential(for: device.publicKey)?.credentialID == Data([0x05]),
        "a refused request writes nothing at all -- not the credential, not the pairing"
    )

    print("PASS: a re-pair replaces the registered credential only on proof of possession, and a forged proof is refused")
}

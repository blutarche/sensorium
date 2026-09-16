import Foundation
import SensoriumClient
import SensoriumCore

/// A one-shot barrier a test opens by hand, to park a `run()` inside its signer
/// so a second `run()` meets the first still in flight.
private actor AsyncGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A main-actor message sink a `run()` launched on its own task can append to,
/// since a plain local `var` cannot cross into that task's closure.
@MainActor
private final class MessageBox {
    private(set) var messages: [SensoriumMessage] = []
    func append(_ message: SensoriumMessage) { messages.append(message) }
    var count: Int { messages.count }
}

/// The viewer's submit-time presence-arm sequence for an opt-in lock-screen
/// unlock: request a single-use challenge, sign that exact challenge with a
/// live presence check, arm, then send the unlock request -- and the
/// fail-closed aborts that send no unlock request at all. Verified against a
/// fake transport that captures what left and a fake signer, so none of it
/// needs a socket or a real authenticator.
@MainActor
func testHostScreenUnlockArmFlowTests() async {
    let signedFormat = "test-format"
    let signedCredentialID = Data([0x11])

    do {
        // On submit the arm proof is signed over the exact challenge the host
        // returned, and the three messages leave in order: challenge request,
        // arm carrying that proof, then the unlock request.
        let flow = HostScreenUnlockArmFlow()
        let challenge = Data([0xAB, 0xCD])
        let password = Data("hunter2".utf8)
        var sent: [SensoriumMessage] = []
        var signedChallenge: Data?

        let result = await flow.run(
            password: password,
            send: { message in
                sent.append(message)
                if case .hostScreenUnlockChallengeRequest = message {
                    Task { @MainActor in flow.deliverChallenge(challenge) }
                }
            },
            sign: { challengeToSign in
                signedChallenge = challengeToSign
                return .signed(
                    credentialID: signedCredentialID,
                    credentialFormat: signedFormat,
                    signature: challengeToSign
                )
            }
        )

        expect(result == .armed, "a submission that armed and sent the unlock request reports .armed")
        expect(
            signedChallenge == challenge,
            "the presence proof is signed over the exact challenge the host returned -- got: \(String(describing: signedChallenge))"
        )
        let expected: [SensoriumMessage] = [
            .hostScreenUnlockChallengeRequest,
            .hostScreenUnlockArm(presence: .signed(
                credentialID: signedCredentialID,
                credentialFormat: signedFormat,
                signature: challenge
            )),
            .hostScreenUnlockRequest(password: password)
        ]
        expect(sent == expected, "the arm carrying the proof is sent between the challenge request and the unlock request -- got: \(sent)")
        print("PASS: an unlock submit signs the returned challenge and arms before sending the unlock request")
    }

    do {
        // The host never returns a challenge: the submit times out, sends no
        // arm and no unlock request, and reports the failure so the prompt
        // stays up to retry.
        let flow = HostScreenUnlockArmFlow()
        var sent: [SensoriumMessage] = []

        let result = await flow.run(
            password: Data("hunter2".utf8),
            timeout: .milliseconds(50),
            send: { sent.append($0) },
            sign: { _ in
                expect(false, "the signer must not run when no challenge ever arrived")
                return .signed(credentialID: signedCredentialID, credentialFormat: signedFormat, signature: Data())
            }
        )

        expect(result == .challengeTimedOut, "a challenge that never arrives resolves as .challengeTimedOut -- got: \(result)")
        expect(
            sent == [.hostScreenUnlockChallengeRequest],
            "only the challenge request left -- no arm, no unlock request -- got: \(sent)"
        )
        print("PASS: a challenge that never arrives times out with no arm and no unlock request")
    }

    do {
        // The live presence check is cancelled (the signer throws): fail
        // closed. No arm, no unlock request, the failure is reported.
        struct PresenceCancelled: Error {}
        let flow = HostScreenUnlockArmFlow()
        let challenge = Data([0x01])
        var sent: [SensoriumMessage] = []

        let result = await flow.run(
            password: Data("hunter2".utf8),
            send: { message in
                sent.append(message)
                if case .hostScreenUnlockChallengeRequest = message {
                    Task { @MainActor in flow.deliverChallenge(challenge) }
                }
            },
            sign: { _ in throw PresenceCancelled() }
        )

        expect(result == .presenceFailed, "a cancelled presence check resolves as .presenceFailed -- got: \(result)")
        expect(
            sent == [.hostScreenUnlockChallengeRequest],
            "a cancelled presence check arms nothing and sends no unlock request -- got: \(sent)"
        )
        print("PASS: a cancelled presence check fails closed -- no arm, no unlock request")
    }

    do {
        // A challenge that arrives after the submission has resolved is
        // ignored: no second signing, nothing more on the wire, no crash.
        let flow = HostScreenUnlockArmFlow()
        let challenge = Data([0x09])
        var sent: [SensoriumMessage] = []
        var signCount = 0

        let result = await flow.run(
            password: Data("hunter2".utf8),
            send: { message in
                sent.append(message)
                if case .hostScreenUnlockChallengeRequest = message {
                    Task { @MainActor in flow.deliverChallenge(challenge) }
                }
            },
            sign: { challengeToSign in
                signCount += 1
                return .signed(credentialID: signedCredentialID, credentialFormat: signedFormat, signature: challengeToSign)
            }
        )
        expect(result == .armed, "the first submission completes and arms")

        flow.deliverChallenge(Data([0xFF]))
        flow.deliverChallenge(challenge)
        expect(signCount == 1, "a challenge arriving after resolution triggers no second signing -- got: \(signCount)")
        expect(sent.count == 3, "and puts no further message on the wire -- got: \(sent)")
        print("PASS: a late or duplicate challenge after resolution is ignored")
    }

    do {
        // A second submit fired while the first is still in flight is
        // refused as .alreadyInFlight and puts nothing extra on the wire -- no
        // second challenge request, arm, or unlock request.
        let flow = HostScreenUnlockArmFlow()
        let sent = MessageBox()
        let challenge = Data([0x22])
        let signGate = AsyncGate()

        let first = Task { @MainActor in
            await flow.run(
                password: Data("first".utf8),
                send: { message in
                    sent.append(message)
                    if case .hostScreenUnlockChallengeRequest = message {
                        Task { @MainActor in flow.deliverChallenge(challenge) }
                    }
                },
                sign: { challengeToSign in
                    await signGate.wait()
                    return .signed(credentialID: signedCredentialID, credentialFormat: signedFormat, signature: challengeToSign)
                }
            )
        }

        // Let the first submit reach and park inside its signer.
        while sent.count < 1 { await Task.yield() }

        let sentBeforeSecond = sent.count
        let secondResult = await flow.run(
            password: Data("second".utf8),
            timeout: .milliseconds(50),
            send: { sent.append($0) },
            sign: { challengeToSign in
                .signed(credentialID: signedCredentialID, credentialFormat: signedFormat, signature: challengeToSign)
            }
        )
        expect(secondResult == .alreadyInFlight, "a second submit while one is in flight is refused as .alreadyInFlight -- got: \(secondResult)")
        expect(sent.count == sentBeforeSecond, "the refused second submit puts nothing extra on the wire -- got: \(sent.messages)")

        // Release the first so it completes cleanly.
        await signGate.open()
        let firstResult = await first.value
        expect(firstResult == .armed, "the first submit still completes once its presence check resolves")
        print("PASS: a second submit during an in-flight one is refused with nothing extra sent; the first still completes")
    }

    do {
        // Seam 2: the controller signs a supplied challenge with its own
        // registered presence credential and returns the proof, without ever
        // exposing that credential.
        let controller = ClientSessionController(
            transport: SilentClientTransport(),
            credentialProvider: SoftwarePresenceCredential()
        )
        let proof = try? await controller.signUnlockChallenge(Data([0x42, 0x43]))
        if case let .signed(_, _, signature)? = proof {
            expect(!signature.isEmpty, "the proof carries a signature over the challenge")
        } else {
            expect(false, "signUnlockChallenge returns a signed proof when a credential is registered -- got: \(String(describing: proof))")
        }
        print("PASS: the controller signs a supplied unlock challenge into a presence proof")
    }

    do {
        // Fail closed: a machine with no registered presence credential cannot
        // sign an unlock challenge at all.
        let controller = ClientSessionController(transport: SilentClientTransport())
        var threw = false
        do {
            _ = try await controller.signUnlockChallenge(Data([0x01]))
        } catch {
            threw = true
        }
        expect(threw, "with no registered presence credential, signing an unlock challenge fails closed")
        print("PASS: signing an unlock challenge fails closed with no registered credential")
    }
}

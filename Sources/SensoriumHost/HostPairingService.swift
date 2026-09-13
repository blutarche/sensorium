import Foundation
import SensoriumCore

/// What `onDeviceApproved` reports about one approved pairing. `isNewDevice`
/// is the fact `HostScreenArmingCoordinator.armOnPairing` in `sensoriumd`
/// gates on: `true` only the very first time this public key is ever
/// approved, so a device that pairs again after the person at the host
/// turned host screen off for it is never re-armed by the mere act of
/// pairing again.
public struct PairingApproval: Sendable {
    public let deviceName: String
    public let devicePublicKey: Data
    public let isNewDevice: Bool

    public init(deviceName: String, devicePublicKey: Data, isNewDevice: Bool) {
        self.deviceName = deviceName
        self.devicePublicKey = devicePublicKey
        self.isNewDevice = isNewDevice
    }
}

/// Owns the one-time-code ceremony and the set of machine keys allowed to open a
/// session. A code approves exactly one machine and cannot be replayed.
@MainActor
public final class HostPairingService {
    private let hostIdentity: DeviceIdentity
    private var authority = PairingAuthority()
    private var approvedKeys: Set<Data>
    private let approvedStore: (any ApprovedDeviceStoring)?
    private let tlsCertificateHash: Data?
    /// Fires the moment a `pairRequest` is approved -- before the machine's
    /// authenticated hello ever arrives -- so a caller can show
    /// "Waiting for `<machine name>` to finish pairing" for the true interval
    /// between approval and connection, not just the connection's own start,
    /// and can decide whether this pairing should arm host screen at once.
    private let onDeviceApproved: ((PairingApproval) -> Void)?

    public init(
        hostIdentity: DeviceIdentity,
        approvedPublicKeys: Set<Data> = [],
        approvedStore: (any ApprovedDeviceStoring)? = nil,
        tlsCertificateHash: Data? = nil,
        onDeviceApproved: ((PairingApproval) -> Void)? = nil
    ) {
        self.hostIdentity = hostIdentity
        self.approvedStore = approvedStore
        self.tlsCertificateHash = tlsCertificateHash
        self.onDeviceApproved = onDeviceApproved
        // A pairing that does not survive a restart silently un-pairs the user.
        approvedKeys = approvedPublicKeys.union(approvedStore?.load() ?? [])
    }

    public var hostPublicKey: Data { hostIdentity.publicKey }
    public var approvedPublicKeys: Set<Data> { approvedKeys }

    @discardableResult
    public func issueCode(
        now: Date = Date(),
        lifetime: TimeInterval = PairingAuthority.defaultLifetime,
        code: String? = nil
    ) -> String {
        authority.issue(now: now, lifetime: lifetime, code: code)
    }

    public func isApproved(_ publicKey: Data) -> Bool {
        approvedKeys.contains(publicKey)
    }

    /// Returns the reply to send back: approval pins the host key on the viewer,
    /// rejection names the reason without revealing the expected code.
    ///
    /// `presenceCredential`, when present, is registered for `publicKey`
    /// only once the code above has genuinely been approved -- this is the
    /// one call site in this codebase that ever writes a machine's
    /// registered presence-bound credential, and the host's own invariant
    /// requires that write to happen nowhere else: a new credential
    /// reaches this host only through the pairing ceremony,
    /// never a later message trusted on its own. A `pairRequest` that
    /// carries none leaves whatever this machine already had registered
    /// untouched -- an ordinary re-pair is not itself a reason to forget a
    /// still-valid credential.
    ///
    /// A valid code proves a person read it off this host and typed it
    /// somewhere -- it says nothing about which key that person's machine
    /// actually holds, because `PairingAuthority.issue` takes no key at
    /// issue time. That is an acceptable gap for a *new* key: there is
    /// nothing registered yet for an impostor to touch. It is not for a key
    /// this host already approved -- a valid code for some unrelated
    /// pairing, replayed with an already-approved machine's own public key
    /// and a fresh credential, would otherwise let anyone who merely
    /// observed that key overwrite its owner's registered credential
    /// wholesale, refusing that machine's own future host-screen requests
    /// and, combined with a still-unarmed minimum, a downgrade path. So a
    /// credential write for an *already-approved* key is allowed only when
    /// this exact connection has separately proven it holds that key's
    /// private half -- `connectionProvenPublicKey`, which the caller
    /// establishes either from an `authenticatedHello` verified earlier on
    /// this same connection or from the `pairRequest`'s own signature over
    /// `SensoriumFrameCodec.pairRequestTranscript(...)`. The name the
    /// request reports does not narrow that further: a proven key is the
    /// same machine whatever the person has since renamed it to, and
    /// refusing the credential over the rename would only make that machine
    /// pair twice to register one key.
    ///
    /// The same replay changes the *name* recorded for an already-approved
    /// key just as easily. Lower severity than the credential (a display
    /// name is not a security boundary), but the same root cause deserves
    /// the same fix: an already-approved key's recorded name changes only
    /// when this connection has proven it holds that key.
    public func handlePairRequest(
        deviceName: String,
        publicKey: Data,
        code: String,
        presenceCredential: PresenceCredentialRegistration? = nil,
        connectionProvenPublicKey: Data? = nil,
        now: Date = Date()
    ) -> SensoriumMessage {
        guard !deviceName.isEmpty, !publicKey.isEmpty else {
            return .pairRejected(reason: "invalid-request")
        }
        // Read before anything below mutates either: what decides whether
        // this request may write a credential is what was already true of
        // `publicKey`, never a fact this same request just wrote.
        let wasAlreadyApproved = approvedKeys.contains(publicKey)
        do {
            _ = try authority.approve(code: code, deviceID: deviceName, now: now)
            approvedKeys.insert(publicKey)
            approvedStore?.save(approvedKeys)
            // One rule for both records this request can change: a key
            // nothing is on file for yet, or a request that proved it holds
            // the key it names.
            let writeAllowed = !wasAlreadyApproved || connectionProvenPublicKey == publicKey
            if writeAllowed {
                approvedStore?.setName(deviceName, for: publicKey)
            }
            if writeAllowed,
               let presenceCredential,
               let strength = HostScreenCredentialStrength(rawValue: presenceCredential.strength) {
                approvedStore?.setPresenceCredential(
                    PresenceCredentialRecord(
                        credentialID: presenceCredential.credentialID,
                        publicKey: presenceCredential.publicKey,
                        credentialFormat: presenceCredential.credentialFormat,
                        strength: strength
                    ),
                    for: publicKey
                )
            }
            onDeviceApproved?(PairingApproval(
                deviceName: deviceName,
                devicePublicKey: publicKey,
                isNewDevice: !wasAlreadyApproved
            ))
            let signature = try hostIdentity.sign(SensoriumFrameCodec.pairApprovalTranscript(
                deviceName: deviceName,
                clientPublicKey: publicKey,
                tlsCertificateHash: tlsCertificateHash
            ))
            return .pairApproved(
                hostPublicKey: hostIdentity.publicKey,
                tlsCertificateHash: tlsCertificateHash,
                signature: signature
            )
        } catch PairingError.invalidCode {
            return .pairRejected(reason: "invalid-code")
        } catch PairingError.codeAlreadyConsumed {
            return .pairRejected(reason: "code-already-consumed")
        } catch PairingError.codeExpired {
            return .pairRejected(reason: "code-expired")
        } catch PairingError.codeAttemptsExhausted {
            // Like an expiry, this retires the code; a new one has to be
            // issued at the host.
            return .pairRejected(reason: "code-attempts-exhausted")
        } catch PairingError.noActiveCode {
            return .pairRejected(reason: "no-active-code")
        } catch {
            return .pairRejected(reason: "invalid-request")
        }
    }

    /// Writes `deviceName` for `publicKey` when nothing is recorded yet, or
    /// corrects it when the connecting machine now reports a different one.
    /// The pairing ceremony above is the ordinary way a name is first
    /// recorded; this is the one other path, for a key approved before that
    /// existed or renamed on its own side afterward -- and, like the
    /// ceremony's own name write, it runs only once the caller has already
    /// verified this exact connection holds `publicKey`'s private half.
    public func recordDeviceName(_ deviceName: String, for publicKey: Data) {
        guard let approvedStore, approvedKeys.contains(publicKey) else { return }
        let existingName = approvedStore.name(for: publicKey)
        guard existingName == nil || existingName != deviceName else { return }
        approvedStore.setName(deviceName, for: publicKey)
    }
}

extension HostPairingService {
    func signCanvasReady(
        displayID: UInt32,
        logicalWidth: Int,
        logicalHeight: Int,
        clientPublicKey: Data,
        surfaceID: UInt32?
    ) throws -> Data {
        try hostIdentity.sign(SensoriumFrameCodec.canvasReadyTranscript(
            displayID: displayID,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            clientPublicKey: clientPublicKey,
            surfaceID: surfaceID
        ))
    }
}

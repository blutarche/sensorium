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
    /// A valid code proves a person read it off this host and typed it
    /// somewhere -- it says nothing about which key that person's machine
    /// actually holds, because `PairingAuthority.issue` takes no key at
    /// issue time. `signature` closes that gap and is required: the
    /// requesting machine's own signature over
    /// `SensoriumFrameCodec.pairRequestTranscript(...)`, which covers every
    /// value this request asks this host to write. It is checked here,
    /// before the code is examined and before anything is written, so a
    /// request that cannot prove possession never reaches the ceremony and
    /// never spends a guess from the code's budget. Pairing is what arms a
    /// machine for host screen, so this is the one check standing between a
    /// six-digit code someone read and an arming record.
    public func handlePairRequest(
        deviceName: String,
        publicKey: Data,
        code: String,
        signature: Data,
        now: Date = Date()
    ) -> SensoriumMessage {
        guard !deviceName.isEmpty, !publicKey.isEmpty else {
            return .pairRejected(reason: "invalid-request")
        }
        guard DeviceIdentity.verify(
            signature: signature,
            message: SensoriumFrameCodec.pairRequestTranscript(
                deviceName: deviceName,
                clientPublicKey: publicKey,
                code: code
            ),
            publicKey: publicKey
        ) else {
            return .pairRejected(reason: "invalid-request")
        }
        // Read before anything below mutates it: whether this request is the
        // very first approval of `publicKey` is what `onDeviceApproved`
        // reports, and it must be what was already true, never a fact this
        // same request just wrote.
        let wasAlreadyApproved = approvedKeys.contains(publicKey)
        do {
            _ = try authority.approve(code: code, deviceID: deviceName, now: now)
            approvedKeys.insert(publicKey)
            approvedStore?.save(approvedKeys)
            // Every request that reaches here proved it holds the key it
            // names, so the name it gives is this machine's own.
            approvedStore?.setName(deviceName, for: publicKey)
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

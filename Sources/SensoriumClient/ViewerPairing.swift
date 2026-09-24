import Foundation

/// How one pairing attempt ended, as the window needs to see it.
public enum ViewerPairingResult: Sendable {
    case paired(SavedHost)
    case failed(ViewerPairingOutcome)
}

/// What attempting `pairIntent` on the code step found -- reuses
/// `ViewerPairingOutcome` for `.failed` so a connection failure here reads
/// with the exact same words a pairing attempt's own failures already use.
public enum ViewerPairIntentAttempt: Sendable {
    case sent
    case failed(ViewerPairingOutcome)
}

/// The machine a code is being typed for: known from the tailnet list, or from a
/// saved machine being paired again. Absent entirely when the address is being
/// typed by hand, which is the one path that has no machine yet.
public struct ViewerPairingDevice: Equatable, Sendable {
    public let address: String
    public let name: String

    public init(address: String, name: String) {
        self.address = address
        self.name = name
    }

    /// What every sentence about this machine calls it before it has been paired.
    public var label: String { name.isEmpty ? address : name }
}

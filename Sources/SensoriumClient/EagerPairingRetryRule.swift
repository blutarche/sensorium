/// What a prefilled-address pairing attempt does with its already-open
/// connection once one attempt fails. A wrong code (`.refused`) is the one
/// outcome worth staying dialled in for: the next retyped digit reuses this
/// same connection. Every other outcome is a connection already known to be
/// bad, so the next attempt -- if there is one -- redials fresh.
public enum EagerPairingConnectionDisposition: Equatable, Sendable {
    case keepConnectionOpen
    case closeConnection
}

public enum EagerPairingRetryRule {
    public static func decision(for outcome: ViewerPairingOutcome) -> EagerPairingConnectionDisposition {
        if case .refused = outcome {
            return .keepConnectionOpen
        }
        return .closeConnection
    }
}

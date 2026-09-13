import Foundation
import SensoriumClient

@MainActor
func testEagerPairingRetryRuleTests() async {
    do {
        // A wrong code is the one outcome worth staying dialled in
        // for: the next retyped digit reuses this same connection
        // rather than redialling.
        expect(
            EagerPairingRetryRule.decision(for: .refused(reason: "invalid-code")) == .keepConnectionOpen,
            "a refused code keeps the connection open for the next retry"
        )
        print("PASS: a refused code keeps the connection open")
    }

    do {
        // Every other outcome is a connection already known to be
        // bad: `.close`, so the next attempt (if there is one)
        // redials fresh instead of reusing it.
        expect(
            EagerPairingRetryRule.decision(for: .unreachable) == .closeConnection,
            "an unreachable host closes the connection rather than reusing it"
        )
        expect(
            EagerPairingRetryRule.decision(for: .unverifiedHost) == .closeConnection,
            "a host that failed verification closes the connection"
        )
        expect(
            EagerPairingRetryRule.decision(for: .unexpectedReply) == .closeConnection,
            "an unexpected reply closes the connection"
        )
        expect(
            EagerPairingRetryRule.decision(for: .unknown) == .closeConnection,
            "an unclassified failure closes the connection"
        )
        print("PASS: every outcome other than a refused code closes the connection")
    }
}

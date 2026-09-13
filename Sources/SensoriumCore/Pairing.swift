import Foundation

public enum PairingError: Error, Equatable {
    case invalidCode
    case noActiveCode
    case codeExpired
    case codeAlreadyConsumed
    case codeAttemptsExhausted
    case invalidDeviceID
}

public struct PairingGrant: Equatable, Sendable {
    public let deviceID: String
}

public struct PairingAuthority: Sendable {
    public static let defaultLifetime: TimeInterval = 300
    /// Wrong guesses an issued code survives. The budget belongs to the code,
    /// not to a connection, so redialling does not buy an attacker a fresh
    /// one: ten out of a million is the total exposure of a code's lifetime.
    /// Ten is far more than a person reading six digits aloud ever needs, and
    /// a user who really burned ten should re-run the pairing verb.
    public static let maximumFailedAttempts = 10

    private var activeCode: String?
    private var expiresAt: Date?
    private var consumed = false
    private var failedAttempts = 0

    public init() {}

    @discardableResult
    public mutating func issue(
        now: Date = Date(),
        lifetime: TimeInterval = PairingAuthority.defaultLifetime,
        code: String? = nil
    ) -> String {
        let selectedCode = code ?? Self.generateCode()
        precondition(Self.isValidCode(selectedCode), "pairing code must contain exactly six decimal digits")
        activeCode = selectedCode
        expiresAt = now.addingTimeInterval(lifetime)
        consumed = false
        failedAttempts = 0
        return selectedCode
    }

    public mutating func approve(code: String, deviceID: String, now: Date = Date()) throws -> PairingGrant {
        guard !deviceID.isEmpty else {
            throw PairingError.invalidDeviceID
        }
        guard let activeCode else {
            throw PairingError.noActiveCode
        }
        guard failedAttempts < Self.maximumFailedAttempts else {
            throw PairingError.codeAttemptsExhausted
        }
        guard Self.constantTimeCompare(activeCode, code).isEqual else {
            failedAttempts += 1
            throw PairingError.invalidCode
        }
        guard !consumed else {
            throw PairingError.codeAlreadyConsumed
        }
        guard let expiresAt else {
            throw PairingError.noActiveCode
        }
        guard now < expiresAt else {
            consumed = true
            throw PairingError.codeExpired
        }

        consumed = true
        return PairingGrant(deviceID: deviceID)
    }

    /// Compares two codes without an early return, so how long the answer
    /// took cannot recover the code a digit at a time. Reports how many
    /// positions were examined, which is the property a test can assert
    /// where a wall-clock measurement would only be flaky.
    ///
    /// Length is compared first and is not a secret: every code is six digits.
    public static func constantTimeCompare(
        _ lhs: String,
        _ rhs: String
    ) -> (isEqual: Bool, comparedPositions: Int) {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else {
            return (false, 0)
        }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return (difference == 0, left.count)
    }

    private static func isValidCode(_ code: String) -> Bool {
        code.count == 6 && code.allSatisfy { $0.isNumber }
    }

    private static func generateCode() -> String {
        var generator = SystemRandomNumberGenerator()
        let value = Int.random(in: 0...999_999, using: &generator)
        return String(format: "%06d", value)
    }
}

import Foundation

/// What a `"Displays"` refusal owes the session's own windows and its
/// Displays-menu state, computed as data so the caller only has to carry
/// it out. That caller, `ClientSessionHost`, is internal and cannot be
/// named by any test target, so
/// this is the seam that makes the reconciliation itself verifiable -- the
/// same reasoning `secondDisplayOutcome(for:)` and `DisplayCountMenuPlan`
/// already follow.
///
/// A refusal always leaves the session at one display and always needs the
/// Displays menu republished, whatever the host's own reason string was and
/// whatever the session's desired count happened to be a moment before.
public struct SecondDisplayRefusalOutcome: Equatable, Sendable {
    public let shouldCloseSecondWindow: Bool
    public let publishedDisplayCount: Int

    public init(shouldCloseSecondWindow: Bool, publishedDisplayCount: Int) {
        self.shouldCloseSecondWindow = shouldCloseSecondWindow
        self.publishedDisplayCount = publishedDisplayCount
    }
}

public enum SecondDisplayRefusalReconciliation {
    /// Whether to close the session's own second window is decided from
    /// `hostWindowExists` alone -- **never** from whether the live
    /// `ClientSessionRunner` that received this particular refusal happens
    /// to hold that window as its own `secondaryWindow`. A runner is
    /// rebuilt fresh on every reconnect (`ClientSessionHost.runOnce()`) and starts with no secondary attached, while the
    /// session's own `windows[1]` can still remember one left open from
    /// before the drop; a refusal that arrives during that reconnect's own
    /// re-ask must still close it. `runnerHasSecondaryWindow` is accepted
    /// here and deliberately left out of the decision, so a test can pin
    /// that fact directly rather than trust a caller to remember it.
    ///
    /// - Parameters:
    ///   - hostWindowExists: whether `windows[1]` is non-nil at the moment
    ///     the refusal arrives -- true for a reconnect-time restore that
    ///     finds a leftover window from before the drop, false for a live
    ///     increase refused before any window was ever opened.
    ///   - runnerHasSecondaryWindow: whether the specific runner that
    ///     received this refusal already holds a `secondaryWindow` of its
    ///     own. Carried for `runner.detachSecondDisplay()`'s own side
    ///     effect (stopping decode, unregistering the router) when true;
    ///     never for this decision.
    public static func outcome(
        hostWindowExists: Bool,
        runnerHasSecondaryWindow: Bool
    ) -> SecondDisplayRefusalOutcome {
        SecondDisplayRefusalOutcome(shouldCloseSecondWindow: hostWindowExists, publishedDisplayCount: 1)
    }
}

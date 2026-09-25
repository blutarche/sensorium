import Foundation

/// Wraps a raw `HostLocalActivitySignal` and corrects it for this host's own
/// input posts -- every event forwarded from the viewer, at either tap, and
/// the relock shortcut -- all of which touch the same `hidSystemState`
/// counter a real key at the machine would. Without this, forwarded input
/// would read as a person at the machine for as long as
/// `HostScreenPresenceRule` requires before it treats this host as
/// unattended again, defeating `HostScreenRelockTracker`'s own
/// local-activity check, which is the one decision this signal feeds --
/// see `HostScreenActivitySignals`. The ask-first presence gate
/// (`HostScreenPresenceRule.assess` in `HostSessionController`)
/// deliberately reads the raw signal instead: over-reporting activity there
/// only means asking the person at the host more often, which is the safe
/// direction, while this discount hiding a real person from that gate
/// would not be.
///
/// Two readings are combined, the more recent of the two winning:
///
/// - The raw reading discounted against this host's own last post: idle
///   time no larger than the time since that post is exactly what the post
///   alone would produce, so it is treated as no evidence of a real person
///   at all.
/// - `HostInjectedHIDActivity.secondsSinceProvenHardwareActivity`, sampled
///   immediately before each of this host's own posts, before that post can
///   touch the raw counter. This is what a real key pressed before this
///   host's own later post would otherwise lose: the raw reading at
///   decision time reflects only the later post, but the sample taken right
///   before it still saw the earlier, genuine input.
public struct SelfPostDiscountingLocalActivitySignal: HostLocalActivitySignal {
    /// How much longer the raw idle reading must be than the time since
    /// this host's own last post before it is trusted as separate from
    /// that post -- covers the gap between posting an event and
    /// `hidSystemState` reflecting it. Chosen, not measured: real hosts have
    /// not confirmed how wide that gap actually is. A local key landing
    /// within this window of one of our own rapid self-posts can still be
    /// missed; measuring the real gap on a host and narrowing this value
    /// accordingly is unverified pending that test.
    public static let discountTolerance: TimeInterval = 1

    private let raw: any HostLocalActivitySignal
    private let ownActivity: any HostInjectedHIDActivity

    public init(
        raw: any HostLocalActivitySignal,
        ownActivity: any HostInjectedHIDActivity = MutableHostInjectedHIDActivity.shared
    ) {
        self.raw = raw
        self.ownActivity = ownActivity
    }

    public func currentReading() -> HostLocalActivityReading {
        let discounted = discountedRawReading()
        // The raw signal itself being broken is left exactly as it is: a
        // proven sample from earlier cannot stand in for it. `.unavailable`
        // already reads as "someone might be there"
        // (`HostScreenPresenceRule.mustAsk`); substituting a stale proven
        // time here could only ever make that read as more absent, which is
        // the direction this whole signal exists to avoid.
        guard case let .idleFor(idleSeconds) = discounted else {
            return discounted
        }
        guard let proven = ownActivity.secondsSinceProvenHardwareActivity() else {
            return discounted
        }
        return .idleFor(min(idleSeconds, proven))
    }

    /// The raw reading, discounted: `.idleFor(.infinity)` in place of an
    /// idle time fully explained by this host's own last post, so it is
    /// never treated as evidence of a real person, but stays distinguishable
    /// from `.unavailable`, which means the raw signal itself is broken.
    private func discountedRawReading() -> HostLocalActivityReading {
        let reading = raw.currentReading()
        guard case let .idleFor(idleSeconds) = reading else {
            return reading
        }
        guard let sincePost = ownActivity.secondsSinceLastPost() else {
            return reading
        }
        // A post of this host's own always makes the counter's last-event
        // time at least as recent as that post, so `idleSeconds` can only
        // be smaller than `sincePost`, never larger, unless something newer
        // than the post has also touched it. Only that -- idle time
        // measurably shorter than time since our own post -- is trusted as
        // a real person; everything else is exactly what the post alone
        // would produce.
        guard idleSeconds < sincePost - Self.discountTolerance else {
            return .idleFor(.infinity)
        }
        return reading
    }
}

/// The two local-activity readings a host-screen session needs, built from
/// one shared raw signal: `presence` is that raw signal itself, and `relock`
/// is the same signal discounted against this host's own posts. Named and
/// split apart so a caller wires each into its own place by construction,
/// rather than passing one shared discounted signal to both and relying on
/// each call site to remember which one it is. See `HostSessionController`'s
/// and `HostSessionCoordinator`'s own doc comments for why the two must
/// differ.
public struct HostScreenActivitySignals: Sendable {
    public let presence: any HostLocalActivitySignal
    public let relock: any HostLocalActivitySignal

    public init(
        raw: any HostLocalActivitySignal,
        ownActivity: any HostInjectedHIDActivity = MutableHostInjectedHIDActivity.shared
    ) {
        presence = raw
        relock = SelfPostDiscountingLocalActivitySignal(raw: raw, ownActivity: ownActivity)
    }
}

import Foundation

/// Records this host's own input posts -- every event forwarded from the
/// viewer, at either tap, and the relock shortcut -- and, sampled immediately
/// before each one, the most recent hardware activity time those posts have
/// not yet touched. All of it feeds `SelfPostDiscountingLocalActivitySignal`,
/// so a post of this host's own is never confused with a real person's.
/// Behind a protocol so a test can hand back a fixed answer instead of
/// measuring real time.
public protocol HostInjectedHIDActivity: Sendable {
    func recordPost()
    /// Seconds since the most recent `recordPost()`, or `nil` before the
    /// first one.
    func secondsSinceLastPost() -> TimeInterval?

    /// Call immediately before any input post of this host's own, while
    /// `hidSystemState`'s idle counter still reflects whatever last touched
    /// it before this post can. The raw idle time read at that instant
    /// proves a hardware-input time -- now minus that idle time -- which is
    /// folded into the record `secondsSinceProvenHardwareActivity` reads,
    /// unless it is explained by this host's own previous post.
    ///
    /// This is what stops a later post of ours from masking a real person's
    /// earlier one: read at decision time, after that later post, the raw
    /// idle counter reflects only the later post and the earlier real input
    /// is gone from it. Sampled here, before the later post can touch it,
    /// the earlier input is caught while it is still visible.
    func sampleBeforePost()

    /// Seconds since the most recent hardware activity `sampleBeforePost`
    /// could prove was not one of this host's own posts, or `nil` if none
    /// has ever been proven.
    func secondsSinceProvenHardwareActivity() -> TimeInterval?
}

public final class MutableHostInjectedHIDActivity: HostInjectedHIDActivity, @unchecked Sendable {
    /// One instance for the whole process: every post site must record into
    /// the same clock the decorator reads from, or a post from one site
    /// could not be told apart from a real person by a reading taken
    /// through another. Defaulted at every call site that needs one, the
    /// same way `HostCaptureAvailability.shared` is, rather than threaded
    /// as an explicit parameter through every construction site.
    public static let shared = MutableHostInjectedHIDActivity()

    private let lock = NSLock()
    private let rawActivity: any HostLocalActivitySignal
    /// `ProcessInfo.processInfo.systemUptime` by default, not `Date()`:
    /// monotonic, so a system clock change can never make this read a post
    /// as having happened in the future or the distant past. Injectable so
    /// a test can script it instead of racing a real clock.
    private let now: @Sendable () -> TimeInterval
    private var lastPost: TimeInterval?
    /// The most recent hardware-input time `sampleBeforePost` could prove,
    /// in the same monotonic clock as `lastPost`. Only ever moves forward:
    /// each sample either advances it to a newer proven time or leaves it
    /// where it was, so one genuine reading is never overwritten by a later
    /// sample that only proves this host's own, older post.
    private var provenHardwareTime: TimeInterval?

    public init(
        rawActivity: any HostLocalActivitySignal = CoreGraphicsLocalActivitySignal(),
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.rawActivity = rawActivity
        self.now = now
    }

    public func recordPost() {
        lock.lock()
        defer { lock.unlock() }
        lastPost = now()
    }

    public func secondsSinceLastPost() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let lastPost else { return nil }
        return now() - lastPost
    }

    public func sampleBeforePost() {
        guard case let .idleFor(idleSeconds) = rawActivity.currentReading() else {
            return
        }
        let sampleTime = now()
        let provenTime = sampleTime - idleSeconds
        lock.lock()
        defer { lock.unlock() }
        // The same tolerance `SelfPostDiscountingLocalActivitySignal` uses
        // to discount a read-time reading, applied here to a sampled one:
        // one slack constant for the one gap it covers, between posting an
        // event and `hidSystemState` reflecting it.
        if let lastPost, provenTime <= lastPost + SelfPostDiscountingLocalActivitySignal.discountTolerance {
            // This proves nothing newer than our own last post: exactly what
            // that post alone would produce.
            return
        }
        if provenHardwareTime == nil || provenTime > provenHardwareTime! {
            provenHardwareTime = provenTime
        }
    }

    public func secondsSinceProvenHardwareActivity() -> TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard let provenHardwareTime else { return nil }
        return now() - provenHardwareTime
    }
}

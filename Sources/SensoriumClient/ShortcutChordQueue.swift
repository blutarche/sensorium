/// Runs whole chords one after another.
///
/// A chord is several key events that only mean anything together, so two of
/// them must never be in flight at once: interleaved, one press's Command-up
/// lands between the other's Command-down and its key, and the far machine is left
/// with a chord nobody typed. Each piece of work waits for the one queued
/// before it, so presses are serialised without any of them being dropped.
public actor ShortcutChordQueue {
    private var tail: Task<Void, Never>?

    public init() {}

    public func enqueue(_ send: @escaping @Sendable () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await send()
        }
    }

    /// Waits for everything queued so far. Used where a caller has to observe
    /// the result of a press rather than only start it.
    public func drain() async {
        await tail?.value
    }
}

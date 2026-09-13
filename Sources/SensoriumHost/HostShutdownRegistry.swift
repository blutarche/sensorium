/// Every teardown a deliberate quit has to run before the process ends.
///
/// Quitting from the menu bar must end a live session exactly the way the
/// transport dying already ends one — workspace windows down, canvas displays
/// released — rather than calling `exit()` underneath it and leaving macOS to
/// reclaim a display Sensorium created. Registrations are dropped as each
/// session ends on its own, so a day of reconnects cannot pile up teardowns
/// for sessions long gone.
@MainActor
public final class HostShutdownRegistry {
    public typealias Teardown = @MainActor () async -> Void

    private var teardowns: [(ticket: Int, run: Teardown)] = []
    private var nextTicket = 0
    private var inFlight: Task<Void, Never>?

    public init() {}

    public var liveTeardownCount: Int { teardowns.count }

    @discardableResult
    public func register(_ teardown: @escaping Teardown) -> Int {
        nextTicket += 1
        teardowns.append((ticket: nextTicket, run: teardown))
        return nextTicket
    }

    public func deregister(_ ticket: Int) {
        teardowns.removeAll { $0.ticket == ticket }
    }

    /// Runs every teardown once, in registration order — the listener stops
    /// accepting before the sessions it accepted are torn down — and empties
    /// the registry first, so a second quit while the first is still in
    /// flight cannot run any of them twice.
    ///
    /// A second call joins the one in flight rather than returning as
    /// though nothing were pending, so a caller reading that return as
    /// "torn down" cannot race a teardown still running.
    public func shutDown() async {
        if let inFlight {
            await inFlight.value
            return
        }
        let pending = teardowns
        teardowns.removeAll()
        let task = Task { @MainActor in
            for entry in pending {
                await entry.run()
            }
        }
        inFlight = task
        await task.value
        inFlight = nil
    }
}

/// Identifies one decoder surface: a surface number means nothing without the
/// display it belongs to.
public struct HardwareSurfaceKey: Hashable, Sendable {
    public let display: UInt
    public let surface: UInt32

    public init(display: UInt, surface: UInt32) {
        self.display = display
        self.surface = surface
    }
}

/// Remembers what the GPU was given for each surface of a decoder's pool, so a
/// surface that comes round again is not exported and imported a second time.
///
/// A decoder cycles through a fixed pool, and a surface keeps the same memory
/// for the pool's whole life. What was imported from it is therefore valid
/// until the pool goes away or changes shape, and the cache says so by
/// handing back everything it drops: a caller that destroys exactly what
/// comes out of `prepare`, `insert` and `removeAll` cannot leak an import.
///
/// Pure bookkeeping: `Entry` is whatever the caller has to destroy later, and
/// no GPU object is touched here.
public struct HardwareSurfaceImportCache<Entry> {
    /// Larger than any pool a decoder allocates for one stream, so a stream
    /// never evicts its own live surfaces, and small enough to bound the
    /// memory held for a pool that keeps changing.
    public static var defaultCapacity: Int { 64 }

    private let capacity: Int
    private var pool: UInt?
    private var width = 0
    private var height = 0
    private var entries: [HardwareSurfaceKey: Entry] = [:]
    /// Least recently used first.
    private var recency: [HardwareSurfaceKey] = []

    public init(capacity: Int = HardwareSurfaceImportCache.defaultCapacity) {
        self.capacity = max(capacity, 1)
    }

    public var count: Int { entries.count }

    /// Declares which pool and picture size the next lookups belong to.
    /// Anything cached for another pool or size is dropped and returned: a
    /// reopened decoder allocates a new pool that may reuse old surface
    /// numbers for different memory.
    public mutating func prepare(pool: UInt, width: Int, height: Int) -> [Entry] {
        guard self.pool != pool || self.width != width || self.height != height else { return [] }
        let dropped = removeAll()
        self.pool = pool
        self.width = width
        self.height = height
        return dropped
    }

    /// The pool the cache currently holds entries for, if any.
    public var currentPool: UInt? { pool }

    public mutating func lookup(_ key: HardwareSurfaceKey) -> Entry? {
        guard let entry = entries[key] else { return nil }
        if let index = recency.firstIndex(of: key) {
            recency.remove(at: index)
        }
        recency.append(key)
        return entry
    }

    /// Stores an entry and returns whatever it displaced: a previous entry for
    /// the same key, and the least recently used ones past capacity.
    public mutating func insert(_ entry: Entry, for key: HardwareSurfaceKey) -> [Entry] {
        var dropped: [Entry] = []
        if let previous = entries[key] {
            dropped.append(previous)
            if let index = recency.firstIndex(of: key) {
                recency.remove(at: index)
            }
        }
        entries[key] = entry
        recency.append(key)
        while entries.count > capacity, let oldest = recency.first {
            recency.removeFirst()
            if let evicted = entries.removeValue(forKey: oldest) {
                dropped.append(evicted)
            }
        }
        return dropped
    }

    /// Empties the cache and forgets the pool, returning every entry.
    public mutating func removeAll() -> [Entry] {
        let dropped = recency.compactMap { entries[$0] }
        entries = [:]
        recency = []
        pool = nil
        width = 0
        height = 0
        return dropped
    }
}

import SensoriumClient

func testHardwareSurfaceImportCacheTests() {
    let a = HardwareSurfaceKey(display: 1, surface: 10)
    let b = HardwareSurfaceKey(display: 1, surface: 11)
    let otherDisplay = HardwareSurfaceKey(display: 2, surface: 10)

    var cache = HardwareSurfaceImportCache<String>(capacity: 3)
    expect(cache.prepare(pool: 7, width: 1920, height: 1080).isEmpty, "the first pool drops nothing")
    expect(cache.insert("a", for: a).isEmpty, "inserting under capacity drops nothing")
    expect(cache.lookup(a) == "a", "a surface seen before is found")
    expect(cache.lookup(b) == nil, "a surface not yet imported is a miss")
    expect(cache.lookup(otherDisplay) == nil, "the same surface number on another display is a different surface")
    expect(cache.prepare(pool: 7, width: 1920, height: 1080).isEmpty, "the same pool and size keeps every entry")
    expect(cache.lookup(a) == "a", "entries survive a repeated prepare")

    expect(
        cache.prepare(pool: 8, width: 1920, height: 1080) == ["a"],
        "a new pool hands back every entry so the caller destroys it"
    )
    expect(cache.count == 0 && cache.lookup(a) == nil, "a new pool starts empty")
    _ = cache.insert("a2", for: a)
    expect(
        cache.prepare(pool: 8, width: 1280, height: 720) == ["a2"],
        "a new picture size hands back every entry"
    )

    let replaced = cache.insert("a3", for: a) + cache.insert("a4", for: a)
    expect(replaced == ["a3"], "re-inserting a key hands back the entry it replaced")

    var small = HardwareSurfaceImportCache<Int>(capacity: 2)
    _ = small.prepare(pool: 1, width: 4, height: 4)
    let k1 = HardwareSurfaceKey(display: 1, surface: 1)
    let k2 = HardwareSurfaceKey(display: 1, surface: 2)
    let k3 = HardwareSurfaceKey(display: 1, surface: 3)
    _ = small.insert(1, for: k1)
    _ = small.insert(2, for: k2)
    _ = small.lookup(k1)
    expect(small.insert(3, for: k3) == [2], "past capacity the least recently used entry is dropped")
    expect(small.lookup(k1) == 1 && small.lookup(k3) == 3 && small.lookup(k2) == nil, "the recent entries stay")

    var everything = small.removeAll().sorted()
    expect(everything == [1, 3], "removeAll returns every remaining entry")
    everything = small.removeAll()
    expect(everything.isEmpty && small.currentPool == nil, "removeAll leaves nothing behind and forgets the pool")

    // Released-once bookkeeping across a reset: every inserted entry comes
    // back out exactly once.
    var live = Set<Int>()
    var tracked = HardwareSurfaceImportCache<Int>(capacity: 4)
    var next = 0
    func drop(_ entries: [Int]) {
        for entry in entries {
            expect(live.remove(entry) != nil, "entry \(entry) was released twice or never held")
        }
    }
    for generation in 0..<5 {
        drop(tracked.prepare(pool: UInt(generation), width: 64, height: 64))
        for surface in 0..<9 {
            let key = HardwareSurfaceKey(display: 1, surface: UInt32(surface % 6))
            if tracked.lookup(key) == nil {
                next += 1
                live.insert(next)
                drop(tracked.insert(next, for: key))
            }
        }
    }
    drop(tracked.removeAll())
    expect(live.isEmpty, "no entry survives a reset or teardown unreleased, \(live.count) leaked")
    print("PASS: hardware surface import cache")
}

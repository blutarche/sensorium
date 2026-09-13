import Foundation
import SensoriumClient

private func temporaryShortcutStripPinMemoryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-shortcut-strip-pin-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("shortcut-strip-pin.json")
}

/// The memory that makes the strip's pin button stay on across launches,
/// verified without touching a live strip.
func testShortcutStripPinMemoryTests() {
    do {
        // The in-memory store starts unpinned, and remembers whatever
        // was last set, for the whole viewer rather than per machine.
        let store = InMemoryShortcutStripPinMemoryStore()
        expect(!store.isPinned(), "nothing is remembered before anything is ever pinned")
        store.remember(isPinned: true)
        expect(store.isPinned(), "pinning round-trips through the store")
        store.remember(isPinned: false)
        expect(!store.isPinned(), "unpinning replaces the earlier choice rather than keeping it")
        print("PASS: the pin memory store remembers the last choice, for the whole viewer")
    }

    do {
        // The file store round-trips through a real file, owner-only,
        // and a corrupt file reads back as unpinned rather than crashing.
        let url = temporaryShortcutStripPinMemoryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileShortcutStripPinMemoryStore(url: url)
        expect(!store.isPinned(), "a file that has never been written reads as unpinned")
        store.remember(isPinned: true)
        let reloaded = FileShortcutStripPinMemoryStore(url: url)
        expect(reloaded.isPinned(), "a fresh store reading the same file finds what an earlier one wrote")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        expect(
            (attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            "the file is owner-readable only, got \(String(describing: attributes?[.posixPermissions]))"
        )

        try? Data("not json at all".utf8).write(to: url)
        let corrupted = FileShortcutStripPinMemoryStore(url: url)
        expect(!corrupted.isPinned(), "a corrupt file reads as unpinned rather than crashing")
        expect(
            !ShortcutStripPinFileCoding.decode(Data("not json at all".utf8)),
            "the coding layer itself treats anything that is not the recorded shape as unpinned"
        )
        print("PASS: the pin memory file store round-trips, is owner-only, and a corrupt file reads as unpinned")
    }
}

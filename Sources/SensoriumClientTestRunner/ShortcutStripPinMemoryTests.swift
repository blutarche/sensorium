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
        // The in-memory store starts pinned, and remembers whatever
        // was last set, for the whole viewer rather than per machine.
        let store = InMemoryShortcutStripPinMemoryStore()
        expect(store.isPinned(), "nothing is remembered before anything is ever chosen, so the strip is pinned")
        store.remember(isPinned: false)
        expect(!store.isPinned(), "unpinning is remembered")
        store.remember(isPinned: true)
        expect(store.isPinned(), "pinning round-trips through the store")
        store.remember(isPinned: false)
        expect(!store.isPinned(), "unpinning replaces the earlier choice rather than keeping it")
        print("PASS: the pin memory store remembers the last choice, for the whole viewer")
    }

    do {
        // The file store round-trips through a real file, owner-only,
        // and a corrupt file reads back as the default, pinned, rather than crashing.
        let url = temporaryShortcutStripPinMemoryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileShortcutStripPinMemoryStore(url: url)
        expect(store.isPinned(), "a file that has never been written reads as pinned")
        store.remember(isPinned: false)
        let reloaded = FileShortcutStripPinMemoryStore(url: url)
        expect(!reloaded.isPinned(), "a fresh store reading the same file finds the unpin an earlier one wrote")
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        expect(
            (attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            "the file is owner-readable only, got \(String(describing: attributes?[.posixPermissions]))"
        )

        try? Data("not json at all".utf8).write(to: url)
        let corrupted = FileShortcutStripPinMemoryStore(url: url)
        expect(corrupted.isPinned(), "a corrupt file reads as pinned rather than crashing")
        expect(
            ShortcutStripPinFileCoding.decode(Data("not json at all".utf8)),
            "the coding layer itself treats anything that is not the recorded shape as the default, pinned"
        )
        expect(
            !ShortcutStripPinFileCoding.decode(ShortcutStripPinFileCoding.encode(false) ?? Data()),
            "an explicit unpin is not mistaken for the default"
        )
        print("PASS: the pin memory file store round-trips, is owner-only, and a corrupt file reads as pinned")
    }

    do {
        // The Linux session window builds its chrome from this store and
        // writes it on every pin toggle.
        let unpinned = InMemoryShortcutStripPinMemoryStore(isPinned: false)
        var chrome = SessionChromeState(pinMemoryStore: unpinned)
        expect(!chrome.strip.isPinned, "a store holding an unpin starts the chrome unpinned")
        chrome.togglePinRequested(now: 0, remembering: unpinned)
        expect(chrome.strip.isPinned && unpinned.isPinned(), "pinning is written to the store")
        chrome.togglePinRequested(now: 1, remembering: unpinned)
        expect(!chrome.strip.isPinned && !unpinned.isPinned(), "unpinning is written to the store")

        let pinned = InMemoryShortcutStripPinMemoryStore(isPinned: true)
        expect(SessionChromeState(pinMemoryStore: pinned).strip.isPinned, "a store holding a pin starts the chrome pinned")
        expect(
            SessionChromeState(pinMemoryStore: InMemoryShortcutStripPinMemoryStore()).strip.isPinned,
            "a store with nothing remembered starts the chrome pinned"
        )
        print("PASS: the session chrome starts from the remembered pin and writes every toggle back")
    }
}

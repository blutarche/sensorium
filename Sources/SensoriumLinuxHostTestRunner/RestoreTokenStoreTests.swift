#if os(Linux)

import Foundation
import SensoriumLinuxHost

private func scratchDirectory(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-linux-host-test-\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func mode(of url: URL) -> Int {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return -1 }
    return Int(info.st_mode & 0o7777)
}

func testTokenStoreRoundTripsOwnerOnly() throws {
    let root = scratchDirectory("token-roundtrip")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RestoreTokenStore(dataRoot: root.appendingPathComponent("sensorium-host"))
    expect(store.load() == nil, "a fresh store has no token")
    try store.save("first-token")
    expect(store.load() == "first-token", "the saved token reads back")
    expect(mode(of: store.fileURL) == 0o600, "the token file is owner-only, got \(String(mode(of: store.fileURL), radix: 8))")
    expect(mode(of: store.fileURL.deletingLastPathComponent()) == 0o700, "the data folder is owner-only")
}

func testTokenStoreRotationReplacesAtomicallyAndLeavesNoTemporaryFile() throws {
    let root = scratchDirectory("token-rotation")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("sensorium-host")
    let store = RestoreTokenStore(dataRoot: folder)
    try store.save("old")
    try store.save("new")
    expect(store.load() == "new", "the newest token wins")
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
    expect(names == [RestoreTokenStore.fileName], "rotation leaves only the token file, got \(names)")
}

func testTokenStoreTightensALooseExistingFile() throws {
    let root = scratchDirectory("token-loose")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("sensorium-host")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let store = RestoreTokenStore(dataRoot: folder)
    try Data("{}".utf8).write(to: store.fileURL)
    chmod(store.fileURL.path, 0o644)
    try store.save("tight")
    expect(mode(of: store.fileURL) == 0o600, "a loose file is replaced by an owner-only one")
}

func testTokenStoreReadsGarbageAsNoToken() throws {
    let root = scratchDirectory("token-garbage")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RestoreTokenStore(dataRoot: root)
    try Data("not json".utf8).write(to: store.fileURL)
    expect(store.load() == nil, "an unreadable file reads as no token")
    try Data("{\"restoreToken\":\"\"}".utf8).write(to: store.fileURL)
    expect(store.load() == nil, "an empty token reads as no token")
}

func testTokenStoreClearRemovesTheToken() throws {
    let root = scratchDirectory("token-clear")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = RestoreTokenStore(dataRoot: root)
    try store.save("gone-soon")
    try store.clear()
    expect(store.load() == nil, "a cleared store has no token")
    try store.clear()
}

func testTokenStoreDataRootFollowsTheXDGRule() {
    let home = URL(fileURLWithPath: "/home/example", isDirectory: true)
    let configured = RestoreTokenStore.defaultDataRoot(environment: ["XDG_DATA_HOME": "/data/xdg"], homeDirectory: home)
    expect(configured.path == "/data/xdg/sensorium-host", "XDG_DATA_HOME is honored")
    let unset = RestoreTokenStore.defaultDataRoot(environment: [:], homeDirectory: home)
    expect(unset.path == "/home/example/.local/share/sensorium-host", "the default is under the home folder")
    let empty = RestoreTokenStore.defaultDataRoot(environment: ["XDG_DATA_HOME": ""], homeDirectory: home)
    expect(empty.path == unset.path, "an empty XDG_DATA_HOME is treated as unset")
}

func restoreTokenStoreTests() -> [NamedTest] { [
    ("the token store round-trips owner-only", { try! testTokenStoreRoundTripsOwnerOnly() }),
    ("token rotation replaces atomically and leaves no temporary file", { try! testTokenStoreRotationReplacesAtomicallyAndLeavesNoTemporaryFile() }),
    ("saving over a loose file leaves an owner-only one", { try! testTokenStoreTightensALooseExistingFile() }),
    ("an unreadable or empty token file reads as no token", { try! testTokenStoreReadsGarbageAsNoToken() }),
    ("clearing the token store removes the token", { try! testTokenStoreClearRemovesTheToken() }),
    ("the data root follows the XDG rule", testTokenStoreDataRootFollowsTheXDGRule)
] }

#endif

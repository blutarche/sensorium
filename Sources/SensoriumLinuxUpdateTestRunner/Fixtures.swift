import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

@inline(__always)
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        print("FAIL: \(message)")
        exit(1)
    }
}

/// A fresh, empty directory under the system's temporary folder. Every test
/// works inside one and removes it when it ends.
func makeTemporaryDirectory(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-linux-update-test-\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    chmod(url.path, 0o700)
    return url
}

/// Removes a test directory, first giving back write permission to any folder
/// a test took it from.
func removeTemporaryDirectory(_ url: URL) {
    if let walker = FileManager.default.enumerator(atPath: url.path) {
        for case let relative as String in walker {
            let path = url.appendingPathComponent(relative).path
            var info = stat()
            if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
                chmod(path, 0o700)
            }
        }
    }
    chmod(url.path, 0o700)
    try? FileManager.default.removeItem(at: url)
}

func posixMode(of url: URL) -> Int {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return -1 }
    return Int(info.st_mode & 0o7777)
}

func fileType(of url: URL) -> mode_t? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return nil }
    return info.st_mode & S_IFMT
}

func symlinkTarget(of url: URL) -> String? {
    try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)
}

func writeFile(_ text: String, to url: URL, mode: mode_t = 0o644) {
    try! FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: url)
    chmod(url.path, mode)
}

let sampleDigest = String(repeating: "ab", count: 32)

func sampleManifestObject(version: String = "0.6.0") -> [String: Any] {
    [
        "format": 1,
        "version": version,
        "file": "Sensorium-\(version)-linux-x86_64.tar.gz",
        "size": 4_194_304,
        "sha256": sampleDigest
    ]
}

func serialized(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

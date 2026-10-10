#if os(macOS)
import Foundation

@inline(__always)
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        print("FAIL: \(message)")
        exit(1)
    }
}

/// Waits for a child process to stop, ending it first when `terminating`.
/// `Process.waitUntilExit()` spins the calling thread's run loop and can
/// wait forever on a Swift concurrency thread even after the child is gone,
/// so this polls `isRunning` instead. A child still running after `grace`
/// seconds is killed; one that survives that fails the test.
func endProcess(_ process: Process, terminating: Bool = true, grace: TimeInterval = 5) {
    if terminating {
        process.terminate()
    }
    func stopped(within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning {
            if Date() >= deadline {
                return false
            }
            usleep(10_000)
        }
        return true
    }
    if stopped(within: grace) {
        return
    }
    kill(process.processIdentifier, SIGKILL)
    expect(stopped(within: 5), "the child process \(process.processIdentifier) did not stop after \(grace) seconds or after SIGKILL")
}

/// A fresh, empty directory under the system's temporary folder. Every test
/// works inside one and removes it when it ends.
func makeTemporaryDirectory(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-update-test-\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Removes a test directory, first giving back write permission to any folder
/// a test took it from.
func removeTemporaryDirectory(_ url: URL) {
    if let walker = FileManager.default.enumerator(atPath: url.path) {
        for case let relative as String in walker {
            chmod(url.appendingPathComponent(relative).path, 0o700)
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

let sampleDigest = String(repeating: "ab", count: 32)

/// The manifest shape the design names, as a dictionary a test can change one
/// field of before serializing it.
func sampleManifestObject(version: String = "0.4.0") -> [String: Any] {
    [
        "format": 1,
        "version": version,
        "minimumMacOS": "13.0",
        "apps": [
            "viewer": [
                "bundleIdentifier": "com.sensorium.viewer",
                "file": "Sensorium-\(version).zip",
                "size": 4_194_304,
                "sha256": sampleDigest
            ],
            "host": [
                "bundleIdentifier": "com.sensorium.host",
                "file": "Sensorium-Host-\(version).zip",
                "size": 4_194_304,
                "sha256": sampleDigest
            ]
        ]
    ]
}

func serialized(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
}

func manifestObject(_ object: [String: Any], settingApp role: String, field: String, to value: Any?) -> [String: Any] {
    var copy = object
    var apps = copy["apps"] as! [String: Any]
    var app = apps[role] as! [String: Any]
    app[field] = value
    apps[role] = app
    copy["apps"] = apps
    return copy
}
#endif

import Foundation
import SensoriumCore

/// What a staged update runs with `--update-self-test` before it may be
/// installed: can this build read the files the viewer needs to start a
/// session? Those are the saved machines and this machine's key.
///
/// A file that does not exist passes: a viewer that has never paired has
/// neither. One that exists but cannot be read or parsed fails. Nothing is
/// written, created or removed, so the stores' own loaders are not used:
/// they tidy away partial files left by an interrupted write, and the key
/// store makes a key when there is none.
public enum ViewerUpdateSelfTest {
    /// `versionLine` is printed first when given: the Linux updater accepts
    /// a staged binary only when its first line is `Sensorium <version>`.
    public static func run(
        applicationSupportDirectory directory: URL,
        versionLine: String? = nil,
        output: (String) -> Void = { print($0) }
    ) -> Int32 {
        if let versionLine {
            output(versionLine)
        }
        let savedHosts = directory.appendingPathComponent(ViewerApplication.savedHostFileName)
        if let failure = check(savedHosts, readsAs: savedMachinesParse) {
            output("Sensorium: update self-test: the saved machines \(failure)")
            return 1
        }
        let identity = directory.appendingPathComponent(ViewerApplication.identityFileName)
        if let failure = check(identity, readsAs: identityParses) {
            output("Sensorium: update self-test: this machine's key \(failure)")
            return 1
        }
        output("Sensorium: update self-test passed")
        return 0
    }

    /// Nil when the file is absent or reads as `parses` expects; otherwise
    /// says what is wrong with it.
    private static func check(_ url: URL, readsAs parses: (Data) -> Bool) -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else {
            return "could not be read"
        }
        return parses(data) ? nil : "could not be parsed"
    }

    /// The two shapes `SavedHostFileCoding` reads: a list, or the single
    /// machine an older viewer wrote. Unlike that coding, anything else
    /// fails rather than reading as no machines.
    private static func savedMachinesParse(_ data: Data) -> Bool {
        let decoder = JSONDecoder()
        return (try? decoder.decode([SavedHost].self, from: data)) != nil
            || (try? decoder.decode(SavedHost.self, from: data)) != nil
    }

    /// The shape `FileDeviceIdentityStore` writes.
    private static func identityParses(_ data: Data) -> Bool {
        struct StoredIdentity: Decodable {
            let privateKey: String
        }
        guard let stored = try? JSONDecoder().decode(StoredIdentity.self, from: data),
              let key = Data(base64Encoded: stored.privateKey) else {
            return false
        }
        return (try? DeviceIdentity(privateKeyData: key)) != nil
    }
}

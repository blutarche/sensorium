import Foundation

/// Which Linux app an update is for. The viewer and the host share one
/// engine; every name that tells their releases, folders and records apart
/// is here.
public struct LinuxUpdateApp: Equatable, Sendable {
    /// The one file a release archive holds, and the installed executable.
    public let binaryName: String
    /// The archive is `<archivePrefix><version>-linux-x86_64.tar.gz`.
    public let archivePrefix: String
    /// The signed manifest's file name. Its signature adds `.sig`.
    public let manifestName: String
    /// What the app remembers between checks, in its data folder.
    public let stateFileName: String
    /// The app's data folder under `$XDG_DATA_HOME`, where it keeps its own
    /// records and installs its versions.
    public let dataFolderName: String
    /// The launcher entry is `<desktopID>.desktop` and its icon
    /// `<desktopID>.png`.
    public let desktopID: String
    /// The field code the launcher entry's `Exec` line ends with, if any.
    public let execFieldCode: String?
    /// The self-test prints `<selfTestName> <version>` as its first line.
    public let selfTestName: String

    public static let viewer = LinuxUpdateApp(
        binaryName: "Sensorium",
        archivePrefix: "Sensorium-",
        manifestName: "sensorium-update-linux-x86_64.json",
        stateFileName: "viewer-update-state.json",
        dataFolderName: "sensorium",
        desktopID: "com.sensorium.viewer",
        execFieldCode: "%u",
        selfTestName: "Sensorium"
    )

    public static let host = LinuxUpdateApp(
        binaryName: "sensorium-host",
        archivePrefix: "Sensorium-Host-",
        manifestName: "sensorium-host-update-linux-x86_64.json",
        stateFileName: "host-update-state.json",
        dataFolderName: "sensorium-host",
        desktopID: "com.sensorium.host",
        execFieldCode: nil,
        selfTestName: "Sensorium Host"
    )

    /// The first line the self-test of `version` prints.
    public func selfTestLine(for version: LinuxUpdateVersion) -> String {
        "\(selfTestName) \(version)"
    }
}

#if os(Linux)
import Foundation
import SensoriumHost

/// The files in the host's data folder that say who it is and whom it
/// serves.
public enum LinuxHostDataFiles {
    public static let deviceIdentity = "device-identity.json"
    public static let tlsIdentity = "host-tls-identity.json"
    public static let approvedDevices = "approved-devices.json"
}

/// `--update-self-test`, run by the running host on a newly downloaded
/// version before installing it. It prints `versionLine` first, which the
/// updater compares with the release's version, then reads, without
/// changing, the identities and paired machines the host serves with.
/// Opens no display, bus or listener.
public enum LinuxHostUpdateSelfTest {
    public static func run(
        dataFolder: URL,
        versionLine: String,
        output: (String) -> Void = { print($0) }
    ) -> Int32 {
        output(versionLine)
        let files = HostUpdateSelfTest.Files(
            deviceIdentity: dataFolder.appendingPathComponent(LinuxHostDataFiles.deviceIdentity),
            tlsIdentity: dataFolder.appendingPathComponent(LinuxHostDataFiles.tlsIdentity),
            approvedDevices: dataFolder.appendingPathComponent(LinuxHostDataFiles.approvedDevices)
        )
        return HostUpdateSelfTest.run(files) { output("sensorium-host: update self-test: \($0)") }
    }
}
#endif

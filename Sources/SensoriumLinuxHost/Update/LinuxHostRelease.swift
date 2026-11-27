#if os(Linux)
import CWaylandGlue

/// The release this build is: the version the package build stamps in, or
/// `development` for a build from source, which does not update itself.
public enum LinuxHostRelease {
    public static let version = String(cString: sensorium_build_version())
}
#endif

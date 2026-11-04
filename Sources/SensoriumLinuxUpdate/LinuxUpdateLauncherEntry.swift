import Foundation

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum LinuxUpdateLauncherEntryError: Error, Equatable {
    case unreadableEntry
    case noExecLine
    /// The path cannot be written as an `Exec` argument: it is relative or
    /// holds a control character.
    case unwritablePath
    case couldNotWrite(String)
}

/// The first update of a viewer the package installed, as section 11.3 of
/// `docs/self-update-design.md` describes: a launcher entry and icons in the
/// person's own applications and icons folders, which take precedence over
/// the package's because they carry the same names. The package's own files
/// are read, never changed.
public enum LinuxUpdateLauncherEntry {
    public static let desktopFileName = "com.sensorium.viewer.desktop"
    public static let iconFileName = "com.sensorium.viewer.png"

    /// Writes `applicationsDirectory/com.sensorium.viewer.desktop`, a copy of
    /// `packagedDesktopFile` whose every `Exec=` line runs
    /// `<dataRoot>/current/Sensorium %u`, and copies each
    /// `hicolor/<size>/apps/com.sensorium.viewer.png` under
    /// `packagedIconsDirectory` to the same place under `iconsDirectory`.
    /// Only regular files are copied; a link is skipped. Every file is
    /// replaced in one rename, so running this again changes nothing.
    public static func install(
        dataRoot: URL,
        packagedDesktopFile: URL,
        packagedIconsDirectory: URL,
        applicationsDirectory: URL,
        iconsDirectory: URL
    ) throws {
        guard let packaged = try? String(contentsOf: packagedDesktopFile, encoding: .utf8) else {
            throw LinuxUpdateLauncherEntryError.unreadableEntry
        }
        let executable = dataRoot
            .appendingPathComponent(LinuxUpdateInstallation.currentLinkName)
            .appendingPathComponent(LinuxUpdateInstallation.executableName)
        let entry = try rewrittenEntry(packaged, executablePath: executable.path)

        for (source, destination) in iconCopies(from: packagedIconsDirectory, to: iconsDirectory) {
            guard let data = try? Data(contentsOf: source) else { continue }
            try replace(destination, with: data)
        }
        try replace(applicationsDirectory.appendingPathComponent(desktopFileName), with: Data(entry.utf8))
    }

    static func rewrittenEntry(_ packaged: String, executablePath: String) throws -> String {
        let exec = "Exec=" + (try execArgument(for: executablePath)) + " %u"
        var found = false
        let lines = packaged.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard line.hasPrefix("Exec=") else { return String(line) }
            found = true
            return exec
        }
        guard found else { throw LinuxUpdateLauncherEntryError.noExecLine }
        return lines.joined(separator: "\n")
    }

    /// The Desktop Entry Specification's rules for one `Exec` argument: an
    /// argument holding a reserved character is double-quoted, with `"`,
    /// `` ` ``, `$` and `\` escaped by a backslash inside the quotes. The
    /// value is also a string, whose own escaping doubles every backslash,
    /// and `%` starts a field code, so a literal one is doubled.
    public static func execArgument(for path: String) throws -> String {
        guard path.hasPrefix("/"), !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            throw LinuxUpdateLauncherEntryError.unwritablePath
        }
        let reserved: Set<Character> = [" ", "\"", "'", "\\", ">", "<", "~", "|", "&", ";", "$", "*", "?", "#", "(", ")", "`"]
        var argument = path
        if path.contains(where: reserved.contains) {
            var quoted = "\""
            for character in path {
                if ["\"", "`", "$", "\\"].contains(character) {
                    quoted.append("\\")
                }
                quoted.append(character)
            }
            quoted.append("\"")
            argument = quoted
        }
        return argument
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "%%")
    }

    private static func iconCopies(from packaged: URL, to destination: URL) -> [(URL, URL)] {
        let theme = packaged.appendingPathComponent("hicolor", isDirectory: true)
        let sizes = ((try? FileManager.default.contentsOfDirectory(atPath: theme.path)) ?? []).sorted()
        return sizes.compactMap { size in
            guard !size.hasPrefix("."), isKind(theme.appendingPathComponent(size).path, S_IFDIR),
                  isKind(theme.appendingPathComponent("\(size)/apps").path, S_IFDIR) else {
                return nil
            }
            let source = theme.appendingPathComponent("\(size)/apps/\(iconFileName)")
            guard isKind(source.path, S_IFREG) else { return nil }
            return (source, destination.appendingPathComponent("hicolor/\(size)/apps/\(iconFileName)"))
        }
    }

    private static func isKind(_ path: String, _ kind: mode_t) -> Bool {
        lstatInfo(path).map { $0.st_mode & S_IFMT == kind } ?? false
    }

    /// A new file beside `destination`, mode 0644, renamed over it.
    private static func replace(_ destination: URL, with data: Data) throws {
        let folder = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        } catch {
            throw LinuxUpdateLauncherEntryError.couldNotWrite(folder.path)
        }
        let temporary = folder.appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw LinuxUpdateLauncherEntryError.couldNotWrite(destination.path) }
        let written = LinuxUpdateArchive.writeAll(data, to: descriptor) && fchmod(descriptor, 0o644) == 0 && fsync(descriptor) == 0
        close(descriptor)
        guard written, rename(temporary.path, destination.path) == 0 else {
            unlink(temporary.path)
            throw LinuxUpdateLauncherEntryError.couldNotWrite(destination.path)
        }
    }
}

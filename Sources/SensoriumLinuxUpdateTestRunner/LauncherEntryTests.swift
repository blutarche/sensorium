import Foundation
import SensoriumLinuxUpdate

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private let packagedEntry = """
[Desktop Entry]
Type=Application
Name=Sensorium
Comment=Work on another machine
Exec=Sensorium %u
Icon=com.sensorium.viewer
Terminal=false
MimeType=x-scheme-handler/sensorium;

"""

private func entries(of directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
}

func testLauncherEntryRunsCurrentAndTheIconsAreCopied() {
    let directory = makeTemporaryDirectory("launcher")
    defer { removeTemporaryDirectory(directory) }
    let root = directory.appendingPathComponent("data/sensorium", isDirectory: true)
    let packaged = directory.appendingPathComponent("usr/share/applications/com.sensorium.viewer.desktop")
    writeFile(packagedEntry, to: packaged)
    let packagedIcons = directory.appendingPathComponent("usr/share/icons", isDirectory: true)
    for size in ["16x16", "48x48", "256x256"] {
        writeFile("icon \(size)", to: packagedIcons.appendingPathComponent("hicolor/\(size)/apps/com.sensorium.viewer.png"))
    }
    writeFile("another app", to: packagedIcons.appendingPathComponent("hicolor/32x32/apps/other.png"))
    let secret = directory.appendingPathComponent("secret")
    writeFile("not an icon", to: secret)
    try! FileManager.default.createDirectory(at: packagedIcons.appendingPathComponent("hicolor/64x64/apps"), withIntermediateDirectories: true)
    expect(
        symlink(secret.path, packagedIcons.appendingPathComponent("hicolor/64x64/apps/com.sensorium.viewer.png").path) == 0,
        "a test can plant a linked icon"
    )
    let applications = directory.appendingPathComponent("data/applications", isDirectory: true)
    let icons = directory.appendingPathComponent("data/icons", isDirectory: true)

    func install() {
        do {
            try LinuxUpdateLauncherEntry.install(
                dataRoot: root,
                packagedDesktopFile: packaged,
                packagedIconsDirectory: packagedIcons,
                applicationsDirectory: applications,
                iconsDirectory: icons
            )
        } catch {
            expect(false, "the launcher entry installs, got \(error)")
        }
    }
    install()

    let entry = applications.appendingPathComponent("com.sensorium.viewer.desktop")
    let written = (try? String(contentsOf: entry, encoding: .utf8)) ?? ""
    let expectedExec = "Exec=\(root.path)/current/Sensorium %u"
    expect(written == packagedEntry.replacingOccurrences(of: "Exec=Sensorium %u", with: expectedExec), "the entry is the packaged one with Exec running current, got \(written)")
    expect(posixMode(of: entry) == 0o644, "the entry is readable like any launcher entry")
    for size in ["16x16", "48x48", "256x256"] {
        let icon = icons.appendingPathComponent("hicolor/\(size)/apps/com.sensorium.viewer.png")
        expect((try? String(contentsOf: icon, encoding: .utf8)) == "icon \(size)", "the \(size) icon is copied")
        expect(posixMode(of: icon) == 0o644, "the \(size) icon is readable")
    }
    expect(entries(of: icons.appendingPathComponent("hicolor")) == ["16x16", "256x256", "48x48"], "only this app's real icons are copied, and no linked one")
    expect(entries(of: applications) == ["com.sensorium.viewer.desktop"], "the applications folder gains the one entry")

    install()
    expect((try? String(contentsOf: entry, encoding: .utf8)) == written, "installing again writes the same entry")
    expect(entries(of: applications) == ["com.sensorium.viewer.desktop"], "installing again leaves no temporary file")
    expect(entries(of: icons.appendingPathComponent("hicolor/48x48/apps")) == ["com.sensorium.viewer.png"], "installing again leaves one icon per size")

    let noExec = directory.appendingPathComponent("no-exec.desktop")
    writeFile("[Desktop Entry]\nName=Sensorium\n", to: noExec)
    do {
        try LinuxUpdateLauncherEntry.install(dataRoot: root, packagedDesktopFile: noExec, packagedIconsDirectory: packagedIcons, applicationsDirectory: applications, iconsDirectory: icons)
        expect(false, "a packaged entry with no Exec line is refused")
    } catch {
        expect((try? String(contentsOf: entry, encoding: .utf8)) == written, "a refused entry leaves the installed one alone")
    }
}

func testExecArgumentIsQuotedAsTheDesktopEntrySpecificationRequires() {
    func argument(_ path: String) -> String? {
        try? LinuxUpdateLauncherEntry.execArgument(for: path)
    }
    expect(argument("/home/ada/.local/share/sensorium/current/Sensorium") == "/home/ada/.local/share/sensorium/current/Sensorium", "a plain path is written as it is")
    expect(argument("/home/ada/My Data/sensorium/current/Sensorium") == "\"/home/ada/My Data/sensorium/current/Sensorium\"", "a path with a space is quoted")
    expect(argument("/home/ada/a$b/Sensorium") == "\"/home/ada/a\\\\$b/Sensorium\"", "a dollar sign is escaped inside quotes, then the backslash is escaped as a string")
    expect(argument("/home/ada/a\"b/Sensorium") == "\"/home/ada/a\\\\\"b/Sensorium\"", "a double quote is escaped")
    expect(argument("/home/ada/a\\b/Sensorium") == "\"/home/ada/a\\\\\\\\b/Sensorium\"", "a backslash takes four backslashes")
    expect(argument("/home/ada/100%/Sensorium") == "/home/ada/100%%/Sensorium", "a percent sign is doubled, since it starts a field code")
    expect(argument("/home/ada/a\nb/Sensorium") == nil, "a path with a line break cannot be written into an entry")
    expect(argument("relative/Sensorium") == nil, "only an absolute path is written")
}

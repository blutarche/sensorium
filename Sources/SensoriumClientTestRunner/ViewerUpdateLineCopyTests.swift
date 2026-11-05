import Foundation
import SensoriumClient
import SensoriumCore

private func neutralLine(
    _ status: ViewerUpdateLineStatus,
    platform: ViewerUpdatePlatform,
    manualCheck: ViewerManualCheck = .none,
    sessionInProgress: Bool = false,
    isRestarting: Bool = false,
    restartFailureReason: String? = nil
) -> ViewerUpdateLine? {
    ViewerUpdateLine.make(
        status: status,
        runningVersion: "0.4.0",
        platform: platform,
        manualCheck: manualCheck,
        sessionInProgress: sessionInProgress,
        isRestarting: isRestarting,
        restartFailureReason: restartFailureReason
    )
}

/// Both viewers say the same thing, except the two sentences that describe
/// how each one installs.
func testViewerUpdateLineCopyMatchesAcrossPlatformsTests() {
    #if os(Linux)
    expect(ViewerUpdatePlatform.current == .linux, "the Linux viewer uses the Linux line")
    #else
    expect(ViewerUpdatePlatform.current == .macOS, "the macOS viewer uses the macOS line")
    #endif

    for platform in [ViewerUpdatePlatform.macOS, .linux] {
        expect(
            neutralLine(.ready(version: "0.5.0"), platform: platform)
                == ViewerUpdateLine(text: "Sensorium 0.5.0 is ready.", offersRestartNow: true),
            "\(platform): a staged update offers Restart Now"
        )
        expect(
            neutralLine(.busy, platform: platform, manualCheck: .pending)?.text == "Checking for updates\u{2026}",
            "\(platform): a chosen check says it is checking"
        )
        expect(neutralLine(.busy, platform: platform) == nil, "\(platform): an automatic check says nothing")
        expect(
            neutralLine(.current, platform: platform, manualCheck: .answered(upToDate: true))?.text == "Sensorium 0.4.0 is up to date.",
            "\(platform): an answered check names the running version"
        )
        expect(
            neutralLine(.current, platform: platform, manualCheck: .answered(upToDate: false)) == nil,
            "\(platform): a check that reached nothing does not claim up to date"
        )
        expect(
            neutralLine(.failed(reason: "the new version did not start"), platform: platform)
                == ViewerUpdateLine(
                    text: "Sensorium could not update: the new version did not start. It keeps running 0.4.0.",
                    offersRestartNow: false,
                    isFailure: true
                ),
            "\(platform): a failure names its reason and is drawn as one"
        )
        expect(
            neutralLine(.ready(version: "0.5.0"), platform: platform, restartFailureReason: "the new version did not start in time")?.isFailure == true,
            "\(platform): a Restart Now that did not take says why"
        )
        for withheld in [
            neutralLine(.ready(version: "0.5.0"), platform: platform, sessionInProgress: true),
            neutralLine(.ready(version: "0.5.0"), platform: platform, isRestarting: true)
        ] {
            expect(withheld?.offersRestartNow == false, "\(platform): no Restart Now during a session or a restart")
        }
    }

    expect(
        neutralLine(.ready(version: "0.5.0"), platform: .macOS, sessionInProgress: true)?.text
            == "Sensorium 0.5.0 is ready. It installs the next time Sensorium quits.",
        "the macOS viewer says it installs at the next quit"
    )
    expect(
        neutralLine(.ready(version: "0.5.0"), platform: .linux, sessionInProgress: true)?.text == "Sensorium 0.5.0 is ready.",
        "the Linux viewer, which installs only at Restart Now, promises no install at quit"
    )
    expect(
        neutralLine(.notUpdatable, platform: .macOS)?.text == "Move Sensorium to Applications and open it again to receive updates.",
        "the macOS viewer says where to move it"
    )
    expect(
        neutralLine(.notUpdatable, platform: .linux)?.text == "Sensorium cannot update itself because it cannot write to its own folder.",
        "the Linux viewer says it cannot write to its own folder"
    )
    expect(neutralLine(.notUpdatable, platform: .linux)?.isFailure == false, "not updatable is not drawn as a failure")
    print("PASS: the update line reads the same on both viewers except how each one installs")
}

/// The Linux engine accepts a staged binary only when the first line its
/// self-test prints is exactly `Sensorium <version>`.
func testViewerUpdateSelfTestNamesItsVersionFirstTests() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-self-test-line-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    var printed: [String] = []
    let passed = ViewerUpdateSelfTest.run(applicationSupportDirectory: directory, versionLine: "Sensorium 0.6.0") { printed.append($0) }
    expect(passed == 0, "an empty folder passes")
    expect(printed.first == "Sensorium 0.6.0", "and the first line is the version, got \(printed)")

    try? Data("{ not json".utf8).write(to: directory.appendingPathComponent("saved-host.json"))
    printed = []
    let failed = ViewerUpdateSelfTest.run(applicationSupportDirectory: directory, versionLine: "Sensorium 0.6.0") { printed.append($0) }
    expect(failed != 0, "a saved-machines file that does not parse fails")
    expect(printed.first == "Sensorium 0.6.0", "and still names the version first, got \(printed)")

    printed = []
    _ = ViewerUpdateSelfTest.run(applicationSupportDirectory: directory) { printed.append($0) }
    expect(printed.first?.hasPrefix("Sensorium: update self-test") == true, "with no version line, the result comes first, got \(printed)")

    let preferences = FileViewerUpdatePreferencesStore(url: directory.appendingPathComponent(FileViewerUpdatePreferencesStore.fileName))
    expect(preferences.checksAutomatically(), "automatic updates are on with nothing saved")
    preferences.remember(checksAutomatically: false)
    expect(
        !FileViewerUpdatePreferencesStore(url: directory.appendingPathComponent(FileViewerUpdatePreferencesStore.fileName)).checksAutomatically(),
        "and off is remembered, on either viewer"
    )
    print("PASS: the update self-test names its version on its first line")
}

/// A viewer the package installed adopts its own launcher entry and icons on
/// its first update: the same data folder rule as its records, and the
/// package's own files as the source.
func testLinuxViewerLauncherFoldersFollowTheXDGRuleTests() {
    let home = URL(fileURLWithPath: "/home/someone", isDirectory: true)
    let unset = LinuxViewerLocations.launcherFolders(environment: [:], homeDirectory: home)
    expect(unset.applications.path == "/home/someone/.local/share/applications", "applications go under ~/.local/share, got \(unset.applications.path)")
    expect(unset.icons.path == "/home/someone/.local/share/icons", "and icons beside them, got \(unset.icons.path)")
    let empty = LinuxViewerLocations.launcherFolders(environment: ["XDG_DATA_HOME": ""], homeDirectory: home)
    expect(empty == unset, "an empty XDG_DATA_HOME reads as unset")
    let set = LinuxViewerLocations.launcherFolders(environment: ["XDG_DATA_HOME": "/data/someone"], homeDirectory: home)
    expect(set.applications.path == "/data/someone/applications", "XDG_DATA_HOME is honoured, got \(set.applications.path)")
    expect(set.icons.path == "/data/someone/icons", "for icons too, got \(set.icons.path)")
    expect(
        LinuxViewerLocations.packagedDesktopFile.path == "/usr/share/applications/com.sensorium.viewer.desktop",
        "the package's launcher entry is the source"
    )
    expect(LinuxViewerLocations.packagedIconsFolder.path == "/usr/share/icons", "and its icon theme folder")
    expect(
        LinuxViewerLocations.applicationSupportDirectory(environment: ["XDG_DATA_HOME": "/data/someone"], homeDirectory: home)
            .deletingLastPathComponent().standardizedFileURL == set.applications.deletingLastPathComponent().standardizedFileURL,
        "the launcher folders sit beside the viewer's own records"
    )
    print("PASS: the launcher entry and icons go to the person's own XDG data folders")
}

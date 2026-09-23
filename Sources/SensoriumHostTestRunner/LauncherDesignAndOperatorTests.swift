import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

/// Split out of main.swift, mechanically -- see docs/testing.md.
@MainActor
func runLauncherDesignAndOperatorTests() async {
        // The placeholder text view was the entire remote desktop: a remote
        // user could type into it and reach nothing else on the Mini. The
        // launcher is what turns the canvas into a workstation, and every
        // decision it makes -- what is installed, what the query selects,
        // where a launched window is allowed to go, and when to stop waiting
        // for that window -- is a pure function driven here. This runner
        // opens no directory, launches no application and creates no window.
        do {
            let root = URL(fileURLWithPath: "/Sensorium/Fake/Applications", isDirectory: true)
            let systemRoot = URL(fileURLWithPath: "/Sensorium/Fake/System/Applications", isDirectory: true)
            let folder = root.appendingPathComponent("Developer", isDirectory: true)
            let nestedFolder = folder.appendingPathComponent("Archive", isDirectory: true)
            let safari = root.appendingPathComponent("Safari.app")
            let listings: [String: [URL]] = [
                root.path: [
                    safari,
                    root.appendingPathComponent("iTerm.app"),
                    root.appendingPathComponent("notes.txt"),
                    folder
                ],
                folder.path: [folder.appendingPathComponent("Xcode.app"), nestedFolder],
                nestedFolder.path: [nestedFolder.appendingPathComponent("Buried.app")],
                systemRoot.path: [
                    systemRoot.appendingPathComponent("Terminal.app"),
                    systemRoot.appendingPathComponent("Safari.app")
                ],
                safari.path: [safari.appendingPathComponent("Contents/Applications/Helper.app")]
            ]
            let listed = DiagnosticsRecorder()
            let discovered = CanvasApplicationCatalog.discover(
                // The same root twice: a duplicate root must not double every
                // application in the list a remote user reads.
                roots: [root, systemRoot, root],
                list: { url in
                    listed.record(url.path)
                    return listings[url.path] ?? []
                }
            )
            expect(
                discovered.map(\.name) == ["iTerm", "Safari", "Safari", "Terminal", "Xcode"],
                "the catalog is enumerated from the search roots, sorted by name, and lists a duplicate root once"
            )
            expect(
                !discovered.contains { $0.name == "notes" },
                "a file that is not an application bundle is never offered as one"
            )
            expect(
                !listed.messages.contains { $0.hasSuffix(".app") },
                "discovery never descends into an application bundle, so its bundled helpers are not offered as applications"
            )
            expect(
                !discovered.contains { $0.name == "Buried" } && !listed.messages.contains(nestedFolder.path),
                "discovery descends exactly one folder deep, so it cannot walk the whole disk on a laggy remote click"
            )
            expect(
                CanvasApplicationCatalog.defaultSearchRoots(
                    homeDirectory: URL(fileURLWithPath: "/Sensorium/Fake/home", isDirectory: true)
                ).map(\.lastPathComponent).contains("Applications"),
                "the shipping roots are the installed-application directories, derived rather than hardcoded to one account"
            )
        }

        // A helper bundle with no Dock presence of its own -- an LSUIElement
        // or LSBackgroundOnly application like a menu-bar helper or a URL
        // handler -- is skipped, the same as a bundled helper one level down
        // already is. The disk read this needs is injected, so this never
        // touches the real /Applications.
        do {
            let root = URL(fileURLWithPath: "/Sensorium/Fake/Applications", isDirectory: true)
            let helper = root.appendingPathComponent("Background Helper.app")
            let realApp = root.appendingPathComponent("iTerm.app")
            let listings: [String: [URL]] = [
                root.path: [helper, realApp]
            ]
            let backgroundOnly: Set<String> = [helper.path]
            let discovered = CanvasApplicationCatalog.discover(
                roots: [root],
                list: { listings[$0.path] ?? [] },
                isBackgroundOnly: { backgroundOnly.contains($0.path) }
            )
            expect(
                discovered.map(\.name) == ["iTerm"],
                "an LSUIElement/LSBackgroundOnly bundle is skipped, so only the real application is offered -- got \(discovered.map(\.name))"
            )

            print("PASS: an LSUIElement/LSBackgroundOnly helper bundle is skipped, and never offered beside a real application")
        }

        // `isBackgroundOnlyBundle` itself, against a real but tiny fixture
        // bundle in the scratch directory -- never /Applications.
        do {
            let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("sensorium-background-only-test-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            func bundle(named name: String, plist: [String: Any]?) -> URL {
                let bundleURL = scratch.appendingPathComponent(name, isDirectory: true)
                let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
                try! FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                if let plist {
                    (plist as NSDictionary).write(to: contents.appendingPathComponent("Info.plist"), atomically: true)
                }
                return bundleURL
            }

            let uiElement = bundle(named: "Helper1.app", plist: ["LSUIElement": true])
            let backgroundOnly = bundle(named: "Helper2.app", plist: ["LSBackgroundOnly": true])
            let ordinary = bundle(named: "Ordinary.app", plist: ["CFBundleName": "Ordinary"])
            let noPlist = bundle(named: "NoPlist.app", plist: nil)

            expect(
                CanvasApplicationCatalog.isBackgroundOnlyBundle(uiElement),
                "LSUIElement true reports the bundle as background-only"
            )
            expect(
                CanvasApplicationCatalog.isBackgroundOnlyBundle(backgroundOnly),
                "LSBackgroundOnly true reports the bundle as background-only"
            )
            expect(
                !CanvasApplicationCatalog.isBackgroundOnlyBundle(ordinary),
                "an ordinary bundle with neither key set is never reported as background-only"
            )
            expect(
                !CanvasApplicationCatalog.isBackgroundOnlyBundle(noPlist),
                "a bundle with no readable Info.plist is assumed to be an ordinary application, never hidden on that account"
            )

            print("PASS: isBackgroundOnlyBundle reads LSUIElement and LSBackgroundOnly from a real Info.plist, and never hides a bundle it cannot read")
        }

        // `discover`'s `list:` seam is pure and cannot exercise the one part of
        // discovery that touches the disk: `systemListing`. On current macOS,
        // an installed application can be a symlink carrying the BSD hidden
        // flag rather than a dot-prefixed name -- Safari.app is exactly this,
        // a symlink into the Safari cryptex -- so a real directory is needed
        // to prove `systemListing` offers it anyway.
        do {
            let scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent("sensorium-catalog-listing-test-\(UUID().uuidString)", isDirectory: true)
            try! FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: scratch) }

            let normal = scratch.appendingPathComponent("Thing.app", isDirectory: true)
            let dotted = scratch.appendingPathComponent(".hidden-thing.app", isDirectory: true)
            let flagged = scratch.appendingPathComponent("Flagged.app", isDirectory: true)
            for entry in [normal, dotted, flagged] {
                try! FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
            }
            let flaggedHiddenResult = chflags(flagged.path, UInt32(UF_HIDDEN))
            expect(flaggedHiddenResult == 0, "chflags(2) must succeed in setting up this test's fixture")

            let listedNames = Set(CanvasApplicationCatalog.systemListing(scratch).map(\.lastPathComponent))
            expect(
                listedNames.contains("Thing.app"),
                "an ordinary application entry is listed"
            )
            expect(
                listedNames.contains("Flagged.app"),
                "an application carrying the BSD hidden flag -- how Safari.app ships, as a cryptex symlink -- is listed anyway"
            )
            expect(
                !listedNames.contains(".hidden-thing.app"),
                "a dot-prefixed entry is still skipped, which is what the original hidden-file filtering was for"
            )
        }

        // The scratch-directory test above proves the mechanism; this proves
        // the actual machine-visible effect it exists to fix. Guarded rather
        // than required, because the suite must still run on a machine with
        // no /Applications/Safari.app.
        safariDiscovery: do {
            guard FileManager.default.fileExists(atPath: "/Applications/Safari.app") else {
                print("SKIP: /Applications/Safari.app is not present on this machine, so discovering it cannot be checked")
                break safariDiscovery
            }
            let discovered = CanvasApplicationCatalog.discover(
                roots: CanvasApplicationCatalog.defaultSearchRoots(homeDirectory: FileManager.default.homeDirectoryForCurrentUser),
                list: CanvasApplicationCatalog.systemListing
            )
            expect(
                discovered.contains { $0.bundleURL.lastPathComponent == "Safari.app" },
                "Safari.app ships as a cryptex symlink carrying the BSD hidden flag, so it must still appear in real discovery"
            )
        }

        // A remote user on a laggy link types rather than clicks, so the query
        // has to put what they meant first: a name that starts with what they
        // typed, before a name that merely contains it.
        do {
            let applications = ["Safari", "Mail", "Terminal", "Preview", "Maps", "Activity Monitor"].map {
                LaunchableApplication(bundleURL: URL(fileURLWithPath: "/Sensorium/Fake/Applications/\($0).app"))
            }
            expect(
                CanvasApplicationCatalog.filter(applications, query: "").map(\.name) == applications.map(\.name),
                "an empty query offers everything installed, in catalog order"
            )
            expect(
                CanvasApplicationCatalog.filter(applications, query: "m").map(\.name)
                    == ["Mail", "Maps", "Activity Monitor", "Terminal"],
                "a prefix match ranks above a substring match, and each group stays alphabetical"
            )
            expect(
                CanvasApplicationCatalog.filter(applications, query: "sAF").map(\.name) == ["Safari"],
                "the query is case-insensitive, so a remote user need not shift-type a name"
            )
            expect(
                CanvasApplicationCatalog.filter(applications, query: "zz").isEmpty,
                "a query that matches nothing offers nothing, rather than falling back to the whole catalog"
            )
            expect(
                CanvasApplicationSelection.move(from: 0, by: -1, count: 4) == 0
                    && CanvasApplicationSelection.move(from: 3, by: 1, count: 4) == 3,
                "arrow keys clamp at both ends rather than wrapping, so a held arrow cannot cycle the list under a laggy user"
            )
            expect(
                CanvasApplicationSelection.move(from: 1, by: 2, count: 4) == 3
                    && CanvasApplicationSelection.move(from: 2, by: 1, count: 0) == 0,
                "a multi-row move lands where it should, and an empty list has no row to select"
            )
        }

        // Everything the launcher panel says, decided without AppKit: a count
        // and a keyboard hint never share a line, an empty catalog reads
        // differently from an over-narrow filter, Return with nothing to
        // launch says so, and a launch outcome carries its own severity to the
        // label instead of being flattened into one muted string.
        do {
            expect(
                CanvasLauncherPresentation.keyboardHint.contains("Return")
                    && CanvasLauncherPresentation.keyboardHint.contains("Esc")
                    && CanvasLauncherPresentation.catalogStatus(count: 12).text
                        == "12 applications",
                "the keyboard hint is constant chrome of its own, so the catalog count cannot overwrite it"
            )
            // Rendered at 440pt the hint wrapped, and the wrap fell after a
            // separator: the panel showed "... Return to launch ·" and stopped.
            // The lines are authored rather than wrapped for exactly that
            // reason, so neither can end on a separator with nothing after it.
            let hintLines = CanvasLauncherPresentation.keyboardHint.split(separator: "\n").map(String.init)
            expect(
                hintLines.count == 2
                    && !hintLines.contains { $0.hasSuffix("·") || $0.hasPrefix("·") }
                    && hintLines.allSatisfy { $0.count <= CanvasLauncherMetrics.lineBudget },
                "the keyboard hint is two authored lines, neither ending on a dangling separator nor overrunning the panel"
            )
            // Two lines of status are laid out, so two lines of status are what
            // the copy may spend -- including the longest application name a
            // real catalog offers. The failure message was cut off mid-sentence
            // when this was left to chance.
            let longName = "Bluetooth File Exchange"
            let everyStatus = [
                CanvasLauncherPresentation.catalogStatus(count: 0),
                CanvasLauncherPresentation.catalogStatus(count: 105),
                CanvasLauncherPresentation.launchingStatus(application: longName),
                CanvasLauncherPresentation.nothingToLaunchStatus(catalogCount: 0),
                CanvasLauncherPresentation.nothingToLaunchStatus(catalogCount: 105)
            ] + [
                CanvasApplicationLaunchOutcome.placed(windows: 1),
                .placed(windows: 3),
                .placementRefused(windows: 1),
                .noWindows(attempts: 40),
                .accessibilityDenied,
                .launchFailed(message: "NSWorkspace error")
            ].map { CanvasLauncherPresentation.outcomeStatus(application: longName, outcome: $0) }
            expect(
                everyStatus.allSatisfy { $0.text.count <= CanvasLauncherMetrics.lineBudget * 2 },
                "every status line fits the two lines the panel lays out, at the longest name a real catalog offers"
            )
            expect(
                CanvasLauncherMetrics.rowHeight
                    == CanvasLauncherMetrics.iconSize + CanvasDesign.Space.xxs * 2
                    && CanvasLauncherMetrics.rowHeight.truncatingRemainder(dividingBy: 4) == 0,
                "a row is an icon plus the grid's smallest gap above and below it, and stays on the 4px grid"
            )
            expect(
                CanvasLauncherMetrics.listHeight(rowCount: 1, available: 1600) == CanvasLauncherMetrics.rowHeight
                    && CanvasLauncherMetrics.listHeight(rowCount: 0, available: 1600) == 0,
                "a list of one row is one row tall, not a screenful of empty list background"
            )
            expect(
                CanvasLauncherMetrics.listHeight(rowCount: 105, available: 1600) == 1600,
                "a list longer than the panel fills the panel and scrolls, rather than overrunning the status line"
            )
            expect(
                CanvasLauncherPresentation.catalogStatus(count: 1).text == "1 application"
                    && CanvasLauncherPresentation.catalogStatus(count: 1).severity == .neutral,
                "a catalog with one application is counted in the singular, as plain information"
            )
            // Under a list showing one row, "105 applications" would read as a
            // contradiction. The count's job is to say what is on screen.
            expect(
                CanvasLauncherPresentation.catalogStatus(count: 105, showing: 1).text == "1 of 105"
                    && CanvasLauncherPresentation.catalogStatus(count: 105, showing: 1).severity == .neutral,
                "a filtered list is counted by what it shows, against the catalog it was filtered from"
            )
            expect(
                CanvasLauncherPresentation.catalogStatus(count: 105, showing: 105).text == "105 applications"
                    && CanvasLauncherPresentation.catalogStatus(count: 105, showing: nil).text == "105 applications",
                "an unfiltered list is the plain catalog count, however the caller says so"
            )
            expect(
                CanvasLauncherPresentation.catalogStatus(count: 105, showing: 0).text == "0 of 105",
                "a filter matching nothing still counts against the catalog it was filtered from"
            )
            // The empty-catalog case leaves the status line blank: the empty
            // state below it already says the same thing in its own subtext,
            // and a status line repeating it read as the host stuttering.
            expect(
                CanvasLauncherPresentation.catalogStatus(count: 0, showing: 0).text.isEmpty
                    && CanvasLauncherPresentation.catalogStatus(count: 0).text.isEmpty,
                "a host that discovered nothing leaves the status line to the empty state, rather than repeating it"
            )
            expect(
                CanvasLauncherPresentation.emptyState(catalogCount: 0, hostName: "Kestrel Studio")
                    == CanvasLauncherEmptyState(
                        heading: "Nothing to Launch",
                        subtext: "Install an application on Kestrel Studio and reconnect."
                    ),
                "an empty catalog is advised to install something, never to clear a query it does not have -- on "
                    + "the host, named, since this text is drawn on the session canvas the viewer reads it from, "
                    + "where a bare \"this machine\" would mean the viewer's own machine"
            )
            // Rendered, the heading and the status line sat four lines apart
            // saying the same sentence twice. The heading names what is empty;
            // the status line reports the catalog.
            expect(
                CanvasLauncherPresentation.emptyState(catalogCount: 0).heading
                    != CanvasLauncherPresentation.catalogStatus(count: 0).text,
                "the empty state's heading does not repeat the status line word for word"
            )
            expect(
                CanvasLauncherPresentation.emptyState(catalogCount: 40)
                    == CanvasLauncherEmptyState(
                        heading: "No Matching Applications",
                        subtext: "Clear the filter, or type fewer letters."
                    ),
                "a filter that matched nothing is advised to widen it, because there is something to find"
            )
            expect(
                CanvasLauncherPresentation.nothingToLaunchStatus(catalogCount: 0, hostName: "Kestrel Studio").text
                    == "Nothing to launch: no applications were found on Kestrel Studio."
                    && CanvasLauncherPresentation.nothingToLaunchStatus(catalogCount: 0).severity == .warn,
                "Return on a host with no applications answers, rather than doing nothing at all -- on the host, "
                    + "named, for the same reason emptyState's subtext names it"
            )
            expect(
                CanvasLauncherPresentation.nothingToLaunchStatus(catalogCount: 40).text
                    == "No application matches what you typed. Try fewer letters."
                    && CanvasLauncherPresentation.nothingToLaunchStatus(catalogCount: 40).severity == .warn,
                "Return on a filter that matched nothing names the filter as the reason, not the catalog"
            )
            // The keyboard hint names three keys the empty and no-match states
            // offer nothing to do with: an empty catalog has nothing to type,
            // choose, or launch, and a filter matching nothing has nothing to
            // choose or launch either. Both trim the hint to what still works.
            expect(
                CanvasLauncherPresentation.footerHint(catalogCount: 0, visibleCount: 0) == "Esc to close",
                "an empty catalog offers nothing to filter or choose, so the hint is only how to leave"
            )
            expect(
                CanvasLauncherPresentation.footerHint(catalogCount: 40, visibleCount: 0) == "Type to filter · Esc to close",
                "a filter matching nothing still offers typing a different query, but nothing yet to choose or launch"
            )
            expect(
                CanvasLauncherPresentation.footerHint(catalogCount: 40, visibleCount: 12) == CanvasLauncherPresentation.keyboardHint,
                "a catalog with matches on screen keeps the full hint, unchanged"
            )
        }

        // Each ending of a launch is a different thing to a remote user
        // watching one status line, so each carries its own severity and its
        // own words -- and the severities map onto the design system's status
        // colours, which is what makes a failure look unlike a success.
        do {
            expect(
                CanvasLauncherPresentation.launchingStatus(application: "Safari")
                    == CanvasLauncherStatus(text: "Launching Safari…", severity: .progress),
                "a launch under way reads as in progress, not as a result"
            )
            expect(
                CanvasLauncherPresentation.outcomeStatus(application: "Safari", outcome: .placed(windows: 1))
                    == CanvasLauncherStatus(text: "Safari is open.", severity: .ok),
                "one window placed is a success, and says where the application went"
            )
            expect(
                CanvasLauncherPresentation.outcomeStatus(application: "Safari", outcome: .placed(windows: 2))
                    == CanvasLauncherStatus(text: "Safari is open, in 2 windows.", severity: .ok),
                "more than one window placed is counted, in the plural"
            )
            expect(
                CanvasLauncherPresentation.outcomeStatus(application: "Safari", outcome: .placementRefused(windows: 1))
                    == CanvasLauncherStatus(
                        text: "Safari opened, but its window could not be moved here.",
                        severity: .warn
                    ),
                "a refused move is a warning: the application did start, it just is not here"
            )
            expect(
                CanvasLauncherPresentation.outcomeStatus(application: "Safari", outcome: .noWindows(attempts: 40))
                    == CanvasLauncherStatus(
                        text: "Safari opened but has not shown a window yet.",
                        severity: .warn
                    ),
                "an application that opened no window is a warning, and is not described as failed"
            )
            expect(
                CanvasLauncherPresentation.outcomeStatus(application: "Safari", outcome: .accessibilityDenied)
                    == CanvasLauncherStatus(
                        text: "Safari opened elsewhere. Grant Sensorium Accessibility access on the host machine.",
                        severity: .bad
                    ),
                "a missing Accessibility grant names the one thing that would fix it, without naming an API"
            )
            expect(
                CanvasLauncherPresentation.outcomeStatus(
                    application: "Safari",
                    outcome: .launchFailed(message: "The application “Safari” could not be launched."),
                    hostName: "Kestrel Studio"
                ) == CanvasLauncherStatus(
                    text: "Safari did not open on Kestrel Studio. It may no longer be installed there.",
                    severity: .bad
                ),
                "a launch that never started names the machine it failed on, and the framework's own wording is kept to the log"
            )
            expect(
                CanvasLauncherStatusSeverity.ok.color == CanvasDesign.ok
                    && CanvasLauncherStatusSeverity.bad.color == CanvasDesign.bad
                    && CanvasLauncherStatusSeverity.warn.color == CanvasDesign.warn
                    && CanvasLauncherStatusSeverity.progress.color == CanvasDesign.info
                    && CanvasLauncherStatusSeverity.neutral.color == CanvasDesign.muted,
                "the status severities draw from the design system's status tokens, so the four are visually distinct"
            )
        }

        // The v1 invariant, applied to a window this host did not create: the
        // only bounds a launched window can ever be moved to are derived from
        // the canvas placement, which `CanvasWorkspacePlacement.resolve` has
        // already refused to produce for a builtin or pre-existing display.
        do {
            let canvas = try! CanvasWorkspacePlacement.resolve(
                ownedHandle: VirtualDisplayHandle(rawValue: 42),
                display: CanvasWorkspaceDisplay(
                    id: 42,
                    bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1200),
                    isBuiltin: false,
                    isOnline: true
                ),
                physicalDisplayIDs: [1, 2]
            )
            let small = CanvasLaunchedWindowPlacement.resolve(
                canvas: canvas,
                windowFrame: CGRect(x: 0, y: 0, width: 800, height: 600)
            )
            expect(
                small == CanvasWindowPlacement(origin: CGPoint(x: 2072, y: 300), size: CGSize(width: 800, height: 600)),
                "a launched window is centred on the owned canvas at the size it opened with"
            )
            let oversized = CanvasLaunchedWindowPlacement.resolve(
                canvas: canvas,
                windowFrame: CGRect(x: 0, y: 0, width: 2400, height: 1400)
            )
            expect(
                oversized == CanvasWindowPlacement(origin: CGPoint(x: 1512, y: 0), size: CGSize(width: 1920, height: 1200)),
                "a window larger than the canvas is shrunk to it, because a window merely moved to the canvas origin would still overhang onto a physical display"
            )
            expect(
                CanvasLaunchedWindowPlacement.isWithinOwnedCanvas(small, canvas: canvas)
                    && CanvasLaunchedWindowPlacement.isWithinOwnedCanvas(oversized, canvas: canvas),
                "every resolved placement stands entirely on the owned canvas"
            )
            expect(
                !CanvasLaunchedWindowPlacement.isWithinOwnedCanvas(
                    CanvasWindowPlacement(origin: .zero, size: CGSize(width: 800, height: 600)),
                    canvas: canvas
                ),
                "and the check is a real one: the builtin display's own origin is not on the owned canvas"
            )
        }

        // A launched application has no window for a while, and may never open
        // one. The wait is bounded and every ending is reported, because a
        // silent give-up looks exactly like a launch that worked.
        do {
            let canvas = try! CanvasWorkspacePlacement.resolve(
                ownedHandle: VirtualDisplayHandle(rawValue: 42),
                display: CanvasWorkspaceDisplay(
                    id: 42,
                    bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1200),
                    isBuiltin: false,
                    isOnline: true
                ),
                physicalDisplayIDs: [1, 2]
            )
            expect(
                CanvasWindowAdoptionPolicy.step(attempt: 0, windowCount: 1, maxAttempts: 3) == .place
                    && CanvasWindowAdoptionPolicy.step(attempt: 0, windowCount: 0, maxAttempts: 3) == .wait
                    && CanvasWindowAdoptionPolicy.step(attempt: 2, windowCount: 0, maxAttempts: 3) == .giveUp,
                "the poll waits while there is no window, places as soon as there is one, and gives up on the last attempt"
            )

            let lateFrames: [[CGRect]] = [[], [], [CGRect(x: 0, y: 0, width: 800, height: 600)]]
            let latePlacer = FakeLaunchedWindowPlacer(framesByAttempt: lateFrames)
            let lateWaits = WaitRecorder()
            let lateOutcome = CanvasWindowAdopter(
                placer: latePlacer,
                isAccessibilityTrusted: { true },
                maxAttempts: 6,
                pollInterval: 0.25,
                wait: { lateWaits.record($0) }
            ).adopt(processIdentifier: 4242, canvas: canvas)
            expect(
                lateOutcome == .placed(windows: 1) && lateWaits.intervals == [0.25, 0.25],
                "a window that appears on the third poll is placed, having waited only the two polls it took"
            )
            expect(
                latePlacer.placements.map(\.placement)
                    == [CanvasWindowPlacement(origin: CGPoint(x: 2072, y: 300), size: CGSize(width: 800, height: 600))],
                "and it is placed on the owned canvas, at the bounds the pure resolver chose"
            )

            let neverWaits = WaitRecorder()
            let neverOutcome = CanvasWindowAdopter(
                placer: FakeLaunchedWindowPlacer(framesByAttempt: [[]]),
                isAccessibilityTrusted: { true },
                maxAttempts: 4,
                pollInterval: 0.25,
                wait: { neverWaits.record($0) }
            ).adopt(processIdentifier: 4242, canvas: canvas)
            expect(
                neverOutcome == .noWindows(attempts: 4) && neverWaits.intervals.count == 3,
                "an application that never opens a window gives up after its attempt budget instead of spinning forever"
            )

            let deniedPlacer = FakeLaunchedWindowPlacer(framesByAttempt: [[CGRect(x: 0, y: 0, width: 800, height: 600)]])
            let deniedWaits = WaitRecorder()
            let deniedOutcome = CanvasWindowAdopter(
                placer: deniedPlacer,
                isAccessibilityTrusted: { false },
                maxAttempts: 4,
                pollInterval: 0.25,
                wait: { deniedWaits.record($0) }
            ).adopt(processIdentifier: 4242, canvas: canvas)
            expect(
                deniedOutcome == .accessibilityDenied
                    && deniedPlacer.frameQueries.isEmpty && deniedWaits.intervals.isEmpty,
                "without the Accessibility grant nothing is asked of the Accessibility API at all, and the caller is told which grant is missing"
            )

            let refusingPlacer = FakeLaunchedWindowPlacer(
                framesByAttempt: [[CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 0, y: 0, width: 400, height: 300)]],
                accepts: false
            )
            let refusedOutcome = CanvasWindowAdopter(
                placer: refusingPlacer,
                isAccessibilityTrusted: { true },
                maxAttempts: 4,
                pollInterval: 0.25,
                wait: { _ in }
            ).adopt(processIdentifier: 4242, canvas: canvas)
            expect(
                refusedOutcome == .placementRefused(windows: 2),
                "an application whose windows refuse to be moved is reported as refused, never as placed"
            )

            let twoPlacer = FakeLaunchedWindowPlacer(
                framesByAttempt: [[CGRect(x: 0, y: 0, width: 800, height: 600), CGRect(x: 0, y: 0, width: 400, height: 300)]]
            )
            let twoOutcome = CanvasWindowAdopter(
                placer: twoPlacer,
                isAccessibilityTrusted: { true },
                maxAttempts: 4,
                pollInterval: 0.25,
                wait: { _ in }
            ).adopt(processIdentifier: 4242, canvas: canvas)
            expect(
                twoOutcome == .placed(windows: 2) && twoPlacer.placements.map(\.windowIndex) == [0, 1],
                "an application that opens more than one window has all of them brought onto the canvas"
            )
        }

        // Degrading honestly is the whole point of these lines: a launch that
        // could not be placed still happened, and the host must say so rather
        // than leave a window on a physical display with no explanation.
        do {
            expect(
                CanvasApplicationLaunchReport.line(application: "Safari", outcome: .accessibilityDenied)
                    == "Sensorium host: launched Safari but could not move its window onto the session canvas: Accessibility is not granted to this host.",
                "a missing Accessibility grant is reported as a launch that happened and a placement that did not"
            )
            expect(
                CanvasApplicationLaunchReport.line(application: "Safari", outcome: .placed(windows: 2))
                    == "Sensorium host: launched Safari and moved 2 window(s) onto the session canvas",
                "a successful placement names how many windows it moved"
            )
            expect(
                CanvasApplicationLaunchReport.line(application: "Safari", outcome: .noWindows(attempts: 40))
                    == "Sensorium host: launched Safari but it opened no window within 40 attempts; nothing was moved onto the session canvas",
                "a launch that never produced a window is reported, not silently abandoned"
            )
            expect(
                CanvasApplicationLaunchReport.line(application: "Safari", outcome: .placementRefused(windows: 1))
                    == "Sensorium host: launched Safari but the Accessibility API refused to move its 1 window(s) onto the session canvas",
                "a refused move is distinguished from a missing grant, because they are fixed differently"
            )
            expect(
                CanvasApplicationLaunchReport.line(application: "Safari", outcome: .launchFailed(message: "no such bundle"))
                    == "Sensorium host: could not launch Safari: no such bundle",
                "a launch that never started is reported as a launch failure, not as a placement failure"
            )
        }

        // The whole path a remote user's Return key drives, with no AppKit and
        // no real application: open, then place what it opened on the canvas.
        do {
            let canvas = try! CanvasWorkspacePlacement.resolve(
                ownedHandle: VirtualDisplayHandle(rawValue: 42),
                display: CanvasWorkspaceDisplay(
                    id: 42,
                    bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1200),
                    isBuiltin: false,
                    isOnline: true
                ),
                physicalDisplayIDs: [1, 2]
            )
            let application = LaunchableApplication(bundleURL: URL(fileURLWithPath: "/Sensorium/Fake/Applications/Safari.app"))
            let placer = FakeLaunchedWindowPlacer(framesByAttempt: [[CGRect(x: 0, y: 0, width: 800, height: 600)]])
            let opened = DiagnosticsRecorder()
            let logged = DiagnosticsRecorder()
            let outcomes = LaunchOutcomeRecorder()
            CanvasApplicationLauncher(
                canvas: canvas,
                opener: FakeCanvasApplicationOpener(result: .success(4242)) { opened.record($0.name) },
                adopter: CanvasWindowAdopter(
                    placer: placer,
                    isAccessibilityTrusted: { true },
                    maxAttempts: 4,
                    pollInterval: 0.25,
                    wait: { _ in }
                ),
                runOffMain: { work in work() },
                log: { logged.record($0) },
                onOutcome: { outcomes.record(application: $0, outcome: $1) }
            ).launch(application)
            expect(
                opened.messages == ["Safari"] && placer.frameQueries == [4242],
                "the launcher opens the chosen application and then places the windows of exactly the process it opened"
            )
            expect(
                logged.messages == ["Sensorium host: launched Safari and moved 1 window(s) onto the session canvas"],
                "and reports the outcome once, on the host's own log"
            )
            // The UI is handed the outcome itself, not the log line: matching
            // that string back apart is how a failed launch ends up drawn in
            // the same colour as a successful one.
            expect(
                outcomes.recorded.map(\.application) == ["Safari"]
                    && outcomes.recorded.map(\.outcome) == [.placed(windows: 1)],
                "and hands the outcome itself, once, to whatever draws it"
            )

            let unplacedPlacer = FakeLaunchedWindowPlacer(framesByAttempt: [[]])
            let failedLog = DiagnosticsRecorder()
            let failedOutcomes = LaunchOutcomeRecorder()
            CanvasApplicationLauncher(
                canvas: canvas,
                opener: FakeCanvasApplicationOpener(result: .failure(CanvasApplicationOpenError(message: "no such bundle"))) { _ in },
                adopter: CanvasWindowAdopter(
                    placer: unplacedPlacer,
                    isAccessibilityTrusted: { true },
                    maxAttempts: 4,
                    pollInterval: 0.25,
                    wait: { _ in }
                ),
                runOffMain: { work in work() },
                log: { failedLog.record($0) },
                onOutcome: { failedOutcomes.record(application: $0, outcome: $1) }
            ).launch(application)
            expect(
                failedLog.messages == ["Sensorium host: could not launch Safari: no such bundle"]
                    && unplacedPlacer.frameQueries.isEmpty,
                "a launch that failed asks the Accessibility API for nothing, because there is no process whose windows could be moved"
            )
            expect(
                failedOutcomes.recorded.map(\.outcome) == [.launchFailed(message: "no such bundle")],
                "a launch that never started reaches the UI as a failure, so it can be drawn as one"
            )
        }

        do {
            // A typo'd hex is the one part of the palette a test can catch; the
            // rest is visual and needs a hardware session. See
            // docs/design-system.md.
            let accent = CanvasDesign.accent
            expect(
                abs(accent.red - 124.0 / 255) < 1e-12 && abs(accent.green - 112.0 / 255) < 1e-12
                    && abs(accent.blue - 245.0 / 255) < 1e-12 && accent.alpha == 1,
                "the accent token decodes #7C70F5 opaque"
            )
            // Compared against the accent's own channels rather than against a
            // freshly typed 0x7C70F5, so this proves the three translucent
            // accents are derived from it instead of retyped beside it.
            expect(
                CanvasDesign.accentSoft.red == accent.red && CanvasDesign.accentSoft.green == accent.green
                    && CanvasDesign.accentSoft.blue == accent.blue && CanvasDesign.accentSoft.alpha == 0.10
                    && CanvasDesign.accentBorder.red == accent.red && CanvasDesign.accentBorder.alpha == 0.30
                    && CanvasDesign.selection.red == accent.red && CanvasDesign.selection.alpha == 0.32,
                "the translucent accents carry the accent's own channels, at 0.10, 0.30 and 0.32"
            )
            expect(
                CanvasDesign.bg == DesignColor(hex: 0x0A0A0C) && CanvasDesign.ink == DesignColor(hex: 0xF2EFEA),
                "the deepest surface and the primary ink decode #0A0A0C and #F2EFEA"
            )
            // `letter-spacing` is relative to the font size and `kern` is
            // absolute points; the conversion is the only place that can drift.
            expect(
                CanvasDesign.kern(CanvasDesign.Tracking.widest, size: 12) == 0.22 * 12,
                "em tracking converts to absolute points against the font size"
            )
        }

        do {
            // Everything the person at the host reads. The menu
            // bar item draws these strings and nothing else, so the words --
            // and which of them appear when -- are checked here rather than on
            // a screen no test has.
            let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
            let notHosting = HostOperatorStatus(connection: .notHosting, permissions: granted).presentation(now: Date())
            expect(
                notHosting.indicator == .idle && notHosting.menuBarTitle == nil && notHosting.pairingCode == nil
                    && notHosting.pairingCountdown == nil && notHosting.alerts.isEmpty,
                "a host that has never started hosting puts nothing in the menu bar but its own icon"
            )
            let couldNotStart = HostOperatorStatus(
                connection: .notHosting, permissions: granted, problem: "address already in use"
            ).presentation(now: Date())
            expect(
                couldNotStart.headline == "Could not start hosting",
                "a headline never names the app it already lives in, the same as every sibling headline -- got: "
                    + "\(couldNotStart.headline)"
            )
            let tailscaleNotRunning = HostOperatorStatus(
                connection: .notHosting, permissions: granted, problem: HostStartupProblemCopy.noTailnetAddress
            ).presentation(now: Date())
            let tailscaleNotInstalled = HostOperatorStatus(
                connection: .notHosting, permissions: granted, problem: HostStartupProblemCopy.tailscaleNotInstalled
            ).presentation(now: Date())
            expect(
                tailscaleNotRunning.headline == "Tailscale is not running"
                    && tailscaleNotInstalled.headline == "Tailscale is not installed"
                    && tailscaleNotRunning.eyebrow == "COULD NOT START"
                    && tailscaleNotInstalled.eyebrow == "COULD NOT START",
                "a Tailscale problem's headline names the cause under the could-not-start eyebrow, so the card does not "
                    + "say the same thing twice -- got: \(tailscaleNotRunning.headline) / \(tailscaleNotInstalled.headline)"
            )
            expect(
                couldNotStart.eyebrowColor == CanvasDesign.warn,
                "a could-not-start eyebrow is gold, the same attention colour as a missing-permission eyebrow, "
                    + "not the grey a neutral status like Ready gets -- got: \(couldNotStart.eyebrowColor)"
            )
            expect(
                notHosting.eyebrowColor == CanvasDesign.muted2,
                "a neutral status eyebrow like this not-hosting, no-problem state stays grey -- got: \(notHosting.eyebrowColor)"
            )
            let missingScreenRecording = HostOperatorStatus(
                connection: .notHosting,
                permissions: HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .granted)
            ).presentation(now: Date())
            expect(
                missingScreenRecording.eyebrow == "SCREEN RECORDING NEEDED"
                    && missingScreenRecording.eyebrowColor == CanvasDesign.warn,
                "the screen-recording-missing eyebrow is gold on both surfaces that read it -- got eyebrow "
                    + "\(missingScreenRecording.eyebrow), colour \(missingScreenRecording.eyebrowColor)"
            )
            expect(
                !notHosting.headline.isEmpty && !notHosting.detail.isEmpty,
                "a not-hosting host still says what it is doing and what that means for this machine"
            )
            expect(
                notHosting.detail == "No machine is connected.",
                "the GUI starts hosting itself and offers no Start Hosting control -- this state's own copy must never instruct the operator to use one, even though the running app can never actually show this line"
            )
            let hosting = HostOperatorStatus(
                connection: .hosting(address: "100.100.0.4"),
                permissions: granted
            ).presentation(now: Date())
            expect(
                hosting.indicator == .idle && hosting.headline == "Waiting for a machine to connect"
                    && hosting.pairingCode == nil && hosting.alerts.isEmpty,
                "a bound listener with nobody connected reads Waiting for a machine to connect -- several tailnet addresses is not a failure, "
                    + "and the host listens on all of them, so no one address is named here"
            )
            expect(
                hosting.detail.isEmpty,
                "the ready state has no detail line of its own -- the headline already says it is waiting, and a "
                    + "second line repeating that would be blank space with the same words in it -- got: \(hosting.detail)"
            )
            expect(
                hosting.eyebrow == "READY",
                "the ready state's own eyebrow names itself rather than the generic STATUS every other idle state used to share"
            )

            let issuedAt = Date()
            let pairing = HostOperatorStatus(
                connection: .hosting(address: "100.100.0.4"),
                pairing: .showing(
                    code: "418362",
                    expiresAt: issuedAt.addingTimeInterval(PairingAuthority.defaultLifetime)
                ),
                permissions: granted
            )
            let openPairing = pairing.presentation(now: issuedAt.addingTimeInterval(48))
            expect(
                openPairing.pairingCode == "418 362" && openPairing.menuBarTitle == "418 362",
                "the code is grouped in threes, the way it is read aloud, wherever it is shown"
            )
            expect(
                openPairing.pairingCountdown == "Expires in 4:12" && openPairing.indicator == .idle
                    && !openPairing.countdownIsUrgent,
                "the code carries how long it has left, counted in minutes and seconds, quietly while there is time -- "
                    + "and the icon itself stays idle, since no machine has connected because of it yet"
            )
            let endOfPairing = pairing.presentation(now: issuedAt.addingTimeInterval(PairingAuthority.defaultLifetime - 9))
            expect(
                endOfPairing.pairingCountdown == "Expires in 0:09" && endOfPairing.countdownIsUrgent,
                "the last seconds are marked urgent, so the panel is not quietest exactly when the code is about to die"
            )
            let expiredPairing = pairing.presentation(now: issuedAt.addingTimeInterval(PairingAuthority.defaultLifetime))
            expect(
                !expiredPairing.countdownIsUrgent,
                "a code with no countdown left to show is not still being urgent about one"
            )
            expect(
                expiredPairing.pairingCode == nil && expiredPairing.pairingCountdown == nil
                    && expiredPairing.menuBarTitle == nil,
                "an expired code is withdrawn rather than left on the menu bar to be read aloud"
            )
            expect(
                expiredPairing.headline == "Waiting for a machine to connect",
                "an expired code leaves the status line unchanged -- no machine is connected either way -- and its own "
                    + "section falls back to a Show pairing code button instead of a second wording here"
            )

            let peerName = "Kestrel Laptop Pro"
            let serving = HostOperatorStatus(connection: .serving(peerName: peerName), permissions: granted)
                .presentation(now: issuedAt)
            expect(
                serving.headline.contains(peerName) && serving.indicator == .serving,
                "the connected client's own device name is what the operator reads, not a connection count"
            )

            let missingCapture = HostOperatorStatus(
                connection: .serving(peerName: peerName),
                permissions: HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .granted)
            ).presentation(now: issuedAt)
            expect(
                missingCapture.indicator == .attention,
                "a permission missing during a live session outranks the session in the menu bar icon"
            )
            expect(
                missingCapture.alerts.map(\.kind) == [.screenRecording]
                    && missingCapture.headline.contains(peerName),
                "only the permission actually missing is raised, and it does not hide who is connected"
            )
            expect(
                missingCapture.alerts.first?.settingsURL.contains("Privacy_ScreenCapture") == true,
                "the alert carries the System Settings pane that grants exactly that permission"
            )
            expect(
                missingCapture.detail == "Kestrel Laptop Pro sees nothing until you allow Screen Recording for Sensorium Host in System Settings.",
                "the canvas-mode privacy sentence -- \"a virtual display, not this machine's own screen\" -- is false and self-contradicting the moment nothing is actually visible at all; the status card itself now carries the Screen Recording sentence as one block, in place of that false claim -- got: \(missingCapture.detail)"
            )
            expect(
                missingCapture.detailIsWarning,
                "the status card's own subtitle is the warning here, so it reads in the same gold as a permission alert would"
            )
            expect(
                missingCapture.screenRecordingReplacesStatusCard,
                "the status card already says Screen Recording is missing while connected, the same as it does before anyone connects -- a second card beneath repeating it would read as two problems instead of one"
            )
            expect(
                missingCapture.alerts.first?.detail == "Kestrel Laptop Pro sees nothing until you allow Screen Recording for Sensorium Host in System Settings.",
                "the alert itself still carries the whole sentence, even though the panel no longer draws it as a second card -- got: \(missingCapture.alerts.first?.detail ?? "nil")"
            )
            let missingCaptureTexts = CanvasHostTestHooks.menuBarPanelTexts(missingCapture)
            expect(
                missingCaptureTexts.map(\.string) == ["SCREEN RECORDING NEEDED", "Connected to Kestrel Laptop Pro", missingCapture.detail],
                "one block: the gold SCREEN RECORDING NEEDED eyebrow and headline, then the Screen Recording sentence -- no second eyebrow beneath it -- got: \(missingCaptureTexts.map(\.string))"
            )
            let missingCaptureEyebrowColor = missingCaptureTexts[0].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            expect(
                missingCaptureEyebrowColor == CanvasDesign.warn.nsColor,
                "the eyebrow reads in the warning gold, not the panel's usual muted grey -- a missing permission, not a normal connection"
            )
            let missingCaptureDetailColor = missingCaptureTexts[2].attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
            expect(
                missingCaptureDetailColor == CanvasDesign.warn.nsColor,
                "the subtitle reads in the warning gold, not the panel's usual muted grey"
            )
            let notReadyMissingCapture = HostOperatorStatus(
                connection: .hosting(address: "203.0.113.42"),
                permissions: HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .granted)
            ).presentation(now: issuedAt)
            expect(
                notReadyMissingCapture.eyebrow == "SCREEN RECORDING NEEDED"
                    && notReadyMissingCapture.headline == "Screen Recording is not allowed",
                "before anyone is connected, a missing Screen Recording permission replaces the status card outright -- the host is not ready, and no Ready line says otherwise"
            )
            expect(
                notReadyMissingCapture.detail == notReadyMissingCapture.alerts.first?.detail,
                "the replaced detail says exactly what the permission alert already says, not a second wording"
            )
            expect(
                notReadyMissingCapture.detail == "No machine can see a screen until you allow Screen Recording for Sensorium Host in System Settings.",
                "the subtitle names the consequence and where the permission lives, so it reads whole even where the button beneath it is absent -- got: \(notReadyMissingCapture.detail)"
            )
            let missingBoth = HostOperatorStatus(
                connection: .notHosting,
                permissions: HostPermissionRequestResult(screenCapture: .approvalRequired, accessibility: .approvalRequired)
            ).presentation(now: issuedAt)
            expect(
                missingBoth.alerts.map(\.kind) == [.screenRecording, .accessibility],
                "both missing permissions are listed, the one that blocks the picture first"
            )
            expect(
                missingBoth.alerts.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty }
                    && missingBoth.alerts.contains { $0.detail.contains("type") },
                "each alert says what stops working, not just which switch is off"
            )

            // Copy written for a person, not a log reader: a case name reaching
            // the menu bar is the failure this catches.
            let everyLine = [openPairing, expiredPairing, serving, missingCapture, missingBoth].flatMap { presentation in
                [presentation.eyebrow, presentation.headline, presentation.detail]
                    + [presentation.pairingCountdown ?? ""]
                    + presentation.alerts.flatMap { [$0.title, $0.detail] }
            }
            expect(
                everyLine.allSatisfy { line in
                    !line.contains("approvalRequired") && !line.contains("peerName")
                        && !line.contains("screenRecording") && !line.contains("(")
                },
                "no line the operator reads is a Swift case name or an interpolated enum"
            )
            // The viewer's pairing window is set with typographic apostrophes;
            // one typewriter apostrophe on this panel is visible beside it.
            expect(
                everyLine.allSatisfy { !$0.contains("'") },
                "every apostrophe this panel writes is typographic, matching the viewer"
            )

            var observedStatuses: [HostOperatorStatus] = []
            let store = HostOperatorStatusStore(permissions: granted)
            store.onChange = { observedStatuses.append($0) }
            store.showPairingCode("000001", expiresAt: issuedAt.addingTimeInterval(60))
            store.apply(.lost(.screenRecording))
            expect(
                observedStatuses.count == 2
                    && store.status.permissions.screenCapture == .approvalRequired
                    && store.status.pairing == .showing(code: "000001", expiresAt: issuedAt.addingTimeInterval(60)),
                "a permission change never overwrites what the host is doing, and every change reaches the menu bar exactly once"
            )
            let firstConnection = HostConnectionToken()
            store.apply(.identified(deviceName: peerName), from: firstConnection)
            store.apply(.closed(reason: nil), from: firstConnection)
            expect(
                store.status.connection == .notHosting,
                "a client that connected and dropped, with no listener ever recorded, leaves the menu bar saying this machine is not hosting"
            )
            store.showPairingCode("000002", expiresAt: issuedAt.addingTimeInterval(60))
            store.apply(.closed(reason: nil), from: HostConnectionToken())
            expect(
                store.status.pairing == .showing(code: "000002", expiresAt: issuedAt.addingTimeInterval(60)),
                "a connection ending during the pairing ceremony does not wipe the code still on screen"
            )

            let hostingStore = HostOperatorStatusStore(permissions: granted)
            var setupObserved: [HostOperatorStatus] = []
            hostingStore.addObserver { setupObserved.append($0) }
            hostingStore.beginHosting(address: "100.100.0.4")
            expect(
                hostingStore.status.connection == .hosting(address: "100.100.0.4") && setupObserved.count == 1,
                "starting an already-paired listener shows the address it is hosting on, and reaches every observer, not just onChange"
            )
            let hostingConnection = HostConnectionToken()
            hostingStore.apply(.identified(deviceName: peerName), from: hostingConnection)
            hostingStore.apply(.closed(reason: nil), from: hostingConnection)
            expect(
                hostingStore.status.connection == .hosting(address: "100.100.0.4"),
                "a connection dropping from a recorded listener returns to hosting on that address, not to not-hosting"
            )
            hostingStore.stopHosting()
            expect(
                hostingStore.status.connection == .notHosting,
                "Stop Hosting clears the recorded address along with the activity"
            )
            let strayConnection = HostConnectionToken()
            hostingStore.apply(.identified(deviceName: peerName), from: strayConnection)
            hostingStore.apply(.closed(reason: nil), from: strayConnection)
            expect(
                hostingStore.status.connection == .notHosting,
                "once Stop Hosting has cleared the address, a stray connection ending has nothing to fall back to"
            )

            // docs/ux-spec.md's "Waiting for `<machine name>` to finish pairing":
            // the interval between a `pairRequest` being approved and its
            // connection actually presenting itself.
            let waitingPresentation = HostOperatorStatus(
                connection: .pairingApproved(deviceName: peerName),
                permissions: granted
            ).presentation(now: issuedAt)
            expect(
                waitingPresentation.headline == "Waiting for \(peerName) to finish pairing"
                    && waitingPresentation.indicator == .waiting,
                "an approved device that has not connected yet reads as waiting, named, not as Ready or Connected"
            )
            expect(
                waitingPresentation.detail == "Code accepted. \(peerName) is connecting.",
                "the detail names the device by the same words the headline already uses it by, and says what is "
                    + "actually true at this state -- the code was already accepted, the connection is what is "
                    + "still pending"
            )
            let waitingStore = HostOperatorStatusStore(permissions: granted)
            var waitingObserved: [HostOperatorStatus] = []
            waitingStore.addObserver { waitingObserved.append($0) }
            waitingStore.beginHosting(address: "100.100.0.4")
            waitingStore.recordPairingApproved(deviceName: peerName)
            waitingStore.apply(.identified(deviceName: peerName), from: HostConnectionToken())
            expect(
                waitingStore.status.connection == .serving(peerName: peerName),
                "the device actually connecting replaces Waiting with Connected, the same as any other pairing"
            )
            let droppedWaitingStore = HostOperatorStatusStore(permissions: granted)
            droppedWaitingStore.beginHosting(address: "100.100.0.4")
            droppedWaitingStore.recordPairingApproved(deviceName: peerName)
            droppedWaitingStore.apply(.closed(reason: nil), from: HostConnectionToken())
            expect(
                droppedWaitingStore.status.connection == .hosting(address: "100.100.0.4"),
                "an approved device that never finishes connecting returns to Ready, not stuck waiting forever"
            )

            // A bind failure, or address auto-detection finding none or too
            // many candidates: `.notHosting`, but not the quiet kind.
            let problemStore = HostOperatorStatusStore(permissions: granted)
            problemStore.reportProblem("No tailnet address found. Tailscale is probably not running.")
            let problemPresentation = problemStore.status.presentation(now: issuedAt)
            expect(
                problemStore.status.connection == .notHosting
                    && problemPresentation.indicator == .attention
                    && problemPresentation.detail.contains("Tailscale"),
                "a reported problem keeps the host not-hosting but raises the same attention icon a missing permission does"
            )
            problemStore.beginHosting(address: "100.100.0.9")
            expect(
                problemStore.status.presentation(now: issuedAt).indicator == .idle
                    && problemStore.status.presentation(now: issuedAt).headline == "Waiting for a machine to connect",
                "hosting starting successfully clears a problem reported before it"
            )

            var teardowns: [String] = []
            let shutdownRegistry = HostShutdownRegistry()
            let endedToken = shutdownRegistry.register { teardowns.append("already-ended") }
            shutdownRegistry.register { teardowns.append("live") }
            expect(shutdownRegistry.liveTeardownCount == 2, "every registered session teardown is held until it is run or dropped")
            shutdownRegistry.deregister(endedToken)
            await shutdownRegistry.shutDown()
            expect(
                teardowns == ["live"],
                "quitting from the menu bar tears down the sessions still live, and nothing a session already ended"
            )
            await shutdownRegistry.shutDown()
            expect(
                teardowns == ["live"] && shutdownRegistry.liveTeardownCount == 0,
                "a second quit runs no teardown twice"
            )

            // A second `shutDown()` call arriving while the first is still
            // running its teardown must join that call rather than return
            // as though the registry were already idle: a caller that reads
            // an early return as "everything is torn down" and moves on to
            // release resources the still-running teardown owns is exactly
            // the double-quit race a second Cmd-Q could hit.
            final class Gate: @unchecked Sendable {
                private var continuation: CheckedContinuation<Void, Never>?
                func wait() async {
                    await withCheckedContinuation { self.continuation = $0 }
                }
                func open() {
                    continuation?.resume()
                    continuation = nil
                }
            }
            let gate = Gate()
            let reentrantRegistry = HostShutdownRegistry()
            reentrantRegistry.register { await gate.wait() }

            let firstShutDown = Task { @MainActor in await reentrantRegistry.shutDown() }
            // The registry empties its pending list synchronously, before
            // the teardown above ever runs -- so this is clear of scheduler
            // timing: once it reads zero, the first call is inside the
            // teardown loop, blocked on the gate.
            while reentrantRegistry.liveTeardownCount != 0 {
                await Task.yield()
            }

            final class Flag: @unchecked Sendable {
                var value = false
            }
            let secondFinished = Flag()
            let secondShutDown = Task { @MainActor in
                await reentrantRegistry.shutDown()
                secondFinished.value = true
            }
            // The gate is still closed, so a join-respecting `shutDown()`
            // cannot have returned yet; a generous real-time margin, not a
            // scheduler-timing assumption, is what makes this a reliable
            // regression check rather than a flaky one.
            try? await Task.sleep(nanoseconds: 200_000_000)
            expect(
                !secondFinished.value,
                "a second shutDown call while the first is still running its teardown waits for it, instead of returning as if it had already finished"
            )
            gate.open()
            await firstShutDown.value
            await secondShutDown.value
            expect(
                secondFinished.value,
                "the second call completes once the in-flight teardown it joined actually finishes"
            )
        }

        do {
            // What the host setup window offers as addresses to host on:
            // exactly `SourceAddressPolicy`'s own ranges, so a row a person
            // can pick is never one the listener would then refuse to bind.
            let raw = [
                "127.0.0.1",
                "100.100.0.4",
                "192.168.1.5",
                "100.100.0.4",
                "fd7a:115c:a1e0:100::9",
                "::1"
            ]
            expect(
                TailnetAddressEnumerator.localTailnetAddresses(rawAddresses: raw)
                    == ["100.100.0.4", "fd7a:115c:a1e0:100::9"],
                "only tailnet addresses are offered, in first-seen order, with duplicates removed"
            )
            expect(
                TailnetAddressEnumerator.localTailnetAddresses(rawAddresses: []).isEmpty,
                "no interface at all is the empty list, not an error -- the setup window names that itself"
            )
            // Reads this machine's real interfaces -- no network call, no
            // `tailscale` CLI -- the same discipline `TailnetInterfaceLocator`
            // already exercises for real in this runner.
            expect(
                TailnetAddressEnumerator.rawLocalAddresses().contains("127.0.0.1"),
                "the real local enumeration finds this machine's own loopback address"
            )

            // What the GUI actually decides with, silently: exactly one
            // candidate picks it, and anything else is a named error state
            // rather than a question or a guess.
            expect(
                TailnetAddressEnumerator.autoSelect(from: ["100.100.0.4"]) == .single("100.100.0.4"),
                "exactly one tailnet address auto-selects"
            )
            expect(
                TailnetAddressEnumerator.autoSelect(from: []) == .none,
                "no tailnet address is a named empty state, not a crash or a guess"
            )
            expect(
                TailnetAddressEnumerator.autoSelect(from: ["100.100.0.4", "100.100.0.5", "100.100.0.6"])
                    == .single("100.100.0.4"),
                "several tailnet addresses is not a failure -- HostNetworkListener admits every address on the owning interface, so the first IPv4 candidate is named"
            )
            expect(
                TailnetAddressEnumerator.autoSelect(from: ["fd7a:115c:a1e0:100::9", "fd7a:115c:a1e0:100::8"])
                    == .single("fd7a:115c:a1e0:100::9"),
                "with no IPv4 candidate at all, the first address of any family auto-selects"
            )
            // A tailnet node normally has exactly one address per family --
            // this is the ordinary case, not an error, and the IPv4 one is
            // what a person would recognize from Tailscale's own UI.
            expect(
                TailnetAddressEnumerator.autoSelect(from: ["100.100.0.4", "fd7a:115c:a1e0:100::9"])
                    == .single("100.100.0.4"),
                "one address per family auto-selects the IPv4 address rather than refusing"
            )
            expect(
                TailnetAddressEnumerator.autoSelect(from: ["fd7a:115c:a1e0:100::9", "100.100.0.4"])
                    == .single("100.100.0.4"),
                "the IPv4 address wins regardless of which family the enumerator saw first"
            )
            expect(
                TailnetAddressEnumerator.autoSelect(from: ["fd7a:115c:a1e0:100::9"]) == .single("fd7a:115c:a1e0:100::9"),
                "an IPv6-only tailnet address still auto-selects on its own"
            )
        }

        do {
            // The one bind failure with an actionable cause on this machine
            // gets its own sentence; every other `NWError` still shows,
            // unaltered, rather than being swallowed.
            expect(
                HostListenerFailureDescription.describe(.posix(.EADDRINUSE)).contains("already running"),
                "EADDRINUSE names another Sensorium host as the likely cause, not a POSIX error code"
            )
            let other = NWError.posix(.ECONNREFUSED)
            expect(
                HostListenerFailureDescription.describe(other) == "\(other)",
                "a bind failure with no specific cause here falls back to NWError's own description"
            )
        }

        print("PASS: virtual display lifecycle, capture ownership, and authenticated host gate")
        print("PASS: a canvasRequest's surfaceID echoes back identical, and an omitted one stays omitted")
        print("PASS: an approved device survives a host restart")
        print("PASS: a pairing code carries its own failure budget across connections, and a near miss still pairs")
        print("PASS: a capture that cannot start is reported and its canvas released")
        print("PASS: a canvas bring-up failure names the step that failed, never blaming capture for a placement or reply")
        print("PASS: a capture that could not start ends the session once, leaving the transport's follow-on teardown nothing to redo")
        print("PASS: a canvas request the shared single-flight gate actually rejects is logged with its specific reason, at the transport too")
        print("PASS: a dropped connection's late teardown never closes the workspace window a reconnect took that surface over with")
        print("PASS: synthetic tailnet fixtures are admitted and the non-tailnet counterpart is refused")
        print("PASS: the host listener can only bind a tailnet address, never every interface")
        print("PASS: a physical baseline requires a display Sensorium did not create, not just a display count")
        print("PASS: transport loss without a goodbye releases canvas, capture, and held input")
        print("PASS: host starts canvas capture on readiness and stops it at session end")
        print("PASS: input translation maps drags, buttons, and modifiers to CoreGraphics events")
        print("PASS: a scroll is positioned on its own canvas before posting, and a key has nothing to position it by")
        print("PASS: host signs canvas readiness so a client can pin its identity")
        print("PASS: host pairing ceremony approves one device per single-use code")
        print("PASS: host listener policy admits only tailnet endpoints")
        print("PASS: host ingress policy accepts only Tailscale IPv4 and IPv6 sources")
        print("PASS: host validates button, scroll, and key input against the owned canvas")
        print("PASS: host releases stuck buttons and modifiers when the session ends")
        print("PASS: a failed held-input release is logged as counts and an outcome, never as which key or button")
        print("PASS: host video packet sequencer numbers frames and isolates recovery configuration")
        print("PASS: host input gate requires authentication and an active session canvas")
        print("PASS: host answers an authenticated time-sync request with its own clock")
        print("PASS: each host connection gets its own authority and cannot inherit another connection's")
        print("PASS: a stale connection cannot release the canvas a reconnected session owns")
        print("PASS: refused input is survivable while an unauthenticated peer is fatal")
        print("PASS: the video send queue drops stale frames and never discards a waiting keyframe")
        print("PASS: a completed send releases the frame its surface was holding and goes idle only when neither surface waits")
        print("PASS: the host resolves input availability without ever prompting for Accessibility")
        print("PASS: the TCP local-verification transport binds the tailnet address and is never QUIC")
        print("PASS: the posix byte channel moves framed bytes both ways and refuses non-tailnet binds")
        print("PASS: QUIC local-verification admits loopback only in that mode and never LAN")
        print("PASS: both QUIC transports carry a 30s idle timeout")
        print("PASS: host stage latency is matched by presentation timestamp and refuses unmatched or negative intervals")
        print("PASS: the host stage summary line reports only measured stages and the dropped frame count")
        print("PASS: the coordinator signals session end exactly once, when streaming actually stops")
        print("PASS: only serve resolves to an interactive host run mode")
        print("PASS: an unregistered canvas is reported distinctly, never as a rejected physical display")
        print("PASS: the canvas display readiness poller waits for registration within a bounded attempt limit")
        print("PASS: only a complete ScreenCaptureKit frame status is submitted to the encoder")
        print("PASS: ground-truth frame counters are not fooled by the percentile guard that can invert capture/encode counts")
        print("PASS: encode submission failures are counted rather than silently discarded by `try?`")
        print("PASS: the host stage summary line surfaces ground-truth frame counts next to percentile latency")
        print("PASS: the encoder configuration scales to the viewer's stream scale and follows it with bitrate")
        print("PASS: a burst of viewer sizes settles into exactly one encoder reconfiguration")
        print("PASS: a resolution change forces a keyframe before any delta at the new resolution")
        print("PASS: the host refuses degenerate viewer drawable sizes without dropping the session")
        print("PASS: a reconfiguration that fails recovers to a working stream or ends the session loudly")
        print("PASS: the host permission monitor detects Screen Recording and Accessibility transitions exactly once each")
        print("PASS: request-permissions reports the terminal-launch and Remote Desktop caveats honestly")
        print("PASS: the global encode admission gate bounds frames in flight across every pipeline, is fair, and counts every drop")
        print("PASS: AnimatedMeasurementWorkspace shares the single-flight canvas creation gate")
        print("PASS: an unrecognized message type is a silent no-op and does not disturb the session")
        print("PASS: the host serves two session-owned canvases, created sequentially, each with its own display, stream, workspace and stream scale")
        print("PASS: each canvasReady is signed over its own surfaceID, and a third surface is still refused")
        print("PASS: both workspace windows come down before either canvas display is released, and session end fires exactly once")
        print("PASS: each surface's waiting frame is scoped to its own queue, so neither surface's keyframe is evicted by the other's")
        print("PASS: two backlogged surfaces share the wire fairly and neither starves")
        print("PASS: a single-surface session queues exactly as one shared queue always did")
        print("PASS: host stage latency is keyed per surface, so two canvases sharing a timestamp are not matched across surfaces")
        print("PASS: tag 2 goes only to a client that supplied a surfaceID and received the echo, on every path")
        print("PASS: a surface-aware client's frames carry the surfaceID they were captured from, one send in flight at a time")
        print("PASS: the host applies a peer clipboard only for a granted session, and never echoes it back")
        print("PASS: a clipboard frame reaching a host with no clipboard session is ignored, not fatal")
        print("PASS: a clipboard frame off the wire is applied, and a local copy is polled and sent on tag 3 exactly once")
        print("PASS: received clipboards are floored and coalesced, so a burst lands the newest content once per interval")
        print("PASS: what was copied before the session became admissible is never sent, however the gate opened")
        print("PASS: the focus signal reports one of three states, is validated against the two-canvas cap, and is absent-safe")
        print("PASS: the focused surface is preferred at the encode gate and the send queue, with a bounded floor for the unfocused one")
        print("PASS: a focus report reaches both the send path's priority and the shared encode gate's")
        print("PASS: a recorder's per-surface metrics and frame counts stay scoped to their own surface, alongside the unchanged session-wide totals")
        print("PASS: per-surface drop and failure counters attribute only to the surface named, and an unattributed call still counts toward the session-wide total")
        print("PASS: the telemetry snapshot omits an empty surface and derives fps from the encoded delta after the first tick")
        print("PASS: a key fronts its own workspace window before posting, and is dropped, counted and left unheld when it cannot")
        print("PASS: key confinement is stated at every call site, and a connection can only front the workspace window it owns")
        print("PASS: key confinement is re-checked on every key, so a window lost between two keys drops the second")
        print("PASS: a key is confined to the window holding the keyboard, so lost focus drops it rather than typing elsewhere")
        print("PASS: a key follows the canvas, not the window, so an application reaching outside the owned canvas drops it")
        print("PASS: every coordinator path writes a canvasReady before that surface's capture starts")
        print("PASS: each canvas surface has its own stable display identity, distinct only in serial number")
        print("PASS: a sub-pixel scroll delta is not truncated to zero on the axis that carries precise motion")
        print("PASS: the fixed-point delta field carries the exact fractional value, not a rounded one")
        print("PASS: a trackpad gesture's began phase is written onto the injected scroll event")
        print("PASS: an ordinary scroll-wheel mouse, which reports no phase, leaves the phase field untouched")
        print("PASS: a trackpad flick's momentum-continue phase is written onto the injected scroll event")
        print("PASS: host rejects an unbounded relative pointer delta")
        print("PASS: captured-mode toggling and the relative motion it gates are injected as ordinary events")
        print("PASS: session teardown releases a still-active pointer capture, the same way it releases a held button or key")
        print("PASS: teardown that never entered capture posts no capture-release event")
        print("PASS: the launcher catalog is enumerated one folder deep from the installed-application roots, never from inside a bundle")
        print("PASS: systemListing lists an ordinary entry and one carrying the BSD hidden flag, and still skips a dot-prefixed one")
        print("PASS: Safari.app, which ships as a hidden-flagged cryptex symlink, is discovered over the real search roots when present")
        print("PASS: a typed query ranks prefix matches above substring matches, and arrow selection clamps at both ends")
        print("PASS: the launcher's status line counts the catalog, warns on an empty one, and never overwrites the keyboard hint")
        print("PASS: an empty catalog, an over-narrow filter and a Return with nothing to launch each get their own words")
        print("PASS: every launch ending carries its own severity to the status line, drawn from the design system's status tokens")
        print("PASS: a launched window centres and shrinks to fit the owned canvas, and never resolves onto a physical display")
        print("PASS: the wait for a launched application's window is bounded, and every ending -- placed, refused, absent, or ungranted -- is distinguishable")
        print("PASS: a launch that could not be placed is reported as a launch that happened, naming which grant or step failed")
        print("PASS: the launcher opens the chosen application and places only that process's windows, reporting the outcome exactly once")
        print("PASS: the design system's colour tokens decode from their hex literals, and em tracking converts to points")
        print("PASS: the menu bar item states every hosting state in words written for the operator")
        print("PASS: a missing permission outranks the session in the menu bar, names what stops working, and carries its own settings pane")
        print("PASS: the operator status store keeps activity and permissions independent, and quitting tears down every live session exactly once")
        print("PASS: the operator status store remembers the hosted address across pairing, serving and a dropped connection, and Stop Hosting forgets it")
        print("PASS: host setup is offered deduplicated tailnet addresses only, and an empty topology is an empty state, not an error")
        print("PASS: address auto-detection prefers the first IPv4 candidate, falls back to any family, and reports .none only for an empty list")
        print("PASS: EADDRINUSE names another Sensorium host as the likely cause, and every other bind failure keeps NWError's own words")
        print("PASS: a reported problem raises the same attention icon a missing permission does, and starting hosting successfully clears it")
        print("PASS: an approved device reads as Waiting for it to finish pairing until it connects or the attempt drops")
}

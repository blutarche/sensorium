import Foundation
import SensoriumClient
import SensoriumCore

/// The Linux menu bar is the macOS one less the items that only call a macOS
/// app service, and nothing else: the test that fails if the two platforms'
/// item lists drift apart.
func testLinuxViewerMenuMatchesMacOSTests() {
    for state in [ViewerMenuBarState.initial, menuBarFixtureState()] {
        let macOS = ViewerMenuPlan.rows(of: ViewerMenuPlan.bar(state))
        let linux = ViewerMenuPlan.rows(of: LinuxViewerMenu.bar(state))
        let omittedTitles = ["Hide Others", "Show All", "Bring All to Front"]
        let kept = macOS.filter { !omittedTitles.contains($0.title) }
        // A separator left with nothing after it in its menu goes too.
        let expected = kept.enumerated().filter { index, row in
            !(row.isSeparator && (index + 1 == kept.count || kept[index + 1].depth < row.depth))
        }.map(\.element)
        for (index, pair) in zip(expected, linux).enumerated() where pair.0 != pair.1 {
            expect(false, "row \(index) differs: macOS \(pair.0), Linux \(pair.1)")
        }
        expect(expected.count == linux.count, "macOS less the omissions has \(expected.count) rows, Linux \(linux.count)")
    }
    expect(
        LinuxViewerMenu.omitted == [.hideOthers, .showAll, .bringAllToFront],
        "only the three macOS app-service items are left out"
    )
    print("PASS: the Linux menu bar is the macOS one less Hide Others, Show All and Bring All to Front")
}

/// Each macOS chord in the GTK accelerator syntax, Ctrl standing in for
/// Command, and back again.
func testLinuxViewerMenuAcceleratorTests() {
    let cases: [(String, ViewerMenuModifiers, String)] = [
        ("q", [.command], "<Control>q"),
        ("1", [.command], "<Control>1"),
        ("z", [.command, .shift], "<Shift><Control>z"),
        ("l", [.command, .shift], "<Shift><Control>l"),
        ("h", [.command, .option], "<Alt><Control>h"),
        ("f", [.command, .control], "<Control><Super>f")
    ]
    for (key, modifiers, accel) in cases {
        expect(
            LinuxViewerMenu.accelerator(keyEquivalent: key, modifiers: modifiers) == accel,
            "\(key) \(modifiers.rawValue) is \(accel), got \(String(describing: LinuxViewerMenu.accelerator(keyEquivalent: key, modifiers: modifiers)))"
        )
        let back = LinuxViewerMenu.chord(accelerator: accel)
        expect(back?.keyEquivalent == key && back?.modifiers == modifiers, "\(accel) reads back as the macOS chord")
    }
    expect(LinuxViewerMenu.accelerator(keyEquivalent: "", modifiers: []) == nil, "an item without a chord has no accelerator")
    print("PASS: every menu chord has a GTK accelerator with Ctrl for Command, and reads back")
}

/// In a session window a menu chord is taken for the menu only where macOS
/// would take it. Super stands in for Command there, as it does on the wire,
/// so the key is judged as the chord the host would receive: any chord
/// `SystemShortcutRouter` would forward from a macOS canvas is forwarded, and
/// every Ctrl chord, which reaches the host as Control, goes to the host.
func testLinuxSessionMenuChordsTests() {
    let menus = LinuxViewerMenu.bar(.initial)
    let viewer = ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: false)
    // Carbon key codes, which is what the Linux key path hands on.
    let one: UInt16 = 18, q: UInt16 = 12, h: UInt16 = 4, c: UInt16 = 8, f: UInt16 = 3, l: UInt16 = 37, g: UInt16 = 5
    let cases: [(SystemShortcutMode, UInt16, String, CanvasModifierFlags, ViewerMenuCommand?, String)] = [
        (.remoteWhenFocused, one, "1", [.command], .showYourMachines, "Super-1 shows Your Machines"),
        (.remoteWhenFocused, f, "f", [.control, .command], .toggleFullScreen, "Ctrl-Super-F toggles full screen"),
        (.remoteWhenFocused, l, "l", [.command, .shift], .toggleTelemetryOverlay, "Super-Shift-L shows Session Diagnostics"),
        (.remoteWhenFocused, g, "g", [.command, .shift], .togglePointerCapture, "Super-Shift-G captures the pointer"),
        (.remoteWhenFocused, c, "c", [.command, .shift], .toggleClipboardSharing, "Super-Shift-C toggles clipboard sharing"),
        (.remoteWhenFocused, q, "q", [.command], nil, "Super-Q reaches the host, as a forwarded Cmd-Q does"),
        (.remoteWhenFocused, h, "h", [.command], nil, "Super-H reaches the host, as a forwarded Cmd-H does"),
        (.remoteWhenFocused, c, "c", [.command], nil, "Super-C reaches the host"),
        (.remoteWhenFocused, one, "1", [.control], nil, "Ctrl-1 reaches the host as Control-1"),
        (.remoteWhenFocused, l, "l", [.control, .shift], nil, "Ctrl-Shift-L reaches the host"),
        (.remoteWhenFocused, g, "g", [.control, .shift], nil, "Ctrl-Shift-G reaches the host"),
        (.remoteWhenFocused, c, "c", [.control, .shift], nil, "Ctrl-Shift-C reaches the host"),
        (.remoteWhenFocused, f, "f", [.control], nil, "Ctrl-F reaches the host"),
        (.remoteWhenFocused, q, "q", [.control], nil, "Ctrl-Q reaches the host"),
        (.remoteWhenFocused, h, "h", [.control], nil, "Ctrl-H reaches the host"),
        (.remoteWhenFocused, c, "c", [.control], nil, "Ctrl-C reaches the host"),
        (.remoteWhenFocused, q, "q", [], nil, "Q alone is typing"),
        (.local, q, "q", [.command], .quit, "with shortcuts kept local, Super-Q quits, as Cmd-Q does"),
        (.local, h, "h", [.command], .hide, "with shortcuts kept local, Super-H hides, as Cmd-H does"),
        (.local, c, "c", [.command], nil, "Super-C still reaches the host: Edit's items act on no field there"),
        (.local, q, "q", [.control], nil, "Ctrl-Q reaches the host even with shortcuts kept local")
    ]
    for (mode, keyCode, key, modifiers, command, description) in cases {
        let chosen = LinuxViewerMenu.sessionCommand(
            chord: KeyChord(keyCode: keyCode, modifiers: modifiers),
            key: key,
            in: menus,
            router: SystemShortcutRouter(mode: mode),
            viewer: viewer
        )
        expect(chosen == command, "\(description), got \(String(describing: chosen))")
    }
    print("PASS: a session window takes a menu chord only where a macOS canvas would leave it to the menu")
}

/// The session window's key path offers a key to the menu by the session
/// rule above, after the viewer's own strip chord and before the canvas, and
/// keeps the key's release from reaching the host once the menu took it.
@MainActor
func testWaylandKeyPathMenuChordsTests() {
    /// KEY_1 and KEY_Q, with whatever modifiers are set.
    struct FakeKeyTranslator: WaylandKeyTranslating {
        var modifiers: CanvasModifierFlags = []

        func key(evdev code: UInt32, isDown: Bool) -> CanvasSurfaceEvent? {
            switch code {
            case 2: .key(keyCode: 18, isDown: isDown, modifiers: modifiers)
            case 16: .key(keyCode: 12, isDown: isDown, modifiers: modifiers)
            default: nil
            }
        }

        func character(evdev code: UInt32) -> String? {
            switch code {
            case 2: "1"
            case 16: "q"
            default: nil
            }
        }
    }
    let menu = WaylandSessionMenuKeys(
        menus: LinuxViewerMenu.bar(.initial),
        router: SystemShortcutRouter(mode: .remoteWhenFocused),
        viewer: ViewerWindowState(surfaceID: 0, hasKeyFocus: true, isFullscreen: false)
    )
    let superKey = FakeKeyTranslator(modifiers: [.command])
    let control = FakeKeyTranslator(modifiers: [.control])
    let down = WaylandKeyPath.destination(evdev: 2, isDown: true, keyboard: superKey, menu: menu)
    expect(down == .menuCommand(.showYourMachines, isDown: true), "Super-1 goes to the menu, got \(down)")
    let up = WaylandKeyPath.destination(evdev: 2, isDown: false, keyboard: superKey, menu: menu)
    expect(up == .menuCommand(.showYourMachines, isDown: false), "and so does its release, got \(up)")
    let controlOne = WaylandKeyPath.destination(evdev: 2, isDown: true, keyboard: control, menu: menu)
    expect(controlOne == .canvas(.key(keyCode: 18, isDown: true, modifiers: [.control])), "Ctrl-1 goes to the host, got \(controlOne)")
    let quit = WaylandKeyPath.destination(evdev: 16, isDown: true, keyboard: superKey, menu: menu)
    expect(
        quit == .reservedChord(KeyChord(keyCode: 12, modifiers: [.command]), .key(keyCode: 12, isDown: true, modifiers: [.command]), isDown: true),
        "Super-Q goes the way of every chord the host reserves, got \(quit)"
    )
    let withoutMenu = WaylandKeyPath.destination(evdev: 2, isDown: true, keyboard: superKey, menu: nil)
    expect(withoutMenu == .canvas(.key(keyCode: 18, isDown: true, modifiers: [.command])), "with no menu, every key goes to the host")
    print("PASS: the session window's key path hands the menu its chords, and the host every other key")
}

/// What each menu command does in a Linux session window: the app-wide ones
/// go to the app, the session's own choices go to the calls the viewer's
/// controller listens on, and the rest act on the window.
func testLinuxSessionMenuActionsTests() {
    let cases: [(ViewerMenuCommand, LinuxSessionMenuAction)] = [
        (.about, .application(.about)),
        (.quit, .application(.quit)),
        (.showYourMachines, .application(.showYourMachines)),
        (.hide, .application(.hide)),
        (.toggleFullScreen, .toggleFullScreen),
        (.toggleTelemetryOverlay, .toggleDiagnostics),
        (.togglePointerCapture, .togglePointerCapture),
        (.minimize, .minimize),
        (.zoom, .zoom),
        (.toggleClipboardSharing, .sessionChoice(.setClipboardSharing(false))),
        (.setStreamScale(0.5), .sessionChoice(.setStreamScale(0.5))),
        (.setStreamScale(nil), .sessionChoice(.setStreamScale(nil))),
        (.selectDisplayCount(2), .sessionChoice(.selectDisplayCount(2))),
        (.selectRealScreen(Data([1])), .sessionChoice(.selectRealScreen(Data([1])))),
        (.selectHostScreenMode("m1"), .sessionChoice(.selectHostScreenMode("m1"))),
        (.selectStartTarget(.virtualDisplay), .sessionChoice(.selectStartTarget(.virtualDisplay))),
        (.copy, .none),
        (.streamScaleClampNotice, .none),
        (.escapeGestureHint, .none)
    ]
    for (command, action) in cases {
        let chosen = LinuxViewerMenu.sessionAction(for: command, clipboardSharingEnabled: true)
        expect(chosen == action, "\(command) is \(action), got \(chosen)")
    }
    expect(
        LinuxViewerMenu.sessionAction(for: .toggleClipboardSharing, clipboardSharingEnabled: false)
            == .sessionChoice(.setClipboardSharing(true)),
        "Share Clipboard turns sharing on when it is off"
    )
    print("PASS: every menu command in a Linux session window goes to the app, the session, or the window")
}

/// A chord as its menu row spells it. Your Machines types Ctrl for Command;
/// a session window types Super for it, the key the host receives as
/// Command. Both follow GTK's own order and spelling.
func testLinuxViewerMenuChordLabelsTests() {
    let cases: [(String, ViewerMenuModifiers, LinuxViewerMenu.ChordStyle, String)] = [
        ("q", [.command], .yourMachines, "Ctrl+Q"),
        ("z", [.command, .shift], .yourMachines, "Shift+Ctrl+Z"),
        ("h", [.command, .option], .yourMachines, "Ctrl+Alt+H"),
        ("f", [.command, .control], .yourMachines, "Ctrl+Super+F"),
        ("1", [.command], .session, "Super+1"),
        ("q", [.command], .session, "Super+Q"),
        ("l", [.command, .shift], .session, "Shift+Super+L"),
        ("f", [.command, .control], .session, "Ctrl+Super+F")
    ]
    for (key, modifiers, style, label) in cases {
        let spelled = LinuxViewerMenu.chordLabel(keyEquivalent: key, modifiers: modifiers, style: style)
        expect(spelled == label, "\(key) \(modifiers.rawValue) in \(style) reads \(label), got \(String(describing: spelled))")
    }
    expect(LinuxViewerMenu.chordLabel(keyEquivalent: "", modifiers: [], style: .session) == nil, "no chord, no label")
    print("PASS: menu chords read Ctrl in Your Machines and Super in a session window, spelled the way GTK spells them")
}

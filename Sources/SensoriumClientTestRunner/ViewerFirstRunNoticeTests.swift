import Foundation
import SensoriumClient
import SensoriumCore

/// What a viewer says for itself before a session exists: the one notice a
/// machine with no hardware decoder gets at launch, the usage a `--help` run
/// prints instead of opening a window, and the install sentence a platform
/// with no Tailscale application substitutes. All three are decided without a
/// window, a device node, or a `tailscaled`, so both platforms verify them.

private struct FixedDecodeCapabilities: VideoDecodeCapabilities {
    let hasHardware: Bool

    func hasH264HardwareDecoder() -> Bool { hasHardware }
}

func testViewerFirstRunNoticeTests() {
    testSoftwareDecodeNoticeNamesTheGuide()
    testNoticesAreDecidedByTheDecoderAndTheArguments()
    testUsageNamesEveryVerbAndTheHelpFlag()
    testTailscaleNotInstalledReasonNamesTheDownload()
}

private func testSoftwareDecodeNoticeNamesTheGuide() {
    let notice = ViewerFirstRunNotices.softwareDecode
    let whole = notice.headline + " " + notice.detail
    expect(
        notice.headline == "This machine decodes video in software, which uses more power.",
        "the notice states the effect of software decoding"
    )
    expect(notice.detail == "\(ViewerCopyWrapping.control("Session Diagnostics")) links to a guide for faster video.",
           "the notice points to the guide and keeps its menu item's name together")
    expect(!whole.contains("/"), "and never a path, a command or a flag -- got: \(whole)")
    expect(
        notice.continueTitle == "Continue",
        "one button, and it only takes the notice away -- got: \(notice.continueTitle)"
    )
    print("PASS: the software-decode notice describes power use and points to Session Diagnostics")
}

/// The probe touches a device node, so a run that is only printing its usage
/// or tracing a session never opens one.
private func testNoticesAreDecidedByTheDecoderAndTheArguments() {
    let without = FixedDecodeCapabilities(hasHardware: false)
    let with = FixedDecodeCapabilities(hasHardware: true)

    expect(
        ViewerFirstRunNotices.notices(arguments: [], capabilities: without) == [
            ViewerFirstRunNotices.softwareDecode
        ],
        "a machine with no hardware decoder is told once, at launch"
    )
    expect(
        ViewerFirstRunNotices.notices(arguments: ["enter"], capabilities: without).count == 1,
        "exactly one notice, never one per session"
    )
    expect(
        ViewerFirstRunNotices.notices(arguments: [], capabilities: with).isEmpty,
        "a machine that has one is told nothing"
    )
    expect(
        ViewerFirstRunNotices.notices(arguments: ["--help"], capabilities: without).isEmpty,
        "a run that only prints its usage probes nothing and shows nothing"
    )
    expect(
        ViewerFirstRunNotices.notices(arguments: ["--trace", "run.jsonl"], capabilities: without).isEmpty,
        "and neither does a traced run"
    )
    print("PASS: one launch notice for a machine with no hardware decoder, none for a machine with one")
}

/// `Sensorium --help` is what a package's own check runs to prove the binary
/// works without a display, so the usage has to name every verb it has.
private func testUsageNamesEveryVerbAndTheHelpFlag() {
    let usage = ViewerUsage.lines
    expect(usage.first?.hasPrefix("usage: Sensorium ") == true, "the first line is the usage line")
    let whole = usage.joined(separator: "\n")
    expect(whole.contains("pair <host> <port> <code>"), "the pairing verb, with what it takes")
    expect(whole.contains("enter [sensorium://enter/<host>]"), "the enter verb, with the URL it accepts")
    expect(whole.contains("--help"), "and the flag that printed this")
    expect(
        usage.allSatisfy { !$0.isEmpty },
        "no blank line, so a package check can count what it got"
    )
    print("PASS: the usage names every verb, the enter URL and the flag that printed it")
}

/// Both viewers show a "Download Tailscale" link beside the not-installed
/// reason, so the one sentence names that link rather than an install route
/// that differs by platform.
private func testTailscaleNotInstalledReasonNamesTheDownload() {
    let reason = TailnetDevicePickerFetchError.tailscaleNotInstalled.reason
    expect(
        reason == "Tailscale is not installed. Download\u{00A0}Tailscale and sign in, then choose Look\u{00A0}Again.",
        "the not-installed reason points at the Download Tailscale link both viewers show -- got: \(reason)"
    )
    expect(
        !reason.contains("distribution") && !reason.contains("app"),
        "and names neither a distribution nor an app, which one platform has and the other does not -- got: \(reason)"
    )
    expect(
        TailnetDevicePickerState.from(.failure(.tailscaleNotInstalled)) == .unreachable(reason: reason),
        "and the picker draws that sentence"
    )
    print("PASS: the not-installed reason names the Download Tailscale link")
}


@MainActor
func testSoftwareDecodeNoticePersistenceTests() async {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("Artifacts/r6-notice-tests/\(UUID().uuidString)")
    let url = directory.appendingPathComponent("first-run-notices.json")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ViewerFirstRunNoticeStore(url: url)
    let capabilities = FixedDecodeCapabilities(hasHardware: false)
    expect(ViewerFirstRunNotices.notices(arguments: [], capabilities: capabilities, acknowledgements: store).count == 1,
           "before acknowledgement the software notice appears")
    expect(!ViewerFirstRunNoticeStore(url: url).hasAcknowledgedSoftwareDecode(), "showing alone does not acknowledge")
    var shown = 0
    await ViewerFirstRunNotices.showNotices(arguments: [], capabilities: capabilities, acknowledgements: store) { notice in
        shown += 1
        expect(notice == ViewerFirstRunNotices.softwareDecode, "the production presenter shows the software notice")
        expect(!store.hasAcknowledgedSoftwareDecode(), "the store stays unacknowledged while the prompt is showing")
    }
    expect(shown == 1, "the first launch presents once")
    await ViewerFirstRunNotices.showNotices(arguments: [], capabilities: capabilities, acknowledgements: store) { _ in
        shown += 1
    }
    expect(shown == 1, "a later launch does not present again")
    let relaunched = ViewerFirstRunNoticeStore(url: url)
    expect(relaunched.hasAcknowledgedSoftwareDecode(), "acknowledgement survives a fresh store")
    expect(ViewerFirstRunNotices.notices(arguments: [], capabilities: capabilities, acknowledgements: relaunched).isEmpty,
           "later launches omit the acknowledged notice")
    let permissions = (try! FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? NSNumber
    expect(permissions?.intValue == 0o600, "acknowledgements use the pin store's owner-only file policy")
    try! Data("invalid".utf8).write(to: url)
    expect(!ViewerFirstRunNoticeStore(url: url).hasAcknowledgedSoftwareDecode(), "an unreadable record does not silently acknowledge")
    print("PASS: software-decode acknowledgement persists across launches in an atomic owner-only JSON file")
}

#if canImport(CGtk4)
import CGtk4

@MainActor
func testGtkSoftwareDecodeContinuePersistenceTests() async {
    guard ProcessInfo.processInfo.environment["SENSORIUM_GTK_WINDOW_TESTS"] == "1" else {
        print("SKIP: software-decode Continue needs the scratch GTK display")
        return
    }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let directory = root.appendingPathComponent("Artifacts/r6-gtk-notice-tests/\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ViewerFirstRunNoticeStore(url: directory.appendingPathComponent("first-run-notices.json"))
    let prompts = GtkViewerPrompts()
    var completed = false
    let presentation = Task { @MainActor in
        await ViewerFirstRunNotices.showNotices(arguments: [], capabilities: FixedDecodeCapabilities(hasHardware: false), acknowledgements: store) {
            await prompts.showNotice($0)
        }
        completed = true
    }
    var pressedContinue = false
    for _ in 0..<100 {
        while g_main_context_iteration(nil, 0) != 0 {}
        if let list = gtk_window_get_toplevels() {
            for index in 0..<g_list_model_get_n_items(list) {
                guard let item = g_list_model_get_item(list, index) else { continue }
                defer { g_object_unref(item) }
                guard gtk_widget_get_visible(sensorium_gtk_widget(item)) != 0,
                      let button = gtk_window_get_default_widget(sensorium_gtk_window(item)),
                      let label = gtk_button_get_label(sensorium_gtk_button(button)),
                      String(cString: label) == "Continue" else { continue }
                expect(!store.hasAcknowledgedSoftwareDecode(), "the visible notice is not yet acknowledged")
                gtk_widget_activate(button)
                pressedContinue = true
                break
            }
        }
        if pressedContinue { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    expect(pressedContinue, "the shipping software notice has an activatable Continue button")
    for _ in 0..<100 {
        while g_main_context_iteration(nil, 0) != 0 {}
        if completed { break }
        try? await Task.sleep(for: .milliseconds(20))
    }
    expect(completed, "Continue completes the production notice presenter")
    await presentation.value
    let relaunched = ViewerFirstRunNoticeStore(url: directory.appendingPathComponent("first-run-notices.json"))
    expect(ViewerFirstRunNotices.notices(arguments: [], capabilities: FixedDecodeCapabilities(hasHardware: false), acknowledgements: relaunched).isEmpty,
           "a fresh launch after the GTK Continue click shows no software notice")
    print("PASS: GTK Continue dismisses the production software notice and persists acknowledgement for the next launch")
}
#else
@MainActor
func testGtkSoftwareDecodeContinuePersistenceTests() async {}
#endif

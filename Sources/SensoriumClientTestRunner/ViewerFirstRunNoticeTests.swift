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
    testSoftwareDecodeNoticeNamesWhereTheDecoderComesFrom()
    testNoticesAreDecidedByTheDecoderAndTheArguments()
    testUsageNamesEveryVerbAndTheHelpFlag()
    testTailscaleInstallHintIsPlatformNeutral()
}

/// docs/ux-spec.md line 108: one sentence on what happened, and no file path
/// in it. A package name is a thing to install, not a path to type.
private func testSoftwareDecodeNoticeNamesWhereTheDecoderComesFrom() {
    let notice = ViewerFirstRunNotices.softwareDecode
    let whole = notice.headline + " " + notice.detail
    expect(
        whole == "This machine has no hardware video decoder Sensorium can use, so it will decode in "
            + "software and use more power. Fedora leaves the decoder out; it comes from the RPM Fusion "
            + "package named mesa-va-drivers-freeworld.",
        "the notice says what happened and where the decoder comes from -- got: \(whole)"
    )
    expect(whole.contains("RPM Fusion"), "it names the repository the package lives in")
    expect(whole.contains("mesa-va-drivers-freeworld"), "and the package itself")
    expect(!whole.contains("/"), "and never a path, a command or a flag -- got: \(whole)")
    expect(
        notice.continueTitle == "Continue",
        "one button, and it only takes the notice away -- got: \(notice.continueTitle)"
    )
    print("PASS: the software-decode notice names what happened and where the decoder comes from")
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

/// Tailscale on Linux is a daemon with no application to open, so the sentence
/// that names how to get it is the platform's to supply.
private func testTailscaleInstallHintIsPlatformNeutral() {
    expect(
        TailnetDevicePickerFetchError.tailscaleNotInstalled.reason
            == "Tailscale doesn\u{2019}t seem to be installed on this machine. Install Tailscale and sign in, "
                + "then choose Look again.",
        "the default sentence is the one the macOS viewer already showed -- got: "
            + "\(TailnetDevicePickerFetchError.tailscaleNotInstalled.reason)"
    )
    let linux = TailnetDevicePickerFetchError.tailscaleNotInstalled.reason(
        installHint: TailnetDevicePickerFetchError.linuxInstallHint
    )
    expect(
        linux == "Tailscale doesn\u{2019}t seem to be installed on this machine. Install Tailscale for Linux "
            + "from your distribution, sign in, then choose Look again.",
        "and a platform with no application to open says how that platform installs it -- got: \(linux)"
    )
    expect(
        !linux.contains("app"),
        "never \u{201C}open the Tailscale app\u{201D} where there is no app -- got: \(linux)"
    )
    expect(
        TailnetDevicePickerState.from(
            .failure(.tailscaleNotInstalled),
            installHint: TailnetDevicePickerFetchError.linuxInstallHint
        ) == .unreachable(reason: linux),
        "and the picker draws that sentence, not the default one"
    )
    print("PASS: the not-installed reason takes its install sentence from the platform")
}


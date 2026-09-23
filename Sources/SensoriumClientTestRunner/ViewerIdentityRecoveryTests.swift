#if canImport(AppKit)
import AppKit
import Foundation
import SensoriumClient
import SensoriumCore

/// The viewer's recovery from a key it cannot read, driven entirely against
/// a fake `DeviceIdentityReplacing` rather than the real file-backed store,
/// so nothing here writes a key on whatever machine runs it.
private final class FakeDeviceIdentityReplacing: DeviceIdentityReplacing, @unchecked Sendable {
    var result: Result<DeviceIdentity, Error> = .failure(FakeReplaceError.notConfigured)
    private(set) var callCount = 0

    func makeReplacementIdentity() throws -> DeviceIdentity {
        callCount += 1
        return try result.get()
    }

    func store(_ identity: DeviceIdentity) throws {}
}

private enum FakeReplaceError: Error, Equatable, LocalizedError {
    case notConfigured
    case stillStuck(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "no result was configured for this fake"
        case let .stillStuck(reason):
            return reason
        }
    }
}

/// What the failure panel actually reads when the real store refuses the
/// file, rather than what a hand-written reason would put there.
func testViewerIdentityFailureCopyReadsAsASentence() {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-viewer-identity-copy-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("device-identity.json")
    try! Data("this is not an identity".utf8).write(to: url)

    guard case let .failure(failure) = ViewerIdentityRecovery.load(using: FileDeviceIdentityStore(url: url)) else {
        expect(false, "the real store refuses a corrupt file, so the load reports a failure")
        return
    }
    let copy = ViewerStartupFailureCopy.copy(for: failure)
    expect(
        copy.detail.contains("The file holding the key that identifies this machine could not be read"),
        "the panel states in a sentence what could not be read -- got \(copy.detail)"
    )
    expect(
        !copy.detail.contains("invalidStoredValue"),
        "no Swift case name reaches the screen -- got \(copy.detail)"
    )

    print("PASS: the viewer's failure panel states the real store's refusal as a sentence, never as a Swift case name")
}

@MainActor
func testViewerIdentityRecoveryTests() async {
    do {
        // unreadable key -> replace -> normal first run
        let fake = FakeDeviceIdentityReplacing()
        let fresh = try! DeviceIdentity.generate()
        fake.result = .success(fresh)

        let outcome = ViewerIdentityRecovery.replace(using: fake)
        guard case let .success(identity) = outcome else {
            expect(false, "a replace that succeeds resolves to the fresh identity, not a failure")
            return
        }
        expect(identity.publicKey == fresh.publicKey, "the identity the state machine reports is the exact one the seam produced, not a re-derived one")
        expect(fake.callCount == 1, "exactly one replace attempt for one tap")

        print("PASS: an unreadable identity, replaced through the seam, resolves to the fresh identity -- the state machine's 'normal first run' step")
    }

    do {
        // A replace attempt that itself fails is reported as a
        // failure again, not silently treated as success.
        let fake = FakeDeviceIdentityReplacing()
        fake.result = .failure(FakeReplaceError.stillStuck("the replacement file is also unwritable"))

        let outcome = ViewerIdentityRecovery.replace(using: fake)
        guard case let .failure(failure) = outcome else {
            expect(false, "a replace that throws must never resolve to success")
            return
        }
        expect(
            {
                if case let .unreadable(reason) = failure {
                    return reason.contains("the replacement file is also unwritable")
                }
                return false
            }(),
            "the seam's own failure reaches the caller as an unreadable-identity failure carrying its reason, not a generic one"
        )

        print("PASS: a replace attempt that itself fails is reported as a failure, never mistaken for success")
    }

    do {
        // Sentence case, and the two facts a person needs before tapping:
        // what breaks (the key itself) and what to do about it (pair
        // again), each its own sentence.
        let copy = ViewerStartupFailureCopy.copy(for: .unreadable(reason: "the stored key is malformed"))
        expect(
            copy.replaceButtonTitle == "Make a new key",
            "the button title is sentence case, not Title Case -- got \(copy.replaceButtonTitle)"
        )
        expect(
            copy.replaceConsequence == "Make a new key replaces the key that identifies this machine. The host "
                + "will then ask for a pairing code again.",
            "the consequence states both facts plainly, one sentence each -- got \(copy.replaceConsequence)"
        )
        expect(
            copy.retryButtonTitle == "Try again",
            "the first thing to try is repeating the read that just failed -- got \(copy.retryButtonTitle)"
        )
        expect(
            copy.detail.contains("the stored key is malformed"),
            "the detail carries the reason the read gave, so the screen is a real defect report -- got \(copy.detail)"
        )

        print("PASS: the viewer's startup copy offers Try again first, then Make a new key with its consequence stated")
    }

    do {
        // The failure screen's two-button shape: tapping either one
        // resolves run() with the button that was actually tapped.
        let copy = ViewerStartupFailureCopy.copy(for: .unreadable(reason: "the stored key is malformed"))
        let actionMessage = ViewerMessageWindowController(
            eyebrow: "CANNOT START",
            headline: copy.headline,
            detail: copy.detail + "\n\n" + copy.replaceConsequence,
            actionTitle: copy.replaceButtonTitle,
            dismissTitle: "Quit Sensorium"
        )
        let actionTask = Task { await actionMessage.run() }
        actionMessage.actionTapped()
        expect(await actionTask.value == .actionTapped, "tapping the replace action resolves run() with .actionTapped, not .dismissed")

        let dismissMessage = ViewerMessageWindowController(
            eyebrow: "CANNOT START",
            headline: copy.headline,
            detail: copy.detail,
            actionTitle: copy.replaceButtonTitle,
            dismissTitle: "Quit Sensorium"
        )
        let dismissTask = Task { await dismissMessage.run() }
        dismissMessage.dismiss()
        expect(await dismissTask.value == .dismissed, "tapping dismiss on the same two-button window still resolves .dismissed, not .actionTapped")

        print("PASS: the failure window's two buttons resolve run() with the one that was actually tapped")
    }

    do {
        // The default (Return) button always sits in the top slot,
        // whichever role -- action or dismiss -- happens to hold it:
        // the reader's eye and the keyboard both meet the same
        // button first, rather than Return firing whatever is
        // visually second.
        func stackView(in view: NSView) -> NSStackView? {
            for subview in view.subviews {
                if let stack = subview as? NSStackView { return stack }
                if let found = stackView(in: subview) { return found }
            }
            return nil
        }
        func buttonOrder(of controller: ViewerMessageWindowController) -> [String] {
            var window: NSWindow?
            for child in Mirror(reflecting: controller).children where child.label == "window" {
                window = child.value as? NSWindow
            }
            guard let window, let content = window.contentView, let stack = stackView(in: content) else {
                fatalError("ViewerMessageWindowController no longer exposes a window with an NSStackView")
            }
            return stack.arrangedSubviews.compactMap { ($0 as? NSButton)?.attributedTitle.string }
        }

        let replaceFirstMessage = ViewerMessageWindowController(
            eyebrow: "CANNOT START",
            headline: "headline",
            detail: "detail",
            actionTitle: "Make a new key",
            actionIsDefault: false,
            dismissTitle: "Quit Sensorium"
        )
        expect(
            buttonOrder(of: replaceFirstMessage) == ["Quit Sensorium", "Make a new key"],
            "the default button (Quit Sensorium) sits above the non-default one -- got \(buttonOrder(of: replaceFirstMessage))"
        )

        let retryFirstMessage = ViewerMessageWindowController(
            eyebrow: "CANNOT START",
            headline: "headline",
            detail: "detail",
            actionTitle: "Try again",
            actionIsDefault: true,
            dismissTitle: "Quit Sensorium"
        )
        expect(
            buttonOrder(of: retryFirstMessage) == ["Try again", "Quit Sensorium"],
            "the default button (Try again) sits above the non-default one -- got \(buttonOrder(of: retryFirstMessage))"
        )

        print("PASS: ViewerMessageWindowController always puts the default button in the top slot")
    }
}

/// The three-button shape the launch path actually shows: try the read
/// again, make a new key, or quit.
@MainActor
func testViewerIdentityFailureButtonsTests() async {
    do {
        let copy = ViewerStartupFailureCopy.copy(for: .unreadable(reason: "the stored key is malformed"))
        func window() -> ViewerMessageWindowController {
            ViewerMessageWindowController(
                eyebrow: "CANNOT START",
                headline: copy.headline,
                detail: copy.detail,
                actionTitle: copy.retryButtonTitle,
                actionIsDefault: true,
                secondaryActionTitle: copy.replaceButtonTitle,
                dismissTitle: "Quit Sensorium"
            )
        }

        let retrying = window()
        let retryingTask = Task { await retrying.run() }
        retrying.actionTapped()
        expect(await retryingTask.value == .actionTapped, "tapping Try again resolves run() with .actionTapped")

        let replacing = window()
        let replacingTask = Task { await replacing.run() }
        replacing.secondaryActionTapped()
        expect(await replacingTask.value == .secondaryActionTapped, "tapping Make a new key resolves run() with .secondaryActionTapped, not .actionTapped")

        let quitting = window()
        let quittingTask = Task { await quitting.run() }
        quitting.dismiss()
        expect(await quittingTask.value == .dismissed, "tapping Quit Sensorium still resolves .dismissed with three buttons on screen")

        func stackView(in view: NSView) -> NSStackView? {
            for subview in view.subviews {
                if let stack = subview as? NSStackView { return stack }
                if let found = stackView(in: subview) { return found }
            }
            return nil
        }
        func buttonOrder(of controller: ViewerMessageWindowController) -> [String] {
            var found: NSWindow?
            for child in Mirror(reflecting: controller).children where child.label == "window" {
                found = child.value as? NSWindow
            }
            guard let found, let content = found.contentView, let stack = stackView(in: content) else {
                fatalError("ViewerMessageWindowController no longer exposes a window with an NSStackView")
            }
            return stack.arrangedSubviews.compactMap { ($0 as? NSButton)?.attributedTitle.string }
        }
        expect(
            buttonOrder(of: window()) == ["Try again", "Make a new key", "Quit Sensorium"],
            "the three buttons read first choice, second choice, then the way out -- got \(buttonOrder(of: window()))"
        )

        print("PASS: the failure window carries a third button and reports which of the three was pressed")
    }
}
#endif

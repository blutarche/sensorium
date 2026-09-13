import AppKit
import Foundation
import SensoriumHost

/// `HostSetupWindowController`'s Open Tailscale button, exercised only
/// through its injected closures -- `tailscaleAppURLLookup` and
/// `onOpenTailscaleApp` -- so none of this needs `NSApplication` running or
/// a window actually on screen. `Mirror` reads the button's own `isHidden`
/// past the controller's private storage, and its real `target`/`action`
/// fire the tap exactly as AppKit's own click handling would.
@MainActor
func runHostSetupTailscaleButtonTests() async {
    let granted = HostPermissionRequestResult(screenCapture: .granted, accessibility: .granted)
    let fakeAppURL = URL(fileURLWithPath: "/Applications/Tailscale.app")
    let tailscaleDownloadURL = URL(string: "https://tailscale.com/download")!

    func tailscaleButton(in controller: HostSetupWindowController) -> NSButton {
        for child in Mirror(reflecting: controller).children {
            if child.label == "tailscaleButton", let button = child.value as? NSButton {
                return button
            }
        }
        fatalError("HostSetupWindowController no longer has a stored property named tailscaleButton")
    }

    func tap(_ button: NSButton) {
        guard let action = button.action, let target = button.target as? NSObject else {
            fatalError("the Open Tailscale button has no target/action wired")
        }
        _ = target.perform(action, with: button)
    }

    /// The status card's own body text, reached past `HostOperatorPanelView`
    /// (a type this module cannot even name -- internal to `SensoriumHost`)
    /// the same way `PairedMachinesSharingToggleTests` reaches a private field
    /// two levels down: `Mirror` never needs the intermediate type's name,
    /// only the label at each level and the type the leaf value casts to.
    func statusPresentation(in controller: HostSetupWindowController) -> HostOperatorPresentation {
        func field<T>(_ name: String, of object: Any) -> T {
            for child in Mirror(reflecting: object).children {
                if child.label == name, let value = child.value as? T {
                    return value
                }
            }
            fatalError("no stored property named \(name) of type \(T.self)")
        }
        let panel: NSView = field("panel", of: controller)
        return field("presentation", of: panel)
    }

    func statusDetail(in controller: HostSetupWindowController) -> String {
        statusPresentation(in: controller).detail
    }

    func controller(problem: String?, tailscaleAppURLLookup: @escaping @MainActor () -> URL?, onOpenTailscaleApp: @escaping @MainActor (URL) -> Void) -> HostSetupWindowController {
        HostSetupWindowController(
            status: HostOperatorStatus(connection: .notHosting, permissions: granted, problem: problem),
            onRevealPairingCode: {},
            onStop: {},
            tailscaleAppURLLookup: tailscaleAppURLLookup,
            onOpenTailscaleApp: onOpenTailscaleApp,
            onToggleSharing: { _, _ in },
            onRemovePairedDevice: { _ in }
        )
    }

    do {
        // Wrong problem: hidden even though the lookup finds the app
        let button = tailscaleButton(in: controller(
            problem: "Could not start hosting on 100.100.0.4: address already in use",
            tailscaleAppURLLookup: { fakeAppURL },
            onOpenTailscaleApp: { _ in }
        ))
        expect(button.isHidden, "a bind failure is not fixed by opening Tailscale, so the button stays hidden even though the lookup found the app")

        print("PASS: the Open Tailscale button stays hidden when status.problem is not noTailnetAddress, even if the lookup finds the app")
    }

    do {
        // Right problem, app not found: "Download Tailscale", not hidden,
        // and body text that does not contradict a button that can
        // only offer to install the app.
        let hostController = controller(
            problem: HostStartupProblemCopy.noTailnetAddress,
            tailscaleAppURLLookup: { nil },
            onOpenTailscaleApp: { _ in }
        )
        let button = tailscaleButton(in: hostController)
        expect(!button.isHidden, "with Tailscale not installed, the button still offers a way to get it rather than disappearing")
        expect(button.title == "Download Tailscale", "the not-installed case reads \"Download Tailscale\", not \"Open Tailscale\"")
        expect(
            statusDetail(in: hostController) == HostStartupProblemCopy.tailscaleNotInstalled,
            "the not-installed case's body text says to install Tailscale, not to start something that is not "
                + "there to start -- got: \(statusDetail(in: hostController))"
        )
        expect(
            HostStartupProblemCopy.tailscaleNotInstalled
                == "Download Tailscale and sign in; this machine then becomes reachable.",
            "the body text starts with the button's own verb, so the two read as one instruction -- got: "
                + "\(HostStartupProblemCopy.tailscaleNotInstalled)"
        )
        expect(
            statusPresentation(in: hostController).headline == "Tailscale is not installed",
            "the not-installed case's headline names the cause, not the running case's -- got: "
                + "\(statusPresentation(in: hostController).headline)"
        )

        print("PASS: the Open Tailscale button reads \"Download Tailscale\" when the problem matches but the lookup finds nothing, and the body text matches")
    }

    do {
        // Right problem, app found: "Open Tailscale", visible, and
        // body text that matches a button which only needs to open
        // the app.
        let hostController = controller(
            problem: HostStartupProblemCopy.noTailnetAddress,
            tailscaleAppURLLookup: { fakeAppURL },
            onOpenTailscaleApp: { _ in }
        )
        let button = tailscaleButton(in: hostController)
        expect(!button.isHidden, "the no-address problem with the app actually found is exactly the case this button exists for")
        expect(button.title == "Open Tailscale", "the installed case reads \"Open Tailscale\", not \"Download Tailscale\"")
        expect(
            statusDetail(in: hostController) == HostStartupProblemCopy.noTailnetAddress,
            "the installed case's body text says to start Tailscale, matching the Open Tailscale button -- got: "
                + "\(statusDetail(in: hostController))"
        )
        expect(
            HostStartupProblemCopy.noTailnetAddress
                == "Open Tailscale and let it connect; this machine then becomes reachable.",
            "the same parallel form as tailscaleNotInstalled's \"Download Tailscale and sign in; this machine then becomes "
                + "reachable\" -- got: \(HostStartupProblemCopy.noTailnetAddress)"
        )
        expect(
            statusPresentation(in: hostController).headline == "Tailscale is not running",
            "the installed case's headline names the cause -- got: \(statusPresentation(in: hostController).headline)"
        )

        print("PASS: the Tailscale button and body text read \"Open Tailscale\" when there is no tailnet address and the app is installed")
    }

    do {
        // Installed: tapping passes exactly the looked-up URL
        var openedURL: URL?
        let button = tailscaleButton(in: controller(
            problem: HostStartupProblemCopy.noTailnetAddress,
            tailscaleAppURLLookup: { fakeAppURL },
            onOpenTailscaleApp: { openedURL = $0 }
        ))
        tap(button)
        expect(openedURL == fakeAppURL, "tapping passes the exact URL the lookup resolved, not a re-looked-up or reconstructed one")

        print("PASS: tapping the installed-case button passes exactly the looked-up URL to onOpenTailscaleApp")
    }

    do {
        // Not installed: tapping opens Tailscale's own download page
        var openedURL: URL?
        let button = tailscaleButton(in: controller(
            problem: HostStartupProblemCopy.noTailnetAddress,
            tailscaleAppURLLookup: { nil },
            onOpenTailscaleApp: { openedURL = $0 }
        ))
        tap(button)
        expect(openedURL == tailscaleDownloadURL, "tapping the not-installed button opens Tailscale's own download page")

        print("PASS: tapping the not-installed-case button opens https://tailscale.com/download through onOpenTailscaleApp")
    }
}

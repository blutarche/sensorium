import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// The power-management calls a live session makes on this machine.
///
/// A seam rather than direct IOKit calls, for the same reason
/// `HostScreenModeControlling` is one: what a session is allowed to do to
/// this machine's power state is a rule, and a rule is verified against a
/// fake. Nothing here configures a display. Waking one and holding it out
/// of idle sleep are the only two things a session may do, both through
/// public IOKit power management.
@MainActor
public protocol DisplayPowerControlling: AnyObject {
    /// Tells macOS that someone is active at this machine. A display that
    /// idled to sleep wakes; a machine that is itself asleep stays asleep.
    func declareUserActivity()
    /// Holds the displays out of idle sleep under `name`, which is what
    /// macOS shows anyone asking what is keeping this machine's screen on.
    func preventDisplaySleep(named name: String)
    /// Drops that hold. Idle sleep behaves exactly as it did before.
    func allowDisplaySleep()
}

/// The real calls, through public IOKit power management.
@MainActor
public final class IOKitDisplayPower: DisplayPowerControlling {
    /// Reused across calls, as `IOPMAssertionDeclareUserActivity` documents:
    /// one activity assertion per process rather than a new one per session.
    private var userActivityAssertion = IOPMAssertionID(0)
    private var displaySleepAssertion: IOPMAssertionID?

    public init() {}

    public func declareUserActivity() {
        var assertion = userActivityAssertion
        let result = IOPMAssertionDeclareUserActivity(
            DisplayWakeController.assertionName as CFString,
            kIOPMUserActiveLocal,
            &assertion
        )
        guard result == kIOReturnSuccess else {
            return
        }
        userActivityAssertion = assertion
    }

    public func preventDisplaySleep(named name: String) {
        guard displaySleepAssertion == nil else {
            return
        }
        var assertion = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertPreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            name as CFString,
            &assertion
        )
        guard result == kIOReturnSuccess else {
            return
        }
        displaySleepAssertion = assertion
    }

    public func allowDisplaySleep() {
        guard let assertion = displaySleepAssertion else {
            return
        }
        displaySleepAssertion = nil
        IOPMAssertionRelease(assertion)
    }
}

/// Wakes this machine's displays at the start of a session, and keeps them
/// awake while one is live.
///
/// macOS draws nothing at all while a display sleeps, virtual displays
/// included, so a session that starts against a sleeping machine captures a
/// picture that never arrives. Waking first is what makes a session
/// possible; holding the displays awake is what keeps it alive past the
/// idle timer. Neither changes any display's configuration.
///
/// One instance per host process, shared by every session on it: the hold is
/// a single assertion this process either has or does not have.
@MainActor
public final class DisplayWakeController {
    /// What macOS shows anyone asking what is keeping this machine's screen
    /// on, and the name the activity declaration carries too.
    public static let assertionName = "Sensorium session is live"
    /// How long a display is given to come back before a session goes on
    /// without it. Long enough for a monitor to light up, short enough that
    /// a viewer is not left watching a connection that may never start.
    public static let defaultWakeSeconds = 5.0
    public static let defaultPollSeconds = 0.1
    /// How long monitors that display sleep took offline are given to come
    /// back online after a wake before an offer is built without them.
    public static let defaultSettleSeconds = 3.0
    /// How long the set of online displays must hold still, once a monitor
    /// is back, before it counts as settled. Monitors attached to one
    /// machine come back one after another, not all at once.
    public static let settledHoldSeconds = 0.5

    private let power: any DisplayPowerControlling
    private let displays: () -> [DisplaySnapshot]
    /// How a poll interval is waited out, injected so a test proves the
    /// bound without spending it.
    private let wait: (Double) async -> Void
    private let wakeSeconds: Double
    private let settleSeconds: Double
    private let pollSeconds: Double
    private let log: ((String) -> Void)?

    /// How many live sessions are holding this machine's displays awake.
    /// Counted rather than a flag because this host serves more than one
    /// connection at a time: the session that ends first must not take the
    /// screen out from under a session that is still running.
    public private(set) var sessionsHoldingDisplaysAwake = 0

    /// Whether anything is holding the displays out of idle sleep right now.
    public var isHoldingDisplaysAwake: Bool {
        sessionsHoldingDisplaysAwake > 0
    }

    public init(
        power: any DisplayPowerControlling = IOKitDisplayPower(),
        displays: @escaping () -> [DisplaySnapshot] = DisplayInventory.online,
        wait: @escaping (Double) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        timeoutSeconds: Double = DisplayWakeController.defaultWakeSeconds,
        pollSeconds: Double = DisplayWakeController.defaultPollSeconds,
        settleSeconds: Double = DisplayWakeController.defaultSettleSeconds,
        log: ((String) -> Void)? = nil
    ) {
        self.power = power
        self.displays = displays
        self.wait = wait
        wakeSeconds = max(timeoutSeconds, 0)
        self.settleSeconds = max(settleSeconds, 0)
        self.pollSeconds = max(pollSeconds, 0.01)
        self.log = log
    }

    /// Displays this machine has online that macOS is not drawing to.
    public var sleepingDisplayIDs: Set<UInt32> {
        Set(displays().filter { $0.online && $0.asleep }.map(\.id))
    }

    /// Whether anything online on this machine is asleep right now. Read
    /// before a session gives up on a capture that delivers nothing: a
    /// sleeping display explains that, and quitting the host does not.
    public var anyDisplayIsAsleep: Bool {
        !sleepingDisplayIDs.isEmpty
    }

    /// Wakes this machine's displays if any are asleep, and waits for the
    /// ones named in `targets` to come back. An empty `targets` means every
    /// online display.
    ///
    /// `true` means nothing in scope is asleep by the time this returns,
    /// which includes the common case where nothing was asleep to begin
    /// with and no power call was made at all. `false` means the wait ran
    /// out with a display still asleep, and the caller decides what a
    /// session does about that.
    @discardableResult
    public func wakeDisplays(targets: Set<UInt32> = []) async -> Bool {
        func stillAsleep() -> Set<UInt32> {
            let sleeping = sleepingDisplayIDs
            return targets.isEmpty ? sleeping : sleeping.intersection(targets)
        }
        guard !stillAsleep().isEmpty else {
            return true
        }
        log?("waking this machine's displays; a sleeping display draws nothing to capture")
        power.declareUserActivity()
        return await waitForDisplaysToWake(targets: targets)
    }

    /// Declares user activity whatever the displays report, then waits for
    /// the set of online displays to settle, up to `settleSeconds`.
    ///
    /// Display sleep can take a monitor offline rather than leave it online
    /// and asleep. A machine in that state reads as nothing asleep at all:
    /// on a Mac mini the only display online is macOS's headless stand-in,
    /// which reads awake and captures black. So nothing here is gated on a
    /// display reading asleep. When an awake monitor is already online the
    /// monitors are on and this returns without waiting. Otherwise it polls
    /// until an awake monitor is online and the set of online displays has
    /// held still for `settledHoldSeconds`. A machine with no monitor
    /// attached waits out the bound and is left with the stand-in, which is
    /// then all it has.
    public func wakeAndSettleDisplays() async {
        power.declareUserActivity()
        var previous = displays().filter(\.online)
        guard !Self.hasAwakeMonitor(previous) else {
            return
        }
        let holdPolls = Int((Self.settledHoldSeconds / pollSeconds).rounded(.up))
        var unchangedPolls = 0
        var waited = 0.0
        while waited < settleSeconds {
            await wait(pollSeconds)
            if Task.isCancelled {
                return
            }
            waited += pollSeconds
            let current = displays().filter(\.online)
            unchangedPolls = Set(current.map(\.id)) == Set(previous.map(\.id)) ? unchangedPolls + 1 : 0
            previous = current
            if Self.hasAwakeMonitor(current), unchangedPolls >= holdPolls {
                return
            }
        }
        log?("no monitor came online after waking this machine's displays")
    }

    /// Waits, without declaring anything, for the displays named in
    /// `targets` to stop reading asleep, up to `timeoutSeconds`. An empty
    /// `targets` means every online display. `true` when none in scope is
    /// asleep by the time this returns.
    @discardableResult
    public func waitForDisplaysToWake(targets: Set<UInt32> = []) async -> Bool {
        func stillAsleep() -> Set<UInt32> {
            let sleeping = sleepingDisplayIDs
            return targets.isEmpty ? sleeping : sleeping.intersection(targets)
        }
        guard !stillAsleep().isEmpty else {
            return true
        }
        var waited = 0.0
        while waited < wakeSeconds {
            await wait(pollSeconds)
            // A cancelled task's sleep returns at once, so without this the
            // poll below would spin through the whole wait in no time at all.
            // The session this was waiting for is going away regardless.
            if Task.isCancelled {
                return false
            }
            waited += pollSeconds
            if stillAsleep().isEmpty {
                return true
            }
        }
        log?("this machine's displays are still asleep after waiting for them to wake")
        return false
    }

    /// An online, awake display that is neither the headless stand-in nor a
    /// canvas Sensorium created: proof that this machine's monitors are on.
    private static func hasAwakeMonitor(_ online: [DisplaySnapshot]) -> Bool {
        online.contains {
            !$0.asleep && !PhysicalDisplayEvidence.isHeadlessStandIn($0) && !PhysicalDisplayEvidence.isSensoriumCanvas($0)
        }
    }

    /// Keeps the displays awake for as long as this session is live. One
    /// assertion however many sessions ask for one; each caller releases its
    /// own hold, and every caller must balance this with exactly one
    /// `releaseDisplaysAwake`.
    public func holdDisplaysAwake() {
        sessionsHoldingDisplaysAwake += 1
        guard sessionsHoldingDisplaysAwake == 1 else {
            return
        }
        power.preventDisplaySleep(named: Self.assertionName)
    }

    /// Drops this session's own hold. Called on every path that ends a
    /// session, including the ones that end it on an error and the one that
    /// ends it because the host is quitting. This machine idles its displays
    /// again only once the last live session has let go.
    public func releaseDisplaysAwake() {
        guard sessionsHoldingDisplaysAwake > 0 else {
            return
        }
        sessionsHoldingDisplaysAwake -= 1
        guard sessionsHoldingDisplaysAwake == 0 else {
            return
        }
        power.allowDisplaySleep()
    }

    /// Drops every hold at once, for the one caller that knows no session can
    /// still be live: this process quitting. A session teardown must use
    /// `releaseDisplaysAwake` instead, which lets go of its own hold alone.
    public func releaseEveryHold() {
        guard sessionsHoldingDisplaysAwake > 0 else {
            return
        }
        sessionsHoldingDisplaysAwake = 0
        power.allowDisplaySleep()
    }
}

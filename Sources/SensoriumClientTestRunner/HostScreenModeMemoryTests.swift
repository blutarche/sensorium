import Foundation
import SensoriumClient
import SensoriumCore

/// The memory that makes a host-screen session ask for the same resolution
/// automatically, without ever touching a live connection.
private let native = HostScreenModeEntry(
    modeID: "session-a-native",
    width: 3008,
    height: 1692,
    pixelWidth: 3008,
    pixelHeight: 1692,
    refreshRate: 60,
    isHiDPI: false
)

private let readable = HostScreenModeEntry(
    modeID: "session-a-readable",
    width: 1920,
    height: 1080,
    pixelWidth: 3840,
    pixelHeight: 2160,
    refreshRate: 60,
    isHiDPI: true
)

private func temporaryHostScreenModeMemoryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("sensorium-hostscreen-mode-memory-tests-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("host-screen-mode-memory.json")
}

@MainActor
func testHostScreenModeMemoryTests() async {
    do {
        // A store holds one remembered mode per (machine, screen), and
        // a second remember for the same pair replaces it in place.
        let store = InMemoryHostScreenModeMemoryStore()
        let key = Data([1])
        expect(
            store.remembered(hostPublicKey: key, displayIdentity: "display-a") == nil,
            "nothing is remembered before anything is ever chosen"
        )
        store.remember(hostPublicKey: key, displayIdentity: "display-a", mode: RememberedHostScreenMode(readable))
        expect(
            store.remembered(hostPublicKey: key, displayIdentity: "display-a") == RememberedHostScreenMode(readable),
            "the choice round-trips through the store"
        )
        store.remember(hostPublicKey: key, displayIdentity: "display-a", mode: RememberedHostScreenMode(native))
        expect(
            store.remembered(hostPublicKey: key, displayIdentity: "display-a") == RememberedHostScreenMode(native),
            "choosing again for the same screen replaces the earlier choice rather than keeping both"
        )
        expect(
            store.remembered(hostPublicKey: key, displayIdentity: "display-b") == nil,
            "a different screen on the same machine has its own, unrelated memory"
        )
        expect(
            store.remembered(hostPublicKey: Data([2]), displayIdentity: "display-a") == nil,
            "a different machine has its own, unrelated memory even for the same display identity"
        )
        print("PASS: the mode memory store keys on machine and screen together, and a later choice replaces an earlier one")
    }

    do {
        // The file store round-trips through a real file, owner-only,
        // and a corrupt file reads back as no memory rather than crashing.
        let url = temporaryHostScreenModeMemoryURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileHostScreenModeMemoryStore(url: url)
        let key = Data([9, 9])
        store.remember(hostPublicKey: key, displayIdentity: "display-x", mode: RememberedHostScreenMode(readable))
        let reloaded = FileHostScreenModeMemoryStore(url: url)
        expect(
            reloaded.remembered(hostPublicKey: key, displayIdentity: "display-x") == RememberedHostScreenMode(readable),
            "a fresh store reading the same file finds what an earlier one wrote"
        )
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        expect(
            (attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600,
            "the file is owner-readable only, got \(String(describing: attributes?[.posixPermissions]))"
        )

        try? Data("not json at all".utf8).write(to: url)
        let corrupted = FileHostScreenModeMemoryStore(url: url)
        expect(
            corrupted.remembered(hostPublicKey: key, displayIdentity: "display-x") == nil,
            "a corrupt file reads as no remembered modes rather than crashing"
        )
        expect(
            HostScreenModeMemoryFileCoding.decode(Data("not json at all".utf8)).isEmpty,
            "the coding layer itself treats anything that is not the recorded shape as empty"
        )
        print("PASS: the mode memory file store round-trips, is owner-only, and a corrupt file reads as empty")
    }

    do {
        // Matching a remembered shape back against a fresh offer looks
        // at width, height, and HiDPI -- never the mode ID, which a
        // new session mints fresh.
        let rememberedReadable = RememberedHostScreenMode(readable)
        expect(
            HostScreenModeMatching.entry(for: rememberedReadable, in: [native, readable])?.modeID == readable.modeID,
            "the remembered shape finds this session's own mode ID for it"
        )
        let unofferedShape = RememberedHostScreenMode(width: 2560, height: 1440, isHiDPI: false)
        expect(
            HostScreenModeMatching.entry(for: unofferedShape, in: [native, readable]) == nil,
            "a shape this offer does not carry matches nothing"
        )
        // Same point size as `readable`, but not HiDPI -- a plain mode of
        // that size must not be confused with the scaled one design §5's own
        // doc comment on `HostScreenModeEntry` distinguishes by this flag.
        let samePointSizeNonHiDPI = RememberedHostScreenMode(width: readable.width, height: readable.height, isHiDPI: false)
        expect(
            HostScreenModeMatching.entry(for: samePointSizeNonHiDPI, in: [native, readable]) == nil,
            "a remembered non-HiDPI shape does not match a HiDPI mode of the same point size"
        )
        print("PASS: matching looks at a mode's shape, not its per-session identifier")
    }

    do {
        // The restore decision: remembered, offered, and different from
        // the current mode is the only case that asks for anything.
        let restoring = HostScreenModeRestoreDecision.decide(
            remembered: RememberedHostScreenMode(readable), modes: [native, readable], currentModeID: native.modeID
        )
        expect(
            restoring == .restore(modeID: readable.modeID, mode: RememberedHostScreenMode(readable)),
            "a remembered, offered, different mode is restored, got \(restoring)"
        )
        expect(
            HostScreenModeRestoreDecision.logLine(for: restoring)
                == "resolution: restoring 1920x1080 (HiDPI) chosen last time",
            "the log line names the shape being restored, got \(String(describing: HostScreenModeRestoreDecision.logLine(for: restoring)))"
        )

        let alreadyThere = HostScreenModeRestoreDecision.decide(
            remembered: RememberedHostScreenMode(native), modes: [native, readable], currentModeID: native.modeID
        )
        expect(
            alreadyThere == .alreadyCurrent(mode: RememberedHostScreenMode(native)),
            "a remembered mode the screen is already on asks for nothing, got \(alreadyThere)"
        )
        expect(
            HostScreenModeRestoreDecision.logLine(for: alreadyThere) == nil,
            "and says nothing, since nothing happened"
        )

        let nothingRemembered = HostScreenModeRestoreDecision.decide(
            remembered: nil, modes: [native, readable], currentModeID: native.modeID
        )
        expect(nothingRemembered == .noRememberedChoice, "no memory means no decision to act on")
        expect(HostScreenModeRestoreDecision.logLine(for: nothingRemembered) == nil, "and no line either")

        let goneMissing = HostScreenModeRestoreDecision.decide(
            remembered: RememberedHostScreenMode(width: 2560, height: 1440, isHiDPI: false),
            modes: [native, readable],
            currentModeID: native.modeID
        )
        expect(
            goneMissing == .rememberedChoiceUnavailable(mode: RememberedHostScreenMode(width: 2560, height: 1440, isHiDPI: false)),
            "a remembered shape this offer no longer carries is left alone rather than guessed at, got \(goneMissing)"
        )
        expect(
            HostScreenModeRestoreDecision.logLine(for: goneMissing)
                == "resolution: 2560x1440 (non-HiDPI) chosen last time is not offered this session",
            "and says so once, got \(String(describing: HostScreenModeRestoreDecision.logLine(for: goneMissing)))"
        )
        print("PASS: the restore decision only ever acts on a remembered, offered, different mode")
    }

    do {
        // The auto-restore gate fires at most once per instance -- the
        // per-session lifetime a fresh `ClientSessionHost.runOnce()`
        // call already gives it -- however that first attempt turned out.
        let gate = HostScreenModeAutoRestore()
        let first = gate.attempt(
            remembered: RememberedHostScreenMode(readable), modes: [native, readable], currentModeID: native.modeID
        )
        expect(first == .restore(modeID: readable.modeID, mode: RememberedHostScreenMode(readable)), "the first attempt decides normally")
        let second = gate.attempt(
            remembered: RememberedHostScreenMode(readable), modes: [native, readable], currentModeID: native.modeID
        )
        expect(second == nil, "a second attempt in the same session sends nothing, even asked the same question again")

        let neverAsked = HostScreenModeAutoRestore()
        let onlyOutcome = neverAsked.attempt(remembered: nil, modes: [native], currentModeID: native.modeID)
        expect(onlyOutcome == .noRememberedChoice, "a gate that has never fired still decides its first call")
        expect(
            neverAsked.attempt(remembered: nil, modes: [native], currentModeID: native.modeID) == nil,
            "and still refuses a second one even when the first found nothing to restore"
        )
        print("PASS: the auto-restore gate acts at most once per instance")
    }

    do {
        // Recording only ever happens from an applied mode -- the modeID
        // a live `hostScreenModeApplied` names is looked up in the same
        // offer list, never invented from geometry.
        let recorded = HostScreenModeMemoryUpdate.remembering(currentModeID: readable.modeID, in: [native, readable])
        expect(recorded == RememberedHostScreenMode(readable), "the applied mode ID's own shape is what gets remembered")
        expect(
            HostScreenModeMemoryUpdate.remembering(currentModeID: "unknown-mode-id", in: [native, readable]) == nil,
            "a modeID absent from the offer list -- which should never happen -- records nothing rather than guessing"
        )
        print("PASS: only an applied mode ID present in the current offer is ever turned into a remembered shape")
    }
}

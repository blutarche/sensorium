#if os(Linux)

import Foundation
import SensoriumLinuxHost

private let sessionPath = "/org/freedesktop/portal/desktop/session/1_42/sensoriumsession"

private let remoteDesktop = "org.freedesktop.portal.RemoteDesktop"
private let screenCast = "org.freedesktop.portal.ScreenCast"

private func scratchRoot(_ label: String) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-linux-host-test-\(label)-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A bus with a cooperative portal: version 2 of RemoteDesktop, every cursor
/// mode offered, and every step granted.
private func cooperativePortal(
    restoreToken: String? = "new-token",
    streams: [PortalValue]? = nil
) -> FakeDBus {
    let bus = FakeDBus()
    bus.setProperty(remoteDesktop, "version", .uint32(2))
    bus.setProperty(screenCast, "version", .uint32(5))
    bus.setProperty(screenCast, "AvailableCursorModes", .uint32(7))
    bus.react("RemoteDesktop.CreateSession", .respond(code: 0, results: ["session_handle": .string(sessionPath)]))
    bus.react("RemoteDesktop.SelectDevices", .respond(code: 0, results: [:]))
    bus.react("ScreenCast.SelectSources", .respond(code: 0, results: [:]))
    var results: [String: PortalValue] = [
        "devices": .uint32(3),
        "streams": .array(
            streams ?? [.tuple([.uint32(57), .vardict([
                "id": .string("monitor-a"),
                "position": .tuple([.int32(0), .int32(0)]),
                "size": .tuple([.int32(1920), .int32(1080)]),
                "source_type": .uint32(1)
            ])])],
            elementSignature: "(ua{sv})"
        )
    ]
    if let restoreToken {
        results["restore_token"] = .string(restoreToken)
    }
    bus.react("RemoteDesktop.Start", .respond(code: 0, results: results))
    bus.react("ScreenCast.OpenPipeWireRemote", .reply([.int32(0)], fileDescriptor: 99))
    return bus
}

private struct Rig {
    let bus: FakeDBus
    let store: RestoreTokenStore
    let root: URL
    let client: PortalSessionClient
}

private func makeRig(
    _ label: String,
    bus: FakeDBus,
    storedToken: String? = "old-token",
    startTimesOut: Bool = false
) throws -> Rig {
    let root = scratchRoot(label)
    let store = RestoreTokenStore(dataRoot: root)
    if let storedToken {
        try store.save(storedToken)
    }
    let counter = TokenCounter()
    let client = PortalSessionClient(
        bus: bus,
        tokenStore: store,
        timeouts: PortalTimeouts(start: 15, step: 10),
        sleep: { seconds in
            // A timer that fires at once for the 15 second Start timeout when
            // the test wants that, and otherwise never fires.
            if startTimesOut, seconds == 15 { return }
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        },
        makeToken: { counter.next() }
    )
    return Rig(bus: bus, store: store, root: root, client: client)
}

private final class TokenCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> String {
        lock.withLock {
            value += 1
            return "token\(value)"
        }
    }
}

func testSessionRunsTheFullHandshakeInOrder() async throws {
    let rig = try makeRig("handshake", bus: cooperativePortal())
    defer { try? FileManager.default.removeItem(at: rig.root) }
    let session = try await rig.client.openSession()

    let methods = rig.bus.log.filter { $0.hasPrefix("call ") && !$0.contains("Properties") }
    expect(
        methods == [
            "call RemoteDesktop.CreateSession", "call RemoteDesktop.SelectDevices",
            "call ScreenCast.SelectSources", "call RemoteDesktop.Start"
        ],
        "the handshake is CreateSession, SelectDevices, SelectSources, Start; got \(methods)"
    )

    // Each request's Response subscription is in place before its call.
    for (index, entry) in rig.bus.log.enumerated() where entry.hasPrefix("call ") && !entry.contains("Properties") {
        expect(
            index > 0 && rig.bus.log[index - 1].hasPrefix("subscribe Response "),
            "a Response subscription comes right before \(entry)"
        )
    }

    let create = rig.bus.calls(named: "RemoteDesktop.CreateSession")[0]
    let createOptions = create.parameters[0].vardictValue ?? [:]
    expect(createOptions["handle_token"]?.stringValue != nil, "CreateSession carries a handle_token")
    expect(createOptions["session_handle_token"]?.stringValue != nil, "CreateSession carries a session_handle_token")
    expect(
        createOptions["handle_token"]?.stringValue != createOptions["session_handle_token"]?.stringValue,
        "the request and session tokens differ"
    )

    let select = rig.bus.calls(named: "RemoteDesktop.SelectDevices")[0]
    expect(select.parameters[0] == .objectPath(sessionPath), "SelectDevices names the session as an object path")
    let selectOptions = select.parameters[1].vardictValue ?? [:]
    expect(selectOptions["types"] == .uint32(3), "keyboard and pointer are requested")
    expect(selectOptions["persist_mode"] == .uint32(2), "the grant persists until revoked")
    expect(selectOptions["restore_token"] == .string("old-token"), "the stored token is offered for restore")

    let sources = rig.bus.calls(named: "ScreenCast.SelectSources")[0]
    expect(sources.parameters[0] == .objectPath(sessionPath), "SelectSources names the session")
    let sourceOptions = sources.parameters[1].vardictValue ?? [:]
    expect(sourceOptions["types"] == .uint32(1), "one monitor source type")
    expect(sourceOptions["multiple"] == .bool(false), "a single monitor")
    expect(sourceOptions["cursor_mode"] == .uint32(4), "cursor metadata is asked for when offered")
    expect(sourceOptions["persist_mode"] == nil, "SelectSources carries no persist mode on a RemoteDesktop session")
    expect(sourceOptions["restore_token"] == nil, "SelectSources carries no restore token on a RemoteDesktop session")

    let start = rig.bus.calls(named: "RemoteDesktop.Start")[0]
    expect(start.parameters[0] == .objectPath(sessionPath), "Start names the session")
    expect(start.parameters[1] == .string(""), "Start has no parent window")
    expect(start.parameters[2].vardictValue?["handle_token"]?.stringValue != nil, "Start carries a handle_token")

    expect(session.grant.sessionHandle == sessionPath, "the grant names the session")
    expect(session.grant.devices == [.keyboard, .pointer], "both devices were granted")
    expect(session.grant.restoreToken == "new-token", "the grant carries the new token")
    expect(
        session.grant.streams == [PortalStream(
            nodeID: 57,
            id: "monitor-a",
            position: PortalPoint(x: 0, y: 0),
            size: PortalSize(width: 1920, height: 1080),
            pipeWireSerial: nil
        )],
        "the stream is read from the Start results, got \(session.grant.streams)"
    )
}

func testNewRestoreTokenIsOnDiskBeforeTheSessionIsUsable() async throws {
    let bus = cooperativePortal()
    let rig = try makeRig("token-first", bus: bus)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    expect(rig.store.load() == "old-token", "the old token is stored to begin with")
    let session = try await rig.client.openSession()
    expect(rig.store.load() == "new-token", "the new token replaced the old before openSession returned")
    expect(bus.calls(named: "ScreenCast.OpenPipeWireRemote").isEmpty, "nothing used the session before the token was stored")
    _ = try await session.openPipeWireRemote()
    expect(rig.store.load() == "new-token", "the token is still the new one")
}

func testAnUnstorableTokenClosesTheSessionBeforeAnyUse() async throws {
    let bus = cooperativePortal()
    let rig = try makeRig("token-unwritable", bus: bus, storedToken: nil)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    // The data folder is a regular file, so nothing can be written under it.
    let blocked = scratchRoot("blocked").appendingPathComponent("file")
    try Data().write(to: blocked)
    defer { try? FileManager.default.removeItem(at: blocked.deletingLastPathComponent()) }
    let client = PortalSessionClient(bus: bus, tokenStore: RestoreTokenStore(dataRoot: blocked))
    do {
        _ = try await client.openSession()
        expect(false, "an unstorable token is an error")
    } catch let error as PortalError {
        guard case .tokenNotStored = error else {
            expect(false, "the error is tokenNotStored, got \(error)")
            return
        }
    }
    expect(bus.calls(named: "Session.Close").count == 1, "the session was closed")
    expect(bus.calls(named: "ScreenCast.OpenPipeWireRemote").isEmpty, "nothing used the session")
}

func testAStartThatNeverAnswersClosesTheSessionThenReportsGrantNeeded() async throws {
    let bus = cooperativePortal()
    bus.react("RemoteDesktop.Start", .silent)
    let rig = try makeRig("timeout", bus: bus, startTimesOut: true)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    do {
        _ = try await rig.client.openSession()
        expect(false, "a Start that never answers is an error")
    } catch let error as PortalError {
        expect(error == .grantNeeded, "the error is grantNeeded, got \(error)")
    }
    let closes = bus.calls(named: "Session.Close")
    expect(closes.count == 1, "the session was closed once")
    expect(closes.first?.path == sessionPath, "the close went to the session object")
    expect(closes.first?.interface == "org.freedesktop.portal.Session", "on the Session interface")
    let closeIndex = bus.log.firstIndex(of: "call Session.Close")
    let startIndex = bus.log.firstIndex(of: "call RemoteDesktop.Start")
    expect(startIndex != nil && closeIndex != nil && startIndex! < closeIndex!, "the close follows the Start")
    expect(rig.store.load() == "old-token", "a timed-out Start leaves the stored token alone")
    expect(bus.cancelledSubscriptions >= 4, "every Response subscription was cancelled")
}

func testADialogTheHostPersonDismissesIsDeclinedNotATimeout() async throws {
    let bus = cooperativePortal()
    bus.react("RemoteDesktop.Start", .respond(code: 1, results: [:]))
    let rig = try makeRig("declined", bus: bus)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    do {
        _ = try await rig.client.openSession()
        expect(false, "a declined grant is an error")
    } catch let error as PortalError {
        expect(error == .declined(response: 1), "the error is declined(1), got \(error)")
    }
    expect(bus.calls(named: "Session.Close").count == 1, "the session was closed")
}

func testAnOldPortalVersionIsRefusedBeforeAnythingIsCreated() async throws {
    let bus = cooperativePortal()
    bus.setProperty(remoteDesktop, "version", .uint32(1))
    let rig = try makeRig("old-version", bus: bus)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    do {
        _ = try await rig.client.openSession()
        expect(false, "RemoteDesktop version 1 is refused")
    } catch let error as PortalError {
        expect(
            error == .interfaceTooOld(interface: remoteDesktop, found: 1, required: 2),
            "the error names the interface and versions, got \(error)"
        )
    }
    expect(bus.calls(named: "RemoteDesktop.CreateSession").isEmpty, "no session was created")
}

func testCursorMetadataIsAskedForOnlyWhenOffered() async throws {
    let bus = cooperativePortal()
    bus.setProperty(screenCast, "AvailableCursorModes", .uint32(3))
    let rig = try makeRig("no-metadata", bus: bus)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    _ = try await rig.client.openSession()
    let options = bus.calls(named: "ScreenCast.SelectSources")[0].parameters[1].vardictValue ?? [:]
    expect(options["cursor_mode"] == nil, "no cursor mode is asked for when metadata is not offered")
}

func testAResponseOnAnOlderPortalsHandleIsStillHeard() async throws {
    let bus = cooperativePortal()
    let moved = "/org/freedesktop/portal/desktop/request/1_42/legacy"
    bus.overrideHandle("RemoteDesktop.SelectDevices", with: moved)
    let rig = try makeRig("legacy-handle", bus: bus)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    _ = try await rig.client.openSession()
    expect(
        bus.log.contains("subscribe Response \(moved)"),
        "the client subscribed again on the handle the portal returned"
    )
}

func testAnOldTokenIsForgottenWhenThePortalReturnsNone() async throws {
    let bus = cooperativePortal(restoreToken: nil)
    let rig = try makeRig("no-token", bus: bus)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    let session = try await rig.client.openSession()
    expect(session.grant.restoreToken == nil, "no token came back")
    expect(rig.store.load() == nil, "the consumed token is not kept")
}

func testMalformedResultsAreReportedNotGuessedAt() async throws {
    let noHandle = cooperativePortal()
    noHandle.react("RemoteDesktop.CreateSession", .respond(code: 0, results: [:]))
    let first = try makeRig("no-handle", bus: noHandle)
    defer { try? FileManager.default.removeItem(at: first.root) }
    do {
        _ = try await first.client.openSession()
        expect(false, "a CreateSession with no session_handle is an error")
    } catch let error as PortalError {
        guard case .malformedResponse = error else {
            expect(false, "the error is malformedResponse, got \(error)")
            return
        }
    }

    let noStreams = cooperativePortal(streams: [])
    let second = try makeRig("no-streams", bus: noStreams)
    defer { try? FileManager.default.removeItem(at: second.root) }
    do {
        _ = try await second.client.openSession()
        expect(false, "a grant with no screen is an error")
    } catch let error as PortalError {
        guard case .malformedResponse = error else {
            expect(false, "the error is malformedResponse, got \(error)")
            return
        }
    }
    expect(noStreams.calls(named: "Session.Close").count == 1, "a grant with no screen closes its session")
}

func testStreamPropertiesAreOptionalAndTheSerialIsRead() async throws {
    let bare = PortalValue.tuple([.uint32(12), .vardict(["pipewire-serial": .uint64(9_000_000_001)])])
    let bus = cooperativePortal(streams: [bare])
    let rig = try makeRig("bare-stream", bus: bus)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    let session = try await rig.client.openSession()
    expect(
        session.grant.streams == [PortalStream(nodeID: 12, id: nil, position: nil, size: nil, pipeWireSerial: 9_000_000_001)],
        "a stream with only a serial parses, got \(session.grant.streams)"
    )
}

func testSessionOpensThePipeWireRemoteAndClosesOnce() async throws {
    let bus = cooperativePortal()
    let rig = try makeRig("remote-close", bus: bus)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    let session = try await rig.client.openSession()
    let descriptor = try await session.openPipeWireRemote()
    expect(descriptor == 99, "the descriptor from the reply is returned")
    let open = bus.calls(named: "ScreenCast.OpenPipeWireRemote")[0]
    expect(open.parameters == [.objectPath(sessionPath), .vardict([:])], "OpenPipeWireRemote names the session")
    expect(open.interface == screenCast, "OpenPipeWireRemote is a ScreenCast method")

    await session.close()
    await session.close()
    expect(bus.calls(named: "Session.Close").count == 1, "closing twice closes once")
    do {
        _ = try await session.openPipeWireRemote()
        expect(false, "a closed session cannot open the remote")
    } catch let error as PortalError {
        expect(error == .sessionClosed, "the error is sessionClosed, got \(error)")
    }
}

func testSessionSendsInputAsFireAndForgetNotifyCalls() async throws {
    let bus = cooperativePortal()
    let rig = try makeRig("notify", bus: bus)
    defer { try? FileManager.default.removeItem(at: rig.root) }
    let session = try await rig.client.openSession()

    try session.notifyPointerMotionAbsolute(stream: 57, x: 10.5, y: 20.25)
    try session.notifyPointerMotion(dx: 1, dy: -2)
    try session.notifyPointerButton(evdevButton: 0x110, pressed: true)
    try session.notifyPointerAxis(dx: 0, dy: 3, finish: true)
    try session.notifyPointerAxisDiscrete(axis: .horizontal, steps: -2)
    try session.notifyKeyboardKeycode(evdevKeycode: 30, pressed: false)

    let sent = bus.calls.filter { $0.interface == remoteDesktop && $0.method.hasPrefix("Notify") }
    expect(sent.map(\.method) == [
        "NotifyPointerMotionAbsolute", "NotifyPointerMotion", "NotifyPointerButton",
        "NotifyPointerAxis", "NotifyPointerAxisDiscrete", "NotifyKeyboardKeycode"
    ], "each input goes to its own method, got \(sent.map(\.method))")
    expect(bus.log.filter { $0.hasPrefix("send RemoteDesktop.Notify") }.count == 6, "all six were sent without waiting")
    expect(
        sent[0].parameters == [.objectPath(sessionPath), .vardict([:]), .uint32(57), .double(10.5), .double(20.25)],
        "absolute motion: session, options, stream, x, y"
    )
    expect(sent[1].parameters == [.objectPath(sessionPath), .vardict([:]), .double(1), .double(-2)], "relative motion")
    expect(sent[2].parameters == [.objectPath(sessionPath), .vardict([:]), .int32(0x110), .uint32(1)], "button press")
    expect(
        sent[3].parameters == [.objectPath(sessionPath), .vardict(["finish": .bool(true)]), .double(0), .double(3)],
        "smooth axis with finish"
    )
    expect(sent[4].parameters == [.objectPath(sessionPath), .vardict([:]), .uint32(1), .int32(-2)], "discrete horizontal axis")
    expect(sent[5].parameters == [.objectPath(sessionPath), .vardict([:]), .int32(30), .uint32(0)], "key release")

    await session.close()
    do {
        try session.notifyKeyboardKeycode(evdevKeycode: 30, pressed: true)
        expect(false, "a closed session sends nothing")
    } catch let error as PortalError {
        expect(error == .sessionClosed, "the error is sessionClosed, got \(error)")
    }
}

func portalSessionTests() -> [NamedTest] { [
    ("the session runs the full handshake in order", { try! await testSessionRunsTheFullHandshakeInOrder() }),
    ("the new restore token is on disk before the session is usable", { try! await testNewRestoreTokenIsOnDiskBeforeTheSessionIsUsable() }),
    ("an unstorable token closes the session before any use", { try! await testAnUnstorableTokenClosesTheSessionBeforeAnyUse() }),
    ("a Start that never answers closes the session, then reports grant-needed", { try! await testAStartThatNeverAnswersClosesTheSessionThenReportsGrantNeeded() }),
    ("a dismissed dialog is declined, not a timeout", { try! await testADialogTheHostPersonDismissesIsDeclinedNotATimeout() }),
    ("an old RemoteDesktop version is refused before anything is created", { try! await testAnOldPortalVersionIsRefusedBeforeAnythingIsCreated() }),
    ("cursor metadata is asked for only when offered", { try! await testCursorMetadataIsAskedForOnlyWhenOffered() }),
    ("a response on an older portal's handle is still heard", { try! await testAResponseOnAnOlderPortalsHandleIsStillHeard() }),
    ("a consumed token is forgotten when the portal returns none", { try! await testAnOldTokenIsForgottenWhenThePortalReturnsNone() }),
    ("malformed results are reported, not guessed at", { try! await testMalformedResultsAreReportedNotGuessedAt() }),
    ("stream properties are optional and the serial is read", { try! await testStreamPropertiesAreOptionalAndTheSerialIsRead() }),
    ("the session opens the PipeWire remote and closes once", { try! await testSessionOpensThePipeWireRemoteAndClosesOnce() }),
    ("the session sends input as fire-and-forget Notify calls", { try! await testSessionSendsInputAsFireAndForgetNotifyCalls() })
] }

#endif

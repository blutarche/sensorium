import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// Stop, as the person at the host means it.
///
/// CLAUDE.md requires "a control that stops it immediately". A viewer cannot
/// tell a socket the operator closed on purpose from one the network dropped,
/// so a session torn down without a word is redialled within a second and Stop
/// appears to do nothing. The reason travels on the wire for exactly that
/// reason.
@MainActor
func runHostStopIsFinalTests() async {
    do {
        // Stop names itself to the peer, while the socket is still open
        let adapter = FakeVirtualDisplayAdapter()
        let session = VirtualDisplaySession(adapter: adapter)
        let controller = HostSessionController(sessions: surfaceZeroOnly(session), keyConfinement: .unconfined)
        _ = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        expect(session.isActive, "the canvas is established before Stop is pressed")
        let channel = FakeHostByteChannel(scriptedMessages: [])
        let networkSession = HostNetworkSession(connection: channel, controller: controller)

        networkSession.stop()
        try! await Task.sleep(for: .milliseconds(200))

        expect(
            channel.packetsSentBeforeCancel.contains(.control(.goodbye(reason: GoodbyeReason.stoppedByHost))),
            "Stop tells the peer why before the socket closes, so the viewer knows this was a person and not a dropout"
        )
        expect(channel.cancelCount == 1, "and the transport is closed exactly once after that word is out")
        expect(!session.isActive, "and the session canvas is still released")

        print("PASS: Stop names itself to the peer before closing the socket, and still releases the canvas")
    }

    do {
        // A write that never lands must not strand the session
        // A peer that has stopped reading is exactly when Stop matters most.
        // The goodbye is best effort: the socket closes and the session ends
        // whether or not the bytes ever left.
        let adapter = FakeVirtualDisplayAdapter()
        let session = VirtualDisplaySession(adapter: adapter)
        let controller = HostSessionController(sessions: surfaceZeroOnly(session), keyConfinement: .unconfined)
        _ = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        let channel = FakeHostByteChannel(scriptedMessages: [])
        channel.sendBytesError = HostNetworkSessionError.closed
        let networkSession = HostNetworkSession(connection: channel, controller: controller)

        networkSession.stop()
        try! await Task.sleep(for: .milliseconds(200))

        expect(channel.cancelCount >= 1, "a goodbye that cannot be written still closes the transport")
        expect(!session.isActive, "and still releases the session canvas")

        print("PASS: a goodbye that cannot be written stops the session anyway")
    }

    do {
        // A peer that accepts no bytes delays Stop, never defeats it
        // The farewell is written to a link that has stopped moving, so it is
        // still outstanding when the deadline closes the socket underneath it.
        let adapter = FakeVirtualDisplayAdapter()
        let session = VirtualDisplaySession(adapter: adapter)
        let controller = HostSessionController(sessions: surfaceZeroOnly(session), keyConfinement: .unconfined)
        _ = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        let channel = FakeHostByteChannel(scriptedMessages: [])
        channel.sendDelay = .seconds(10)
        let networkSession = HostNetworkSession(connection: channel, controller: controller)

        let startedAt = ContinuousClock.now
        networkSession.stop()
        expect(channel.cancelCount == 0, "the write is under way, so nothing has closed yet")
        try! await Task.sleep(for: .milliseconds(1_400))

        expect(
            channel.cancelCount >= 1,
            "a farewell the peer never accepts must not hold the connection open past the deadline"
        )
        expect(
            startedAt.duration(to: ContinuousClock.now) < .seconds(3),
            "and the close comes on that deadline, nowhere near the ten seconds the write would take"
        )
        expect(
            channel.packetsSentBeforeCancel.isEmpty,
            "the socket closed with the goodbye still in flight, which is what best effort means"
        )
        expect(!session.isActive, "and the session canvas was released when Stop was pressed, not when the write gave up")

        print("PASS: a peer that accepts no bytes delays Stop by the farewell deadline and no longer")
    }

    do {
        // Turning a device off ends its live host-screen session, as Stop does
        let fixture = await makeLiveHostScreenFixture()
        defer { fixture.cleanUp() }
        expect(fixture.controller.hasLiveHostScreenSession, "the device's host-screen session is live before it is turned off")

        fixture.revocation.turnOff(devicePublicKey: fixture.deviceKey)
        try! await Task.sleep(for: .milliseconds(200))

        expect(
            fixture.channel.packetsSentBeforeCancel.contains(.control(.goodbye(reason: GoodbyeReason.stoppedByHost))),
            "turning the device off tells the viewer stopped-by-host, so it does not redial"
        )
        expect(fixture.channel.cancelCount == 1, "and closes the connection")
        expect(!fixture.controller.hasLiveHostScreenSession, "and the host-screen session is no longer live")
        expect(fixture.controller.hostScreenDisplayID == nil, "and its teardown has completed, not merely begun")

        print("PASS: turning a device off ends its live host-screen session the way Stop does")
    }

    do {
        // A hello already read when a still-paired device is turned off is refused
        let fixture = await makeLiveHostScreenFixture()
        defer { fixture.cleanUp() }
        let hello = fixture.signedHello()

        fixture.revocation.turnOff(devicePublicKey: fixture.deviceKey)
        var stopsAfterTeardown = 0

        expect(refuses { try fixture.controller.handle(hello) }, "a hello already in flight when the device is turned off is refused, though it is still paired")
        expect(
            refuses { try fixture.controller.offerHostScreenList() },
            "and the connection stays unauthenticated"
        )
        try! await Task.sleep(for: .milliseconds(200))
        expect(fixture.controller.hostScreenDisplayID == nil, "the stopped connection's teardown completes")
        fixture.controller.onStopRequested = { stopsAfterTeardown += 1 }
        fixture.connections.stopConnections(for: fixture.deviceKey)
        expect(stopsAfterTeardown == 0, "and nothing of it was admitted to the device connection registry again, got \(stopsAfterTeardown)")

        print("PASS: a hello already read when a still-paired device is turned off is refused")
    }

    do {
        // Turning a different device off leaves this session alone
        let fixture = await makeLiveHostScreenFixture()
        defer { fixture.cleanUp() }
        let otherKey = try! DeviceIdentity.generate().publicKey

        fixture.revocation.turnOff(devicePublicKey: otherKey)
        try! await Task.sleep(for: .milliseconds(200))

        expect(fixture.channel.cancelCount == 0, "turning another device off closes nothing")
        expect(fixture.channel.packetsSentBeforeCancel.isEmpty, "and sends this viewer nothing")
        expect(fixture.controller.hasLiveHostScreenSession, "and this device's session stays live")

        fixture.networkSession.stop()
        try! await Task.sleep(for: .milliseconds(200))

        print("PASS: turning a different device off leaves a live host-screen session alone")
    }

    do {
        // Removing a paired device ends its live host-screen session, as Stop does
        let fixture = await makeLiveHostScreenFixture()
        defer { fixture.cleanUp() }

        fixture.revocation.removePairedDevice(devicePublicKey: fixture.deviceKey)
        try! await Task.sleep(for: .milliseconds(200))

        expect(
            fixture.channel.packetsSentBeforeCancel.contains(.control(.goodbye(reason: GoodbyeReason.stoppedByHost))),
            "removing the device tells the viewer stopped-by-host"
        )
        expect(!fixture.controller.hasLiveHostScreenSession, "and its host-screen session is no longer live")
        expect(fixture.controller.hostScreenDisplayID == nil, "and its teardown has completed, not merely begun")
        expect(fixture.approvedStore.load().isEmpty, "and the device is no longer paired")

        print("PASS: removing a paired device ends its live host-screen session the way Stop does")
    }

    do {
        // Removing a paired device ends its session canvas connection too
        let device = try! DeviceIdentity.generate()
        let world = RevocationWorld(paired: [device])
        defer { world.cleanUp() }
        let connection = world.connectCanvas(device)
        expect(connection.canvas.isActive, "the device's session canvas is live before it is removed")

        world.revocation.removePairedDevice(devicePublicKey: device.publicKey)
        try! await Task.sleep(for: .milliseconds(200))

        expect(
            connection.channel.packetsSentBeforeCancel.contains(.control(.goodbye(reason: GoodbyeReason.stoppedByHost))),
            "removing the device tells its canvas viewer stopped-by-host, so it does not redial"
        )
        expect(connection.channel.cancelCount == 1, "and closes that connection")
        expect(!connection.canvas.isActive, "and releases its session canvas")

        print("PASS: removing a paired device ends its live session canvas connection the way Stop does")
    }

    do {
        // A removed device is refused at its next hello, with no host restart
        let device = try! DeviceIdentity.generate()
        let world = RevocationWorld(paired: [device])
        defer { world.cleanUp() }
        _ = world.connectCanvas(device)

        world.revocation.removePairedDevice(devicePublicKey: device.publicKey)
        try! await Task.sleep(for: .milliseconds(200))

        let redial = world.makeController()
        do {
            _ = try redial.handle(world.hello(from: device))
            expect(false, "a removed device's authenticated hello must be refused by the running host")
        } catch HostSessionControllerError.deviceNotPaired {
        } catch {
            expect(false, "a removed device is refused as not paired, got \(error)")
        }
        expect(!world.pairing.isApproved(device.publicKey), "the running pairing service no longer admits the key")
        expect(!world.approvedStore.load().contains(device.publicKey), "and the stored list the host window reads agrees")

        print("PASS: a removed device's next authenticated hello is refused without a host restart")
    }

    do {
        // Removing one device leaves another device's connections alone
        let deviceA = try! DeviceIdentity.generate()
        let deviceB = try! DeviceIdentity.generate()
        let world = RevocationWorld(paired: [deviceA, deviceB])
        defer { world.cleanUp() }
        let connectionA = world.connectCanvas(deviceA)
        let connectionB = world.connectCanvas(deviceB)

        world.revocation.removePairedDevice(devicePublicKey: deviceA.publicKey)
        try! await Task.sleep(for: .milliseconds(200))

        expect(connectionA.channel.cancelCount == 1, "the removed device's connection is closed")
        expect(connectionB.channel.cancelCount == 0, "the other device's connection is not")
        expect(connectionB.channel.packetsSentBeforeCancel.isEmpty, "and its viewer is sent nothing")
        expect(connectionB.canvas.isActive, "and its session canvas stays live")
        expect(world.pairing.isApproved(deviceB.publicKey), "and it stays paired")

        connectionB.networkSession.stop()
        try! await Task.sleep(for: .milliseconds(200))

        print("PASS: removing one paired device leaves another device's connections alone")
    }

    do {
        // Turning a device off leaves its session canvas connection alone
        let device = try! DeviceIdentity.generate()
        let world = RevocationWorld(paired: [device])
        defer { world.cleanUp() }
        let connection = world.connectCanvas(device)

        world.revocation.turnOff(devicePublicKey: device.publicKey)
        try! await Task.sleep(for: .milliseconds(200))

        expect(connection.channel.cancelCount == 0, "turning screen control off does not close a session canvas connection")
        expect(connection.canvas.isActive, "and its session canvas stays live")

        connection.networkSession.stop()
        try! await Task.sleep(for: .milliseconds(200))

        print("PASS: turning a device off ends only its host-screen session, never its session canvas")
    }

    do {
        // A connection that already ended is no longer stopped by removal
        let device = try! DeviceIdentity.generate()
        let world = RevocationWorld(paired: [device])
        defer { world.cleanUp() }
        let connection = world.connectCanvas(device)
        connection.networkSession.stop()
        try! await Task.sleep(for: .milliseconds(200))
        let sentAtEnd = connection.channel.sentPackets.count

        world.revocation.removePairedDevice(devicePublicKey: device.publicKey)
        try! await Task.sleep(for: .milliseconds(200))

        expect(connection.channel.cancelCount == 1, "an ended connection gave its entry back, so removal does not close it again")
        expect(connection.channel.sentPackets.count == sentAtEnd, "and sends it nothing more")

        print("PASS: a connection's own teardown takes it out of the device connection registry")
    }

    do {
        // Messages already read when a device is removed are refused, before the teardown runs
        let device = try! DeviceIdentity.generate()
        let world = RevocationWorld(paired: [device])
        defer { world.cleanUp() }
        let streaming = world.connectCanvas(device)
        _ = try! streaming.controller.handle(.input(.pointerMoved(x: 10, y: 20), surfaceID: 0))
        expect(streaming.injector.events.count == 1, "input reaches the canvas before the device is removed")
        let idleAdapter = FakeVirtualDisplayAdapter()
        let idle = world.connectAuthenticated(device, adapter: idleAdapter)

        world.revocation.removePairedDevice(devicePublicKey: device.publicKey)

        expect(
            refuses { try streaming.controller.handle(.input(.pointerMoved(x: 30, y: 40), surfaceID: 0)) },
            "input already in flight when the device is removed is refused"
        )
        expect(streaming.injector.events.count == 1, "and none of it is injected")
        expect(
            refuses { try idle.controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil)) },
            "a canvas request already in flight when the device is removed is refused"
        )
        expect(idleAdapter.acquiredConfigurations.isEmpty, "and no canvas is created for it")
        expect(
            refuses { try idle.controller.handle(world.hello(from: device)) },
            "and the stopped connection cannot authenticate again"
        )
        try! await Task.sleep(for: .milliseconds(200))

        print("PASS: messages already read when a device is removed are refused before its teardown runs")
    }

    do {
        // Messages already read when a device is turned off are refused, before the teardown runs
        let fixture = await makeLiveHostScreenFixture()
        defer { fixture.cleanUp() }
        _ = try! fixture.controller.handle(.input(.pointerMoved(x: 100, y: 100), surfaceID: nil))
        let injectedBefore = fixture.injectors.injector.events.count
        expect(injectedBefore == 1, "host-screen input is injected before the device is turned off, got \(injectedBefore)")

        fixture.revocation.turnOff(devicePublicKey: fixture.deviceKey)

        expect(
            refuses { try fixture.controller.handle(.input(.pointerMoved(x: 200, y: 200), surfaceID: nil)) },
            "host-screen input already in flight when the device is turned off is refused"
        )
        expect(fixture.injectors.injector.events.count == injectedBefore, "and none of it is injected")
        expect(!fixture.controller.canObserveHostScreenLockState(), "and the lock screen can no longer be unlocked through it")
        try! await Task.sleep(for: .milliseconds(200))

        print("PASS: messages already read when a device is turned off are refused before its teardown runs")
    }

    do {
        // Removing a device while its ask-first prompt is showing refuses the request
        let device = try! DeviceIdentity.generate()
        let world = RevocationWorld(paired: [device])
        defer { world.cleanUp() }
        world.armingStore.arm(HostScreenDeviceArming(
            devicePublicKey: device.publicKey,
            deviceName: "Kestrel Laptop Pro",
            armedAt: Date(),
            asksWhenSomeoneIsUsingThisMachine: true
        ))
        let display = DisplaySnapshot(
            id: 7, pixelWidth: 5120, pixelHeight: 2880, modeWidth: 2560, modeHeight: 1440,
            modePixelWidth: 5120, modePixelHeight: 2880, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
            online: true, builtin: false, main: false, vendorNumber: 1552, modelNumber: 40
        )
        let gate = RemovingPresenceGate { world.revocation.removePairedDevice(devicePublicKey: device.publicKey) }
        let injectors = FakeInputInjectorFactory()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            requireAuthentication: true,
            inputInjectorFactory: injectors,
            pairing: world.pairing,
            keyConfinement: .hostScreen,
            hostScreenArmingProvider: { world.armingStore.load() },
            hostScreenCurrentDisplaysProvider: { [display] },
            hostScreenLiveSessionRegistry: world.liveSessions,
            deviceConnectionRegistry: world.connections,
            hostScreenLocalActivitySignal: InUseLocalActivitySignal(),
            hostScreenPresenceGate: gate
        )
        _ = try! controller.handle(world.hello(from: device))
        let channel = FakeHostByteChannel(scriptedMessages: [])
        let networkSession = HostNetworkSession(connection: channel, controller: controller)
        controller.onStopRequested = { [weak networkSession] in networkSession?.stop() }
        guard case let .hostScreenList(displays) = try! controller.offerHostScreenList(), let token = displays.first?.opaqueToken else {
            expect(false, "the armed device is offered the display")
            return
        }

        let response = try? controller.handle(.hostScreenRequest(token: token, resumeTicket: nil))
        try! await Task.sleep(for: .milliseconds(200))

        expect(gate.askCount == 1, "the person here was asked")
        if case .hostScreenReady = response {
            expect(false, "a device removed while the prompt showed is never admitted, and no resume ticket is minted for it")
        }
        expect(!controller.hasLiveHostScreenSession, "and no host-screen session is live")
        expect(
            world.liveSessions.admit(devicePublicKey: device.publicKey, isLive: { true }, stop: {}) != nil,
            "and nothing is registered as live for that device"
        )
        expect(injectors.requestedDisplayIDs.isEmpty, "and no input injector is built for the display")
        expect(controller.hostScreenTargetDisplayID(for: token) == nil, "and the offered token no longer names a display")
        expect(
            channel.packetsSentBeforeCancel.filter { $0 == .control(.goodbye(reason: GoodbyeReason.stoppedByHost)) }.count == 1,
            "the connection is told stopped-by-host exactly once"
        )
        expect(channel.cancelCount == 1, "and torn down exactly once")

        print("PASS: removing a device while its ask-first prompt shows refuses the request and ends the connection once")
    }

    do {
        // The running pairing service is the only authority once there is one
        let device = try! DeviceIdentity.generate()
        let pairing = HostPairingService(
            hostIdentity: try! DeviceIdentity.generate(),
            approvedStore: InMemoryApprovedDeviceStore(keys: [device.publicKey])
        )
        pairing.removeApprovedDevice(device.publicKey)
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            approvedPublicKeys: [device.publicKey],
            requireAuthentication: true,
            pairing: pairing,
            keyConfinement: .unconfined
        )
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: device.publicKey, hostCertificateHash: nil
        )
        do {
            _ = try controller.handle(.authenticatedHello(
                protocolVersion: 1, deviceName: "Probe", publicKey: device.publicKey, signature: try! device.sign(transcript)
            ))
            expect(false, "a key the pairing service no longer approves is refused even when a static key set names it")
        } catch HostSessionControllerError.deviceNotPaired {
        } catch {
            expect(false, "refused as not paired, got \(error)")
        }

        print("PASS: with a pairing service, a static key set cannot admit a key the service no longer approves")
    }

    do {
        // A stale release does not evict a newer connection of the same device
        let registry = HostDeviceConnectionRegistry()
        let key = try! DeviceIdentity.generate().publicKey
        var stoppedOld = 0
        var stoppedNew = 0
        let oldClaim = registry.admit(devicePublicKey: key, stop: { stoppedOld += 1 })
        _ = registry.admit(devicePublicKey: key, stop: { stoppedNew += 1 })

        registry.release(oldClaim)
        registry.release(oldClaim)
        registry.stopConnections(for: key)

        expect(stoppedNew == 1, "the newer connection is still registered after the older one's late release, got \(stoppedNew)")
        expect(stoppedOld == 0, "and the released one is not stopped, got \(stoppedOld)")

        print("PASS: a stale release never evicts a newer connection of the same device")
    }
}

@MainActor
private struct WorldConnection {
    let canvas: VirtualDisplaySession
    let channel: FakeHostByteChannel
    let networkSession: HostNetworkSession
    let controller: HostSessionController
    let injector: FakeInputInjector
}

/// Whether handling a message throws. A handled message may itself answer
/// `nil`, so an optional `try?` cannot tell refusal from success.
@MainActor
private func refuses(_ handle: () throws -> SensoriumMessage?) -> Bool {
    do {
        _ = try handle()
        return false
    } catch {
        return true
    }
}

/// A host's pairing service, stores, and registries, wired the way
/// `sensoriumd` wires them, for connections of any number of devices.
@MainActor
private final class RevocationWorld {
    let armingURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-device-removal-test-\(UUID().uuidString).json")
    let approvedStore: InMemoryApprovedDeviceStore
    let armingStore: HostScreenArmingStore
    let pairing: HostPairingService
    let liveSessions = HostScreenLiveSessionRegistry()
    let connections = HostDeviceConnectionRegistry()
    let revocation: HostScreenDeviceRevocation
    private var networkSessions: [HostNetworkSession] = []

    /// The service reads its store once, at launch, as the host does.
    init(paired devices: [DeviceIdentity]) {
        approvedStore = InMemoryApprovedDeviceStore(keys: Set(devices.map(\.publicKey)))
        pairing = HostPairingService(hostIdentity: try! DeviceIdentity.generate(), approvedStore: approvedStore)
        armingStore = HostScreenArmingStore(url: armingURL)
        revocation = HostScreenDeviceRevocation(
            armingStore: armingStore,
            pairedDevices: pairing,
            liveSessions: liveSessions,
            connections: connections
        )
    }

    func makeController(
        session: VirtualDisplaySession = VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter()),
        inputInjectorFactory: FakeInputInjectorFactory? = nil
    ) -> HostSessionController {
        HostSessionController(
            sessions: surfaceZeroOnly(session),
            requireAuthentication: true,
            inputInjectorFactory: inputInjectorFactory,
            pairing: pairing,
            keyConfinement: .unconfined,
            hostScreenLiveSessionRegistry: liveSessions,
            deviceConnectionRegistry: connections
        )
    }

    func hello(from device: DeviceIdentity) -> SensoriumMessage {
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: device.publicKey, hostCertificateHash: nil
        )
        return .authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: device.publicKey, signature: try! device.sign(transcript)
        )
    }

    func connectCanvas(_ device: DeviceIdentity) -> WorldConnection {
        let connection = connectAuthenticated(device, adapter: FakeVirtualDisplayAdapter())
        _ = try! connection.controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        return connection
    }

    func connectAuthenticated(_ device: DeviceIdentity, adapter: FakeVirtualDisplayAdapter) -> WorldConnection {
        let canvas = VirtualDisplaySession(adapter: adapter)
        let injectors = FakeInputInjectorFactory()
        let controller = makeController(session: canvas, inputInjectorFactory: injectors)
        _ = try! controller.handle(hello(from: device))
        let channel = FakeHostByteChannel(scriptedMessages: [])
        let networkSession = HostNetworkSession(connection: channel, controller: controller)
        controller.onStopRequested = { [weak networkSession] in networkSession?.stop() }
        networkSessions.append(networkSession)
        return WorldConnection(
            canvas: canvas, channel: channel, networkSession: networkSession,
            controller: controller, injector: injectors.injector
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: armingURL)
    }
}

@MainActor
private struct LiveHostScreenFixture {
    let deviceKey: Data
    let controller: HostSessionController
    let channel: FakeHostByteChannel
    let networkSession: HostNetworkSession
    let approvedStore: InMemoryApprovedDeviceStore
    let revocation: HostScreenDeviceRevocation
    let injectors: FakeInputInjectorFactory
    let connections: HostDeviceConnectionRegistry
    let identity: DeviceIdentity
    let armingURL: URL

    func signedHello() -> SensoriumMessage {
        let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, hostCertificateHash: nil
        )
        return .authenticatedHello(
            protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
        )
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: armingURL)
    }
}

/// One armed device with a live host-screen session, wired the way
/// `sensoriumd` wires a connection: the controller's stop request ends its
/// own `HostNetworkSession`, and the registry is the one revocation uses.
@MainActor
private func makeLiveHostScreenFixture() async -> LiveHostScreenFixture {
    let identity = try! DeviceIdentity.generate()
    let deviceKey = identity.publicKey
    let display = DisplaySnapshot(
        id: 7, pixelWidth: 5120, pixelHeight: 2880, modeWidth: 2560, modeHeight: 1440,
        modePixelWidth: 5120, modePixelHeight: 2880, bounds: CGRect(x: 0, y: 0, width: 2560, height: 1440),
        online: true, builtin: false, main: false, vendorNumber: 1552, modelNumber: 40
    )
    let armingURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("sensorium-host-screen-revocation-test-\(UUID().uuidString).json")
    let armingStore = HostScreenArmingStore(url: armingURL)
    armingStore.arm(HostScreenDeviceArming(
        devicePublicKey: deviceKey,
        deviceName: "Kestrel Laptop Pro",
        armedAt: Date(timeIntervalSince1970: 1_700_000_000)
    ))
    let approvedStore = InMemoryApprovedDeviceStore(keys: [deviceKey])
    let pairing = HostPairingService(hostIdentity: try! DeviceIdentity.generate(), approvedStore: approvedStore)
    let registry = HostScreenLiveSessionRegistry()
    let connections = HostDeviceConnectionRegistry()
    let injectors = FakeInputInjectorFactory()
    let controller = HostSessionController(
        sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
        requireAuthentication: true,
        inputInjectorFactory: injectors,
        pairing: pairing,
        keyConfinement: .hostScreen,
        hostScreenArmingProvider: { armingStore.load() },
        hostScreenCurrentDisplaysProvider: { [display] },
        hostScreenLiveSessionRegistry: registry,
        deviceConnectionRegistry: connections,
        hostScreenLocalActivitySignal: FakeHostScreenIdleSignal(),
        hostScreenPresenceGate: nil,
        hostScreenModeController: nil
    )
    let transcript = SensoriumFrameCodec.authenticatedHelloTranscript(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, hostCertificateHash: nil
    )
    _ = try! controller.handle(.authenticatedHello(
        protocolVersion: 1, deviceName: "Probe", publicKey: deviceKey, signature: try! identity.sign(transcript)
    ))
    let coordinator = HostSessionCoordinator(
        controller: controller,
        media: CanvasSurfaceSlots { _ in FakeCanvasMedia() },
        videoSink: FakeVideoSink(),
        hostScreenMediaFactory: { _ in FakeScalableCanvasMedia() },
        lockStateReader: FakeScreenLockState(locked: false)
    )
    let channel = FakeHostByteChannel(scriptedMessages: [])
    let networkSession = HostNetworkSession(connection: channel, controller: controller, coordinator: coordinator)
    controller.onStopRequested = { [weak networkSession] in networkSession?.stop() }
    if case let .hostScreenList(displays) = try! controller.offerHostScreenList(), let token = displays.first?.opaqueToken {
        _ = try! await coordinator.handleWritingResponse(
            .hostScreenRequest(token: token, resumeTicket: nil),
            onWrite: { _ in }
        )
    }
    return LiveHostScreenFixture(
        deviceKey: deviceKey,
        controller: controller,
        channel: channel,
        networkSession: networkSession,
        approvedStore: approvedStore,
        revocation: HostScreenDeviceRevocation(
            armingStore: armingStore,
            pairedDevices: pairing,
            liveSessions: registry,
            connections: connections
        ),
        injectors: injectors,
        connections: connections,
        identity: identity,
        armingURL: armingURL
    )
}

private final class FakeHostScreenIdleSignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading {
        .idleFor(HostScreenPresenceRule.recommendedPresenceThreshold + 1)
    }
}

/// A person here is using the machine, so an ask-first device is asked.
private final class InUseLocalActivitySignal: HostLocalActivitySignal, @unchecked Sendable {
    func currentReading() -> HostLocalActivityReading { .idleFor(0) }
}

/// Allows the request, after the person here removed the device while the
/// prompt was showing.
private final class RemovingPresenceGate: HostScreenPresenceGating, @unchecked Sendable {
    private let remove: @MainActor () -> Void
    private(set) var askCount = 0
    init(remove: @escaping @MainActor () -> Void) { self.remove = remove }
    func ask(content: HostScreenBadgeContent) -> HostScreenPresenceOutcome {
        askCount += 1
        MainActor.assumeIsolated { remove() }
        return .proceed
    }
}

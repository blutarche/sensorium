import Foundation
import SensoriumClient
import SensoriumCore

/// Prints a line and flushes, so a run whose output is piped still shows
/// each second as it happens. `stdout` itself is a mutable global on Linux
/// and cannot be handed to `setvbuf` from concurrency-checked code.
private func emit(_ line: String) {
    print(line)
    fflush(nil)
}

#if canImport(COpenSSL)

/// The Linux viewer's check rig. It is test scaffolding, not a product
/// surface: the viewer people use is a double-clickable app, and every
/// capability has to be reachable from it before it counts as delivered.
/// What this exists for is the one thing an app cannot do yet on Linux --
/// prove that this machine's QUIC transport reaches a real host.
enum ViewerProbe {
    static func run() async {
        let arguments = Array(CommandLine.arguments.dropFirst())
        switch arguments.first {
        case "pair":
            guard arguments.count == 3 || arguments.count == 4, let port = UInt16(arguments[2]) else {
                emit("usage: SensoriumViewerProbe pair <host> <port> [code]")
                exit(2)
            }
            guard let code = arguments.count == 4 ? arguments[3] : readCodeFromStandardInput() else {
                emit("No pairing code was given.")
                exit(2)
            }
            await pair(host: arguments[1], port: port, code: code)
        case "hello":
            guard arguments.count == 3 || arguments.count == 4, let port = UInt16(arguments[2]) else {
                emit("usage: SensoriumViewerProbe hello <host> <port> [seconds]")
                exit(2)
            }
            let seconds = arguments.count == 4 ? Int(arguments[3]) ?? 10 : 10
            await hello(host: arguments[1], port: port, seconds: seconds)
        default:
            emit("usage: SensoriumViewerProbe <pair|hello> ...")
            exit(2)
        }
    }

    /// The one-time ceremony. Pairing is what arms a device for host screen,
    /// and this rig checks the session canvas that follows it.
    static func pair(host: String, port: UInt16, code: String) async {
        guard let identity = loadIdentity() else {
            exit(1)
        }
        let connection = OpenSSLQUICConnection(host: host, port: port, tlsCertificateHash: nil)
        do {
            try await connection.start(timeout: SessionTimeouts.remoteDefault.handshake)
            let controller = ClientSessionController(
                transport: connection,
                identity: identity
            )
            let approval = try await controller.pair(deviceName: deviceName(), code: code)
            FileSavedHostStore(url: savedHostURL()).save(SavedHost(
                displayName: host,
                host: host,
                port: port,
                hostPublicKey: approval.hostPublicKey,
                tlsCertificateHash: approval.tlsCertificateHash
            ))
            await connection.close()
            emit("Paired with \(host). Its key is pinned; later sessions need no code.")
        } catch {
            await connection.close()
            fail(error)
        }
    }

    static func hello(host: String, port: UInt16, seconds: Int) async {
        guard let identity = loadIdentity() else {
            exit(1)
        }
        let saved: SavedHost
        switch SavedHostLookup.resolve(host: host, in: FileSavedHostStore(url: savedHostURL()).loadAll()) {
        case let .success(match):
            saved = match
        case .failure:
            // Never a dial with no pin: that is the one-time pairing flow,
            // and running it against a typed address would trust whatever
            // machine answered.
            emit("host not paired: run pair first")
            exit(1)
        }
        let connection = OpenSSLQUICConnection(
            host: host,
            port: port,
            tlsCertificateHash: saved.tlsCertificateHash
        )
        do {
            try await connection.start(timeout: SessionTimeouts.remoteDefault.handshake)
            let controller = ClientSessionController(
                transport: connection,
                identity: identity,
                pinnedHostPublicKey: saved.hostPublicKey
            )
            let outcome = try await controller.connect(deviceName: deviceName(), target: .sessionCanvas)
            switch outcome {
            case let .canvas(displayID, _):
                emit("Session canvas ready, display \(displayID).")
            case let .hostScreen(geometry, _, _):
                emit("Host screen ready, \(geometry.logicalWidth)x\(geometry.logicalHeight).")
            }
            try await count(packetsOn: connection, seconds: seconds)
            // The same ending the macOS viewer sends: input released on every
            // surface, then `goodbye`, then the transport closed. A host that
            // receives it reports a session that ended rather than one that
            // dropped.
            await controller.disconnect()
        } catch {
            await connection.close()
            fail(error)
        }
    }

    /// One line per second: how much of each kind arrived, and how many
    /// bytes. No decoding and no window -- what is being measured is whether
    /// the transport keeps delivering, not whether a picture comes out.
    static func count(packetsOn connection: OpenSSLQUICConnection, seconds: Int) async throws {
        let counters = PacketCounters()
        let reader = Task {
            while !Task.isCancelled {
                let packet = try await connection.receivePacket()
                await counters.record(packet)
            }
        }
        for second in 1...max(seconds, 1) {
            try await Task.sleep(for: .seconds(1))
            let tally = await counters.takeInterval()
            emit("t+\(second)s control \(tally.control) media \(tally.media) clipboard \(tally.clipboard) bytes \(tally.bytes)")
        }
        reader.cancel()
    }

    /// Every failure reads the same way: the case name, which is what the
    /// check rig is for.
    static func fail(_ error: any Error) -> Never {
        emit("\(error)")
        exit(1)
    }

    static func loadIdentity() -> DeviceIdentity? {
        switch ViewerIdentityRecovery.load(using: FileDeviceIdentityStore(url: identityFileURL())) {
        case let .success(identity):
            return identity
        case let .failure(failure):
            emit("This machine's identity could not be read: \(failure)")
            return nil
        }
    }

    /// Read rather than taken as an argument, so a pairing code never lands
    /// in `ps` output or a shell history file.
    static func readCodeFromStandardInput() -> String? {
        emit("Pairing code: ")
        guard let line = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespaces),
              !line.isEmpty else {
            return nil
        }
        return line
    }

    static func deviceName() -> String {
        ProcessInfo.processInfo.hostName
    }

    /// The XDG location, so the viewer's files sit where a Linux desktop
    /// expects a per-user configuration to be.
    static func configurationDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        let base: URL
        if let configured = environment["XDG_CONFIG_HOME"], !configured.isEmpty {
            base = URL(fileURLWithPath: configured, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("sensorium", isDirectory: true)
    }

    static func savedHostURL() -> URL {
        configurationDirectory().appendingPathComponent("saved-host.json")
    }

    static func identityFileURL() -> URL {
        configurationDirectory().appendingPathComponent("device-identity.json")
    }
}

/// Counts what arrived since the last line was printed. An actor because the
/// reader task and the per-second tick are separate.
private actor PacketCounters {
    private var control = 0
    private var media = 0
    private var clipboard = 0
    private var bytes = 0

    func record(_ packet: SensoriumTransportPacket) {
        switch packet {
        case .control, .unrecognized:
            control += 1
        case .video, .videoForSurface:
            media += 1
        case .clipboard:
            // Its own tally rather than lumped into control traffic: this
            // rig has no window and no runner to apply it through, but it is
            // not a control message either.
            clipboard += 1
        }
        bytes += (try? SensoriumTransportPacketCodec.encode(packet).count) ?? 0
    }

    func takeInterval() -> (control: Int, media: Int, clipboard: Int, bytes: Int) {
        let tally = (control: control, media: media, clipboard: clipboard, bytes: bytes)
        control = 0
        media = 0
        clipboard = 0
        bytes = 0
        return tally
    }
}

#else

/// Nothing to dial from here. The Linux viewer's transport is the point of
/// this rig, and the macOS viewer has an app of its own.
enum ViewerProbe {
    static func run() async {
        emit("SensoriumViewerProbe is the Linux viewer probe; it has no macOS build.")
        exit(2)
    }
}

#endif

// `main.swift` runs top-level statements, so there is no `@main` type here.
// The window verbs go first: they need this process before it has awaited.
// `render-chrome` needs no window and no event loop, so it runs and exits
// before either.
RenderChromeVerb.runIfRequested()
ViewVerbs.dispatchIfRequested()
await ViewerProbe.run()

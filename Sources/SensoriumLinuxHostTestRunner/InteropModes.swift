import Foundation
import SensoriumCore

/// Two modes that let the Linux server and the macOS viewer's real
/// Network.framework client be checked against each other across a container
/// boundary:
///
///     SensoriumLinuxHostTestRunner serve <identity-file> <bind-address> <port>
///     SensoriumLinuxHostTestRunner dial <host> <port> <pin-hex>
///     SensoriumLinuxHostTestRunner identity <identity-file>
///
/// `serve` runs on Linux and echoes every packet it reads. `dial` runs on
/// macOS and sends a small packet and a payload over 1 MiB, then checks the
/// echoes. `identity` loads a stored identity file the way the macOS host
/// would and prints its pin, which proves Security accepts a certificate and
/// key that OpenSSL wrote.
///
/// Two more prove the whole Linux host against the macOS viewer:
///
///     SensoriumLinuxHostTestRunner host <data-folder> <bind-address> <port>
///     SensoriumLinuxHostTestRunner view <host> <port> <pairing-code> <frames>
///
/// `host` runs on Linux: the real runtime, with a made-up monitor in place of
/// the portal and stand-ins for the indicator and the screen saver. It prints
/// its pin and a pairing code, then serves until it is stopped. `view` runs
/// on macOS with the viewer's own connection, session controller and
/// VideoToolbox decoder: it pairs with the code, reconnects pinned, asks for
/// the host screen, and decodes until `frames` pictures have arrived. Against
/// a real host offering more than one monitor, it then connects to each other
/// monitor in turn, as the viewer's Screen menu does, and decodes as many.
/// `Scripts/run-linux-host-macos-smoke.py` also switches monitors and checks
/// offscreen Metal output, input delivery, and the indicator's Stop callback.
/// Pass `-` in place of the pairing code to read it from standard input.
enum InteropModes {
    private static let unattendedSmoke = ProcessInfo.processInfo.environment["SENSORIUM_INTEROP_SMOKE"] == "1"

    static func run(_ arguments: [String]) async -> Int32? {
        guard let mode = arguments.first else { return nil }
        switch mode {
        case "host" where arguments.count == 4:
            #if os(Linux)
            return await host(dataFolder: arguments[1], bindAddress: arguments[2], port: UInt16(arguments[3]) ?? 0)
            #else
            print("host runs on Linux only")
            return 2
            #endif
        case "view" where arguments.count == 5:
            #if canImport(Network)
            let code = arguments[3] == "-" ? readLine() : arguments[3]
            guard let code, !code.isEmpty else {
                print("VIEW missing pairing code")
                return 2
            }
            return await view(
                host: arguments[1],
                port: UInt16(arguments[2]) ?? 0,
                code: code,
                frames: Int(arguments[4]) ?? 30
            )
            #else
            print("view runs on macOS only")
            return 2
            #endif
        case "serve" where arguments.count == 4:
            #if os(Linux)
            return await serve(identityPath: arguments[1], bindAddress: arguments[2], port: UInt16(arguments[3]) ?? 0)
            #else
            print("serve runs on Linux only")
            return 2
            #endif
        case "dial" where arguments.count == 4:
            #if canImport(Network)
            return await dial(host: arguments[1], port: UInt16(arguments[2]) ?? 0, pinHex: arguments[3])
            #else
            print("dial runs on macOS only")
            return 2
            #endif
        case "identity" where arguments.count == 2:
            return identity(path: arguments[1])
        default:
            return nil
        }
    }

    private static func identity(path: String) -> Int32 {
        let store = FileHostTLSIdentityStore(url: URL(fileURLWithPath: path), commonName: "Sensorium Host")
        do {
            let identity = try store.loadOrCreate()
            print("IDENTITY loaded, pin \(hex(identity.certificateHash))")
            return 0
        } catch {
            print("IDENTITY failed: \(error)")
            return 1
        }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else { return nil }
        var result = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }
}

#if os(Linux)
import SensoriumLinuxHost

extension InteropModes {
    private static func serve(identityPath: String, bindAddress: String, port: UInt16) async -> Int32 {
        do {
            let store = FileHostTLSIdentityStore(
                url: URL(fileURLWithPath: identityPath),
                commonName: "Sensorium Host"
            )
            let identity = try store.loadOrCreate()
            let server = OpenSSLQUICServer(identity: identity, bindAddress: bindAddress, port: port)
            try server.start()
            print("PIN \(hex(identity.certificateHash))")
            print("LISTENING \(server.boundPort)")
            for await channel in server.channels {
                print("ACCEPTED")
                Task { await echo(channel) }
            }
            return 0
        } catch {
            print("serve failed: \(error)")
            return 1
        }
    }

    @MainActor
    private static func host(dataFolder: String, bindAddress: String, port: UInt16) async -> Int32 {
        let folder = URL(fileURLWithPath: dataFolder, isDirectory: true)
        let stream = PortalStream(
            nodeID: 71,
            id: "monitor-interop",
            position: PortalPoint(x: 0, y: 0),
            size: PortalSize(width: 1280, height: 720)
        )
        let source = SyntheticScreenSource(width: 1280, height: 720)
        let secondStream = PortalStream(
            nodeID: 72,
            id: "monitor-interop-second",
            position: PortalPoint(x: 1280, y: 0),
            size: PortalSize(width: 640, height: 360)
        )
        let pill = StubIndicatorSurface()
        let tray = StubIndicatorSurface()
        let input = RecordingSink()
        let platform = LinuxHostPlatform(
            grantOpener: FakeGrantOpener(
                stream: stream, source: source, sink: input,
                additionalStream: unattendedSmoke ? secondStream : nil
            ),
            makeIndicator: { LinuxHostIndicator(pill: pill, tray: tray) },
            indicatorSupport: { nil },
            lockState: FakeLockState(),
            localActivity: FakeActivity(),
            relocker: FakeRelocker(),
            sessionAge: { nil },
            encoderBackend: .openH264
        )
        let runtime = LinuxHostRuntime(
            dataFolder: folder,
            platform: platform,
            listen: .testOnly(address: bindAddress, port: port),
            log: { print($0) }
        )
        await runtime.start()
        guard runtime.boundPort != nil else {
            print("HOST failed to listen: \(runtime.state.status)")
            return 1
        }
        let tls = FileHostTLSIdentityStore(
            url: folder.appendingPathComponent("host-tls-identity.json"),
            commonName: "Sensorium Host"
        )
        guard let identity = try? tls.loadOrCreate() else {
            print("HOST has no TLS identity")
            return 1
        }
        print("PIN \(hex(identity.certificateHash))")
        runtime.showPairingCode()
        guard case let .showing(code, _, _) = runtime.state.pairing else {
            print("HOST shows no pairing code")
            return 1
        }
        print("PAIRING \(code)")
        // The screen is offered once the made-up monitor's first frame has
        // said its size.
        let offerDeadline = Date().addingTimeInterval(10)
        while !runtime.offersHostScreen, Date() < offerDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        print("LISTENING \(runtime.boundPort ?? 0), host screen offered: \(runtime.offersHostScreen)")
        if unattendedSmoke {
            let pointer = SinkEvent.absolute(stream: secondStream.nodeID, x: 173, y: 109)
            let keyDown = SinkEvent.key(30, true)
            let inputDeadline = ContinuousClock.now + .seconds(20)
            while !input.events.contains(pointer) || !input.events.contains(keyDown) {
                guard ContinuousClock.now < inputDeadline else {
                    print("HOST timed out waiting for pointer and key input")
                    await runtime.stop()
                    return 1
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            print("HOST received pointer and key on the second monitor")
            guard let stop = pill.onStop else {
                print("HOST has no Stop callback")
                await runtime.stop()
                return 1
            }
            let dismissalsBeforeStop = pill.dismissals
            stop()
            let stopDeadline = ContinuousClock.now + .seconds(5)
            while pill.dismissals <= dismissalsBeforeStop || !input.events.contains(.key(30, false)) {
                guard ContinuousClock.now < stopDeadline else {
                    print("HOST Stop did not dismiss the indicator and release input")
                    await runtime.stop()
                    return 1
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            print("HOST Stop dismissed the indicator and released the held key")
        }
        while true {
            try? await Task.sleep(for: .seconds(3_600))
        }
    }

    private static func echo(_ channel: OpenSSLQUICServerChannel) async {
        do {
            while true {
                let header = try await channel.receiveBytes(count: 5)
                let length = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
                let payload = try await channel.receiveBytes(count: length)
                print("ECHO \(5 + length) bytes")
                try await channel.sendBytes(header + payload)
            }
        } catch {
            print("CHANNEL ENDED \(error)")
        }
    }
}
#endif

#if canImport(Network)
import MetalKit
import Network
import SensoriumClient

extension InteropModes {
    private static func dial(host: String, port: UInt16, pinHex: String) async -> Int32 {
        guard let pin = data(hex: pinHex), let nwPort = NWEndpoint.Port(rawValue: port) else {
            print("DIAL bad arguments")
            return 2
        }
        let connection = NetworkControlConnection(
            host: NWEndpoint.Host(host),
            port: nwPort,
            tlsCertificateHash: pin
        )
        do {
            try await connection.start(timeout: 15)
            print("DIAL connected over QUIC, pin matched")
            var failures = 0
            for (tag, size) in [(UInt8(0x40), 24), (UInt8(0x41), 1_500_000)] {
                var payload = Data(count: size)
                for index in payload.indices {
                    payload[index] = UInt8(truncatingIfNeeded: index &* 31 &+ Int(tag))
                }
                let packet = SensoriumTransportPacket.unrecognized(tag: tag, payload: payload)
                // A large write completes only as the far end reads.
                async let echoed = connection.receiveWirePacket()
                try await connection.send(packet)
                let received = try await echoed
                let matches = received == packet
                print("DIAL sent \(size) byte payload, echo \(matches ? "matches" : "DIFFERS")")
                if !matches { failures += 1 }
            }
            await connection.close()
            print(failures == 0 ? "DIAL OK" : "DIAL FAILED")
            return failures == 0 ? 0 : 1
        } catch {
            print("DIAL failed: \(error)")
            return 1
        }
    }

    @MainActor
    private static func view(host: String, port: UInt16, code: String, frames wanted: Int) async -> Int32 {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            print("VIEW bad port")
            return 2
        }
        guard !unattendedSmoke || host == "127.0.0.1" else {
            print("VIEW the unattended smoke requires a loopback host")
            return 2
        }
        let deviceName = "Kestrel Laptop"
        do {
            let identity = try DeviceIdentity.generate()
            // The one-time pairing dial carries no pin; the signed approval
            // is what binds the certificate hash it returns to the host key.
            let pairing = NetworkControlConnection(host: NWEndpoint.Host(host), port: nwPort)
            try await pairing.start(timeout: 15)
            let approval = try await ClientSessionController(transport: pairing, identity: identity)
                .pair(deviceName: deviceName, code: code)
            await pairing.close()
            guard let pin = approval.tlsCertificateHash else {
                print("VIEW the approval named no certificate")
                return 1
            }
            print("VIEW paired, pin \(hex(pin))")

            func openPinnedConnection() async throws -> (NetworkControlConnection, ClientSessionController) {
                let connection = NetworkControlConnection(
                    host: NWEndpoint.Host(host), port: nwPort, tlsCertificateHash: pin
                )
                try await connection.start(timeout: 15)
                let client = ClientSessionController(
                    transport: connection, identity: identity, pinnedHostPublicKey: approval.hostPublicKey
                )
                return (connection, client)
            }
            let (connection, client) = try await openPinnedConnection()
            let outcome = try await client.connect(
                deviceName: deviceName,
                target: .offeredHostScreen(preferredDisplayIdentity: nil)
            )
            guard case let .hostScreen(geometry, _, offer) = outcome else {
                print("VIEW was not given the host screen: \(outcome)")
                await client.disconnect()
                return 1
            }
            print("VIEW host screen \(geometry.logicalWidth)x\(geometry.logicalHeight) points at \(geometry.backingScale), \(offer.count) offered")
            if unattendedSmoke {
                guard !(await client.supportsMacOSShortcuts) else {
                    print("VIEW Linux host did not suppress macOS shortcuts")
                    await client.disconnect()
                    return 1
                }
                print("VIEW Linux host suppresses macOS shortcuts")
            }

            print("VIEW offered \(offer.map { "\($0.displayIdentity)" }.joined(separator: ", "))")
            let decoded = try await decodePictures(from: connection, count: wanted)
            let passed = decoded.count >= wanted
            await client.disconnect()
            if !unattendedSmoke && passed {
                for screen in offer where screen.displayIdentity != offer.first?.displayIdentity {
                    let (next, nextClient) = try await openPinnedConnection()
                    let nextOutcome = try await nextClient.connect(
                        deviceName: deviceName, target: .hostScreen(displayIdentity: screen.displayIdentity)
                    )
                    guard case let .hostScreen(nextGeometry, _, _) = nextOutcome else {
                        print("VIEW did not switch to \(screen.displayIdentity): \(nextOutcome)")
                        await nextClient.disconnect()
                        return 1
                    }
                    print("VIEW switched to \(screen.displayIdentity), \(nextGeometry.logicalWidth)x\(nextGeometry.logicalHeight) points at \(nextGeometry.backingScale)")
                    let nextDecoded = try await decodePictures(from: next, count: wanted)
                    await nextClient.disconnect()
                    guard nextDecoded.count >= wanted else {
                        print("VIEW FAILED")
                        return 1
                    }
                }
            }
            if unattendedSmoke && passed {
                guard let frame = decoded.firstFrame, frame.width == 1280, frame.height == 720,
                      let (left, right) = try renderSamples(frame), right - left > 100 else {
                    print("VIEW Metal output did not match the first monitor")
                    return 1
                }
                guard offer.count == 2 else {
                    print("VIEW expected two monitors, saw \(offer.count)")
                    return 1
                }
                let (secondConnection, secondClient) = try await openPinnedConnection()
                let secondOutcome = try await secondClient.connect(
                    deviceName: deviceName, target: .hostScreen(displayIdentity: offer[1].displayIdentity)
                )
                guard case let .hostScreen(geometry, _, _) = secondOutcome,
                      geometry.logicalWidth == 640, geometry.logicalHeight == 360 else {
                    print("VIEW did not switch to the second monitor: \(secondOutcome)")
                    await secondClient.disconnect()
                    return 1
                }
                let secondDecoded = try await decodePictures(from: secondConnection, count: 1)
                guard let secondFrame = secondDecoded.firstFrame, secondFrame.width == 640, secondFrame.height == 360,
                      let (left, right) = try renderSamples(secondFrame), left - right > 100 else {
                    print("VIEW Metal output did not match the second monitor")
                    await secondClient.disconnect()
                    return 1
                }
                print("VIEW Metal pixels matched both monitors after switching")
                try await secondClient.sendInput(.pointerMoved(x: 173, y: 109))
                try await secondClient.sendInput(.key(keyCode: 0, isDown: true, modifiers: []))
                while true {
                    let packet = try await secondConnection.receivePacket()
                    if case let .control(.goodbye(reason)) = packet {
                        guard reason == GoodbyeReason.stoppedByHost else {
                            print("VIEW unexpected goodbye: \(reason)")
                            await secondClient.disconnect()
                            return 1
                        }
                        print("VIEW Stop acknowledged")
                        break
                    }
                }
                await secondClient.disconnect()
            }
            print(passed ? "VIEW OK" : "VIEW FAILED")
            return passed ? 0 : 1
        } catch {
            print("VIEW failed: \(error)")
            return 1
        }
    }

    private static func decodePictures(from connection: NetworkControlConnection, count wanted: Int) async throws -> DecodedSizes {
        let decoded = DecodedSizes()
        let decoder = VideoToolboxDecoder(outputHandler: { decoded.append($0, keepFirstFrame: unattendedSmoke) })
        var packets = 0
        let deadline = Date().addingTimeInterval(30)
        while decoded.count < wanted, Date() < deadline {
            if case let .video(frame) = try await connection.receivePacket() {
                packets += 1
                try decoder.decode(frame)
            }
        }
        let sizes = decoded.sizes
        print("VIEW \(packets) video packets, \(sizes.count) pictures decoded, sizes \(Set(sizes).sorted())")
        return decoded
    }

    @MainActor
    private static func renderSamples(_ frame: DecodedFrame) throws -> (Int, Int)? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let width = 64
        let height = 36
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false
        )
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: descriptor),
              let command = device.makeCommandQueue()?.makeCommandBuffer(),
              let blit = command.makeBlitCommandEncoder() else { return nil }
        let presenter = try MetalFramePresenter(view: MTKView(frame: .zero, device: device), device: device)
        try presenter.render(frame.pixelBuffer, into: texture)
        blit.synchronize(resource: texture)
        blit.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let y = height / 4
        return (Int(bytes[(y * width + width / 4) * 4]), Int(bytes[(y * width + 3 * width / 4) * 4]))
    }
}

/// Decoded picture sizes, appended from VideoToolbox's own thread.
private final class DecodedSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var all: [String] = []
    private var first: DecodedFrame?
    func append(_ frame: DecodedFrame, keepFirstFrame: Bool) {
        lock.withLock {
            all.append("\(frame.width)x\(frame.height)")
            if keepFirstFrame && first == nil { first = frame }
        }
    }
    var sizes: [String] { lock.withLock { all } }
    var count: Int { lock.withLock { all.count } }
    var firstFrame: DecodedFrame? { lock.withLock { first } }
}
#endif

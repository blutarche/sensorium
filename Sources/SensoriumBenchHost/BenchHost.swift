// SensoriumBenchHost: a stand-in host for an unattended latency benchmark.
//
// It streams synthetic frames through the real encode path -- the host media
// pipeline with its VideoToolbox encoder, admission gates, fidelity control and
// latency recorder -- and over the real QUIC listener to a real viewer on
// another machine. It is test scaffolding, never bundled into either app.
//
// What it never does: capture or enumerate any display, call ScreenCaptureKit
// or any other permission-gated API, create a virtual display, post input
// events, lock or unlock the screen, hold a display awake, open a window or a
// menu-bar item, listen on the host app's port, or read or write anything
// outside --state-dir and --trace. The session canvas it offers is a display
// number only; the picture is drawn from the pointer positions the viewer sends.
//
// The viewer pairs with the code printed as `bench-host pairing-code <code>`
// the first time; the paired device is kept in --state-dir for later runs.
// It exits after the first session that streamed ends, after --max-seconds, or
// on SIGTERM/SIGINT, with the host stage traces appended to --trace.

import CoreMedia
import Foundation
import Network
import ScreenCaptureKit
import SensoriumCore
import SensoriumHost

private struct NeverLockedScreen: ScreenLockStateReading {
    func isScreenLocked() -> Bool { false }
}

private struct NoLockScreenUnlock: LockScreenUnlocking {
    func unlock(password: Data) async -> HostScreenUnlockOutcome { .screenSharingUnavailable }
}

private struct NoRelock: HostScreenRelocking {
    func relock() -> Bool { false }
}

private enum BenchHostFailure: Error, CustomStringConvertible {
    case notTailnetAddress(String)
    case identityUnavailable(String)

    var description: String {
        switch self {
        case let .notTailnetAddress(address):
            return "\(address) is not a tailnet address; refusing to listen"
        case let .identityUnavailable(reason):
            return reason
        }
    }
}

/// One run: builds the host, serves until the first streamed session ends (or
/// the time limit or a termination signal comes first), then tears down.
@MainActor
private final class BenchHostRun {
    private let options: BenchHostOptions
    private let trace: LatencyTraceWriter
    private let listener: HostNetworkListener
    private let pairing: HostPairingService
    private let sessionFactory: HostConnectionSessionFactory
    private let pointer = BenchPointer()
    private let injector: RecordingInputInjector
    private var teardowns: [@MainActor () async -> Void] = []
    private var isFinishing = false

    init(options: BenchHostOptions) throws {
        self.options = options
        guard SourceAddressPolicy.isTailnetSource(options.address) else {
            throw BenchHostFailure.notTailnetAddress(options.address)
        }
        trace = try LatencyTraceWriter(url: URL(fileURLWithPath: options.tracePath), sessionLabel: options.address)

        try FileManager.default.createDirectory(at: options.stateDirectory, withIntermediateDirectories: true)
        let identity: DeviceIdentity
        let tlsIdentity: HostTLSIdentity
        do {
            identity = try FileDeviceIdentityStore(
                url: options.stateDirectory.appendingPathComponent("device-identity.json")
            ).loadOrCreate()
            tlsIdentity = try FileHostTLSIdentityStore(
                url: options.stateDirectory.appendingPathComponent("host-tls-identity.json"),
                commonName: "Sensorium Bench Host"
            ).loadOrCreate()
        } catch {
            throw BenchHostFailure.identityUnavailable("the stand-in's keys could not be read or made in the state folder: \(error)")
        }
        pairing = HostPairingService(
            hostIdentity: identity,
            approvedStore: FileApprovedDeviceStore(url: options.stateDirectory.appendingPathComponent("approved-devices.json")),
            tlsCertificateHash: tlsIdentity.certificateHash
        )

        injector = RecordingInputInjector(pointer: pointer)
        sessionFactory = HostConnectionSessionFactory(
            sessions: CanvasSurfaceSlots { surface in
                VirtualDisplaySession(adapter: BenchVirtualDisplayAdapter(displayID: 4200 + UInt32(surface.index)))
            },
            requireAuthentication: true,
            inputInjectorFactory: RecordingInputInjectorFactory(injector: injector),
            pairing: pairing,
            // Nothing is posted anywhere, so there is no window for a key to
            // be confined to.
            keyConfinement: .unconfined,
            hostCertificateHash: tlsIdentity.certificateHash,
            hostScreenCurrentDisplaysProvider: { [] },
            privateDesktopOffered: { true }
        )

        listener = try HostNetworkListener(
            tailnetAddress: options.address,
            port: options.port,
            tlsIdentity: tlsIdentity,
            transport: .quic,
            allowsLocalNetwork: false
        )
    }

    func start() {
        let code = pairing.issueCode()
        print("bench-host pairing-code \(code)")
        listener.start { state in
            switch state {
            case let .ready(boundPort):
                print("bench-host listening \(self.options.address) \(boundPort)")
            case let .failed(reason):
                print("bench-host listener-failed \(reason)")
                Foundation.exit(1)
            case .cancelled:
                print("bench-host listener-closed")
            case .rebuilding:
                print("bench-host listener-rebuilding")
            case let .refusedSource(address):
                print("bench-host refused-source \(address)")
            }
        } onConnection: { connection in
            let channel = NWByteChannel(connection: connection)
            Task { @MainActor in
                self.serve(channel)
            }
        }
        let limit = options.maxSeconds
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(limit))
            print("bench-host time-limit \(limit)s")
            await self.finish()
        }
    }

    private func serve(_ channel: any HostByteChannel) {
        guard !isFinishing else {
            channel.cancel()
            return
        }
        let controller = sessionFactory.makeController()
        let latencyRecorder = HostMediaLatencyRecorder()
        let focus = CanvasFocusTracker()
        let sendFeedback = VideoSendFeedback()
        let pointer = pointer
        let trace = trace
        let injector = injector
        let session = HostNetworkSession(
            connection: channel,
            controller: controller,
            latencyRecorder: latencyRecorder,
            // The clipboard session would write this machine's pasteboard.
            clipboard: nil,
            sendFeedback: sendFeedback,
            onEvent: { print("bench-host host: \($0)") }
        )
        controller.onStopRequested = { [weak session] in session?.stop() }
        let coordinator = HostSessionCoordinator(
            controller: controller,
            media: CanvasSurfaceSlots { surface in
                ScreenCaptureCanvasMedia(
                    surface: surface,
                    configuration: .remoteDefault,
                    latencyRecorder: latencyRecorder,
                    focus: focus,
                    admissionGate: controller.encodeAdmission,
                    sendFeedback: sendFeedback,
                    log: { print("bench-host host: \($0)") },
                    pipelineFactory: { _, surface, configuration, latencyRecorder, gate, focus, sendFeedback, _, packetizer, streamStopped, packetHandler in
                        try await HostMediaPipeline(
                            surface: surface,
                            configuration: configuration,
                            latencyRecorder: latencyRecorder,
                            sessionAdmissionGate: gate,
                            focus: focus,
                            sendFeedback: sendFeedback,
                            packetizer: packetizer,
                            streamStoppedHandler: streamStopped,
                            frameSourceFactory: { configuration, deliveryHandler, _, frameHandler in
                                try SyntheticDesktopFrameSource(
                                    configuration: configuration,
                                    pointer: pointer,
                                    deliveryHandler: deliveryHandler,
                                    frameHandler: frameHandler
                                )
                            },
                            encodedPacketHandler: packetHandler
                        )
                    },
                    // Resolves no capture target: the filter is never used to capture.
                    contentFilterProvider: { _ in SCContentFilter() }
                )
            },
            videoSink: session,
            workspaces: CanvasSurfaceSlots { _ -> any CanvasWorkspacePresenting in NoCanvasWorkspace() },
            focus: focus,
            latencyRecorder: latencyRecorder,
            onEvent: { print("bench-host host: \($0)") },
            onSessionEnded: {
                if let summary = HostLatencySummary.line(
                    metrics: latencyRecorder.metrics,
                    droppedFrameCount: session.droppedVideoFrameCount,
                    frameCounts: latencyRecorder.frameCounts
                ) {
                    print("bench-host \(summary)")
                }
                try? trace.write(latencyRecorder.metrics)
                Task { @MainActor in
                    print("bench-host input-events \(injector.eventCount)")
                    print("bench-host session-ended")
                    await self.finish()
                }
            },
            onStreamUnrecoverable: { [weak session] reason in
                print("bench-host stream-unrecoverable \(reason)")
                session?.stop()
            },
            hostScreenMediaFactory: nil,
            lockStateReader: NeverLockedScreen(),
            lockScreenUnlocker: NoLockScreenUnlock(),
            hostScreenRelockPoster: NoRelock(),
            sharpScreens: nil
        )
        session.attach(coordinator: coordinator)
        teardowns.append { [weak session] in
            await coordinator.sessionDidEnd(reason: "bench-host-exit")
            session?.stop()
        }
        session.start()
    }

    /// Ends every live connection, closes the listener and the trace, and
    /// exits. Reached once whichever of a session ending, the time limit or a
    /// signal comes first.
    func finish() async {
        guard !isFinishing else { return }
        isFinishing = true
        listener.stop()
        for teardown in teardowns {
            await teardown()
        }
        // Lets the farewell reach the viewer before the process goes.
        try? await Task.sleep(for: .milliseconds(500))
        trace.close()
        print("bench-host exit")
        Foundation.exit(0)
    }
}

@main
@MainActor
struct SensoriumBenchHost {
    private static var run: BenchHostRun?
    private static var signalSources: [any DispatchSourceSignal] = []

    static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.first == "motion-bench" {
            runMotionBench(Array(arguments.dropFirst()))
        }
        if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
            print(BenchHostOptions.usage)
            Foundation.exit(arguments.isEmpty ? 2 : 0)
        }
        let options: BenchHostOptions
        switch BenchHostOptions.parse(arguments) {
        case let .success(parsed):
            options = parsed
        case let .failure(.message(reason)):
            FileHandle.standardError.write(Data("bench-host error: \(reason)\n\n\(BenchHostOptions.usage)\n".utf8))
            Foundation.exit(2)
        }
        let started: BenchHostRun
        do {
            started = try BenchHostRun(options: options)
        } catch {
            FileHandle.standardError.write(Data("bench-host error: \(error)\n".utf8))
            Foundation.exit(1)
        }
        run = started
        // The default disposition ends the process before any handler could
        // await the teardown, so it is turned off and a dispatch source
        // delivers the signal on the main queue instead.
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler {
                MainActor.assumeIsolated {
                    print("bench-host signal \(number)")
                    Task { @MainActor in await run?.finish() }
                }
            }
            source.resume()
            signalSources.append(source)
        }
        started.start()
        dispatchMain()
    }

    private static func runMotionBench(_ arguments: [String]) -> Never {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(MotionBenchOptions.usage)
            Foundation.exit(0)
        }
        let options: MotionBenchOptions
        switch MotionBenchOptions.parse(arguments) {
        case let .success(parsed):
            options = parsed
        case let .failure(.message(reason)):
            FileHandle.standardError.write(Data("bench-host error: \(reason)\n\n\(MotionBenchOptions.usage)\n".utf8))
            Foundation.exit(2)
        }
        Task { @MainActor in
            do {
                try await MotionBench.run(options)
                Foundation.exit(0)
            } catch {
                FileHandle.standardError.write(Data("bench-host error: \(error)\n".utf8))
                Foundation.exit(1)
            }
        }
        dispatchMain()
    }
}

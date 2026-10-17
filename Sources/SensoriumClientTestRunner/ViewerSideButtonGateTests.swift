import Foundation
import SensoriumClient
import SensoriumCore

/// A host that predates the back and forward buttons cannot read either
/// name, so the viewer sends them only to a host whose reply admitting the
/// session listed `HostInputFeature.backForwardButtons`, and learns that
/// afresh on every connection.
@MainActor
func testViewerSideButtonGateTests() async {
    let hostScreenGeometry = SessionSurfaceGeometry(logicalWidth: 3008, logicalHeight: 1692, backingScale: 2.0)
    let displayIdentity = "00000610-0000a038"

    func connectedCanvasSession(inputFeatures: [String]) async -> (ClientSessionController, ScriptedClientTransport) {
        let transport = ScriptedClientTransport(responses: [
            .canvasReady(
                displayID: 7, logicalWidth: 1920, logicalHeight: 1200, hostSignature: nil,
                surfaceID: 0, inputFeatures: inputFeatures
            )
        ])
        let controller = ClientSessionController(transport: transport)
        _ = try! await controller.connect(deviceName: "Laptop")
        return (controller, transport)
    }

    func connectedHostScreenSession(inputFeatures: [String]) async -> (ClientSessionController, ScriptedClientTransport) {
        let entry = HostScreenListEntry(
            opaqueToken: Data([0x09]), label: "Built-in Display",
            logicalWidth: hostScreenGeometry.logicalWidth, logicalHeight: hostScreenGeometry.logicalHeight,
            backingScale: hostScreenGeometry.backingScale, isBuiltin: true,
            displayIdentity: displayIdentity
        )
        let transport = ScriptedClientTransport(responses: [
            .hostScreenList(displays: [entry]),
            .hostScreenReady(geometry: hostScreenGeometry, resumeTicket: Data([0x01]), inputFeatures: inputFeatures)
        ])
        let controller = ClientSessionController(
            transport: transport,
            pinnedHostPublicKey: Data(repeating: 0x7A, count: 32)
        )
        _ = try! await controller.connect(
            deviceName: "Laptop",
            target: .hostScreen(displayIdentity: displayIdentity)
        )
        return (controller, transport)
    }

    func sentButtons(_ transport: ScriptedClientTransport) async -> [String] {
        await transport.sent.compactMap { message in
            guard case let .input(.pointerButton(button, isDown, _, _), _, _) = message else { return nil }
            return "\(button.rawValue) \(isDown ? "down" : "up")"
        }
    }

    func pressAndReleaseEverySideButtonThenMiddle(_ controller: ClientSessionController) async {
        for button in [CanvasPointerButton.back, .forward, .middle] {
            try! await controller.sendInput(.pointerButton(button: button, isDown: true, x: 100, y: 100))
            try! await controller.sendInput(.pointerButton(button: button, isDown: false, x: 100, y: 100))
        }
    }

    do {
        // A host that did not list the feature never sees either button
        let (canvas, canvasTransport) = await connectedCanvasSession(inputFeatures: [])
        await pressAndReleaseEverySideButtonThenMiddle(canvas)
        let canvasButtons = await sentButtons(canvasTransport)
        expect(
            canvasButtons == ["middle down", "middle up"],
            "a canvas host that did not list backForwardButtons gets neither the press nor the release of back or forward, and no middle in their place, got \(canvasButtons)"
        )

        let (hostScreen, hostScreenTransport) = await connectedHostScreenSession(inputFeatures: ["aFeatureFromANewerHost"])
        await pressAndReleaseEverySideButtonThenMiddle(hostScreen)
        let hostScreenButtons = await sentButtons(hostScreenTransport)
        expect(
            hostScreenButtons == ["middle down", "middle up"],
            "a host-screen host that listed only features this viewer does not know gets neither button either, got \(hostScreenButtons)"
        )
        print("PASS: a viewer drops back and forward, press and release, for a host that did not list them")
    }

    do {
        // A host that listed it gets both buttons, press and release
        let (canvas, canvasTransport) = await connectedCanvasSession(inputFeatures: [HostInputFeature.backForwardButtons])
        await pressAndReleaseEverySideButtonThenMiddle(canvas)
        let canvasButtons = await sentButtons(canvasTransport)
        let everyButton = ["back down", "back up", "forward down", "forward up", "middle down", "middle up"]
        expect(
            canvasButtons == everyButton,
            "a canvas host that listed backForwardButtons gets back and forward as themselves, got \(canvasButtons)"
        )

        let (hostScreen, hostScreenTransport) = await connectedHostScreenSession(
            inputFeatures: ["aFeatureFromANewerHost", HostInputFeature.backForwardButtons]
        )
        await pressAndReleaseEverySideButtonThenMiddle(hostScreen)
        let hostScreenButtons = await sentButtons(hostScreenTransport)
        expect(
            hostScreenButtons == everyButton,
            "a host-screen host that listed backForwardButtons among unknown features gets them too, got \(hostScreenButtons)"
        )
        print("PASS: a viewer sends back and forward, press and release, to a host that listed them")
    }

    do {
        // A release whose press never went out stays home
        let (controller, transport) = await connectedCanvasSession(inputFeatures: [HostInputFeature.backForwardButtons])
        try! await controller.sendInput(.pointerButton(button: .back, isDown: false, x: 100, y: 100))
        try! await controller.sendInput(.pointerButton(button: .forward, isDown: true, x: 100, y: 100))
        try! await controller.sendInput(.pointerButton(button: .forward, isDown: false, x: 100, y: 100))
        try! await controller.sendInput(.pointerButton(button: .forward, isDown: false, x: 100, y: 100))
        let buttons = await sentButtons(transport)
        expect(
            buttons == ["forward down", "forward up"],
            "only a release whose press this connection sent goes out, got \(buttons)"
        )
        print("PASS: a viewer never sends the release of a back or forward press it did not send")
    }

    do {
        // The list sits outside the signed transcript, so a signed reply
        // that carries it still verifies against the pinned host key
        let hostIdentity = try! DeviceIdentity.generate()
        let viewerIdentity = try! DeviceIdentity.generate()
        let signature = try! hostIdentity.sign(SensoriumFrameCodec.canvasReadyTranscript(
            displayID: 7,
            logicalWidth: 1920,
            logicalHeight: 1200,
            clientPublicKey: viewerIdentity.publicKey,
            surfaceID: 0
        ))
        let transport = ScriptedClientTransport(responses: [
            .hostScreenRefused(reason: "host-screen-not-allowed"),
            .canvasReady(
                displayID: 7, logicalWidth: 1920, logicalHeight: 1200, hostSignature: signature,
                surfaceID: 0, inputFeatures: [HostInputFeature.backForwardButtons]
            )
        ])
        let controller = ClientSessionController(
            transport: transport,
            identity: viewerIdentity,
            pinnedHostPublicKey: hostIdentity.publicKey
        )
        do {
            _ = try await controller.connect(deviceName: "Laptop")
            try await controller.sendInput(.pointerButton(button: .back, isDown: true, x: 100, y: 100))
        } catch {
            expect(false, "a signed canvasReady carrying input features verifies and admits the session, got \(error)")
        }
        let buttons = await sentButtons(transport)
        expect(buttons == ["back down"], "and the features it carries take effect, got \(buttons)")
        print("PASS: a signed canvasReady carrying input features verifies, since the list is outside the transcript")
    }
}

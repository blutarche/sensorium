import CoreGraphics
import Foundation
import SensoriumCore
import SensoriumHost

/// Every event the injector built, in order.
private final class ScrollLinePosts: @unchecked Sendable {
    private(set) var events: [CGEvent] = []

    func record(_ event: CGEvent) {
        events.append(event)
    }

    var scrolls: [CGEvent] {
        events.filter { $0.type == .scrollWheel }
    }
}

private final class ScrollLineHIDActivity: HostInjectedHIDActivity, @unchecked Sendable {
    func recordPost() {}
    func secondsSinceLastPost() -> TimeInterval? { nil }
    func sampleBeforePost() {}
    func secondsSinceProvenHardwareActivity() -> TimeInterval? { nil }
}

@MainActor
private func makeScrollLineInjector(post: @escaping (CGEvent) -> Void) -> CoreGraphicsInputInjector {
    try! CoreGraphicsInputInjector(
        canvasDisplayID: CGMainDisplayID(),
        sessionKind: .hostScreen,
        lockStateReader: FakeScreenLockState(locked: false),
        hostInjectedHIDActivity: ScrollLineHIDActivity(),
        postEvent: { event, _ in post(event) },
        associateMouseAndCursor: { _ in },
        warpCursor: { _ in }
    )
}

/// A line-based mouse wheel's scroll reaches the host as lines, and the host
/// posts it as the line scroll macOS itself makes for such a wheel, rather
/// than as points.
@MainActor
func runHostScrollLineTests() {
    do {
        // Whole lines in the wheel fields, the exact lines in the fixed-point ones
        let posts = ScrollLinePosts()
        let injector = makeScrollLineInjector(post: posts.record)
        try! injector.inject(.scrolled(
            deltaX: -15, deltaY: 32.5, x: 10, y: 10, phase: nil, momentumPhase: nil,
            lineDeltaX: -1.5, lineDeltaY: 3.25
        ))
        guard let line = posts.scrolls.last else {
            expect(false, "a scroll with lines posts a scroll event")
            return
        }
        expect(
            line.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
            "a scroll with lines is posted in line units, not pixels"
        )
        let wheel = (
            line.getIntegerValueField(.scrollWheelEventDeltaAxis1),
            line.getIntegerValueField(.scrollWheelEventDeltaAxis2)
        )
        expect(wheel == (3, -1), "the wheel fields carry the whole lines, toward zero, got \(wheel)")
        let exact = (
            line.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
            line.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
        )
        expect(exact == (3.25, -1.5), "the fixed-point fields carry the exact lines, got \(exact)")
        print("PASS: a scroll with lines is posted as a line scroll, whole lines in the wheel fields and exact lines in the fixed-point fields")
    }

    do {
        // Phases ride along on a line scroll as on a point scroll
        let posts = ScrollLinePosts()
        let injector = makeScrollLineInjector(post: posts.record)
        try! injector.inject(.scrolled(
            deltaX: 0, deltaY: 10, x: 10, y: 10, phase: .changed, momentumPhase: .continue,
            lineDeltaX: 0, lineDeltaY: 1
        ))
        guard let line = posts.scrolls.last else {
            expect(false, "a phased scroll with lines posts a scroll event")
            return
        }
        expect(
            line.getIntegerValueField(.scrollWheelEventIsContinuous) == 0
                && line.getIntegerValueField(.scrollWheelEventScrollPhase) == Int64(CGScrollPhase.changed.rawValue)
                && line.getIntegerValueField(.scrollWheelEventMomentumPhase)
                == Int64(CoreGraphicsInputTranslation.cgMomentumScrollPhase(.continue).rawValue),
            "a line scroll keeps its phase and momentum phase"
        )
        print("PASS: a line scroll keeps its phase and momentum phase")
    }

    do {
        // Without both lines, the scroll is the point scroll it always was
        let posts = ScrollLinePosts()
        let injector = makeScrollLineInjector(post: posts.record)
        try! injector.inject(.scrolled(deltaX: -2, deltaY: 30.5, x: 10, y: 10, phase: nil, momentumPhase: nil))
        try! injector.inject(.scrolled(
            deltaX: -2, deltaY: 30.5, x: 10, y: 10, phase: nil, momentumPhase: nil,
            lineDeltaX: nil, lineDeltaY: 3
        ))
        let pixels = posts.scrolls.map {
            [
                Double($0.getIntegerValueField(.scrollWheelEventIsContinuous)),
                $0.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                $0.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)
            ]
        }
        expect(
            pixels == [[1, 30.5, -2], [1, 30.5, -2]],
            "a scroll without lines, or with only one, is posted in pixels from its points, got \(pixels)"
        )
        print("PASS: a scroll without both lines is posted in pixels from its points, as before")
    }

    do {
        // Lines are bounded as points are, and refused rather than clamped
        let injector = FakeInputInjector()
        let controller = HostSessionController(
            sessions: surfaceZeroOnly(VirtualDisplaySession(adapter: FakeVirtualDisplayAdapter())),
            inputInjector: injector,
            keyConfinement: .unconfined,
            privateDesktopOffered: { true }
        )
        _ = try! controller.handle(.canvasRequest(logicalWidth: 1920, logicalHeight: 1200, scale: 2, surfaceID: nil))
        func scroll(lineDeltaX: Double?, lineDeltaY: Double?) -> SensoriumInputEvent {
            .scrolled(
                deltaX: -15, deltaY: 30, x: 10, y: 20, phase: nil, momentumPhase: nil,
                lineDeltaX: lineDeltaX, lineDeltaY: lineDeltaY
            )
        }
        for (lineDeltaX, lineDeltaY) in [(1000.5, 0), (0, -1001), (Double.infinity, 0), (0, -Double.infinity), (Double.nan, 0), (0, Double.nan)] {
            expectThrows(
                HostSessionControllerError.invalidInput,
                { _ = try controller.handle(.input(scroll(lineDeltaX: lineDeltaX, lineDeltaY: lineDeltaY), surfaceID: nil)) },
                "a scroll of \(lineDeltaX), \(lineDeltaY) lines is refused"
            )
        }
        expectThrows(
            HostSessionControllerError.invalidInput,
            { _ = try controller.handle(.input(scroll(lineDeltaX: nil, lineDeltaY: 1001), surfaceID: nil)) },
            "a scroll with only one line field is still bounded"
        )
        let accepted = [scroll(lineDeltaX: 1000, lineDeltaY: -1000), scroll(lineDeltaX: -1.5, lineDeltaY: 3)]
        for event in accepted {
            _ = try! controller.handle(.input(event, surfaceID: nil))
        }
        let scrolls = injector.events.filter {
            if case .scrolled = $0 { return true }
            return false
        }
        expect(
            scrolls == accepted,
            "scrolls within 1000 lines reach the injector with their points and lines as sent, got \(scrolls)"
        )
        print("PASS: a scroll of more than 1000 lines, or of lines that are not a finite number, is refused")
    }
}

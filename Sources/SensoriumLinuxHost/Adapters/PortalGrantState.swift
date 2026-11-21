#if os(Linux)

import Foundation

/// The launch-time portal session as every host-screen gate reads it: the
/// capture grant, the input factory and the display inventory. It is the
/// Linux counterpart of the Screen Recording grant, and it holds only while
/// that one portal session is open.
public final class PortalGrantState: @unchecked Sendable {
    /// The open portal session and what it granted.
    public struct Live: Sendable {
        public let grant: PortalGrant
        /// Where input for this grant goes.
        public let sink: any PortalInputSink
        /// Tells this grant from one installed later, so input built under an
        /// ended grant never reaches its successor.
        public let generation: UInt64
        /// The pixel size of the first frame the granted stream delivered,
        /// once one has.
        public fileprivate(set) var frameSize: (width: Int, height: Int)?

        /// The one monitor the person at the host chose.
        public var stream: PortalStream? { grant.streams.first }

        /// The monitor's logical geometry: from the stream's `size`, or from
        /// the first frame for a stream the portal gave no size.
        public var geometry: PortalCaptureGeometry? {
            guard let stream else { return nil }
            if let geometry = PortalCaptureGeometry(stream: stream) {
                return geometry
            }
            guard let frameSize else { return nil }
            return PortalCaptureGeometry(stream: stream, firstFrameWidth: frameSize.width, firstFrameHeight: frameSize.height)
        }

        /// Whether the grant covers what a remote session types and points
        /// with. Without the keyboard nobody could type at the lock screen.
        public var grantsInput: Bool {
            grant.devices.isSuperset(of: [.keyboard, .pointer])
        }
    }

    private let lock = NSLock()
    private var current: Live?
    private var nextGeneration: UInt64 = 1
    private var changeHandler: (@Sendable () -> Void)?

    public init() {}

    /// The open grant, or nil when there is none.
    public var live: Live? {
        lock.withLock { current }
    }

    /// Whether a monitor may be captured right now.
    public var isGranted: Bool {
        live?.stream != nil
    }

    /// Whether `generation` is still the open grant.
    public func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { current?.generation == generation }
    }

    /// Called after every change, on whichever thread made it.
    public func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { changeHandler = handler }
    }

    /// Records a newly opened portal session, replacing any earlier one.
    public func install(grant: PortalGrant, sink: any PortalInputSink) {
        let handler = lock.withLock {
            current = Live(grant: grant, sink: sink, generation: nextGeneration, frameSize: nil)
            nextGeneration += 1
            return changeHandler
        }
        handler?()
    }

    /// Records that the portal session is gone: closed by the host, by the
    /// person at the host, or never opened.
    public func end() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard current != nil else { return nil }
            current = nil
            return changeHandler
        }
        handler?()
    }

    /// Records the pixel size of a frame from the granted stream. Only the
    /// first one is kept; later ones change nothing.
    public func recordFrame(width: Int, height: Int) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard current != nil, current?.frameSize == nil, width > 0, height > 0 else { return nil }
            current?.frameSize = (width, height)
            return changeHandler
        }
        handler?()
    }
}

#endif

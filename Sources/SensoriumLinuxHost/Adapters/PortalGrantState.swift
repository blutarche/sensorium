#if os(Linux)

import Foundation

/// The open portal session as the capture gate, input factory, and display
/// inventory read it. Each monitor's geometry and frame size belong to its node.
public final class PortalGrantState: @unchecked Sendable {
    public struct Monitor: Sendable {
        public let stream: PortalStream
        public fileprivate(set) var frameSize: (width: Int, height: Int)?
        fileprivate var firstFrameSize: (width: Int, height: Int)?
        fileprivate var failed = false

        /// A single monitor can use its first buffer size when the portal
        /// omits logical geometry. A multi-monitor grant requires that
        /// geometry to route input to the correct display on a scaled desktop.
        fileprivate func geometry(allowFrameFallback: Bool) -> PortalCaptureGeometry? {
            if let geometry = PortalCaptureGeometry(stream: stream) {
                return geometry
            }
            guard allowFrameFallback, let firstFrameSize else { return nil }
            return PortalCaptureGeometry(
                stream: stream, firstFrameWidth: firstFrameSize.width, firstFrameHeight: firstFrameSize.height
            )
        }
    }

    public struct Live: Sendable {
        public let grant: PortalGrant
        public let sink: any PortalInputSink
        public let generation: UInt64
        fileprivate var monitors: [Monitor]

        /// A node and display identity must each resolve to exactly one
        /// granted monitor for the lifetime of the grant.
        public var routableMonitors: [(monitor: Monitor, geometry: PortalCaptureGeometry)] {
            let nodeCounts = Dictionary(grouping: monitors, by: \.stream.nodeID)
            let candidates = monitors.compactMap { monitor -> (Monitor, PortalCaptureGeometry)? in
                guard let geometry = monitor.geometry(allowFrameFallback: monitors.count == 1) else { return nil }
                return (monitor, geometry)
            }
            let byIdentity = Dictionary(grouping: candidates, by: { $0.1.displayIdentity })
            return candidates.filter { monitor, geometry in
                !monitor.failed && nodeCounts[monitor.stream.nodeID]?.count == 1
                    && byIdentity[geometry.displayIdentity]?.count == 1
            }
        }

        public var grantsInput: Bool {
            grant.devices.isSuperset(of: [.keyboard, .pointer])
        }
    }

    private let lock = NSLock()
    private var current: Live?
    private var nextGeneration: UInt64 = 1
    private var changeHandler: (@Sendable () -> Void)?

    public init() {}

    public var live: Live? {
        lock.withLock { current }
    }

    public var isGranted: Bool {
        live.map { !$0.grant.streams.isEmpty } ?? false
    }

    public func isCurrent(_ generation: UInt64) -> Bool {
        lock.withLock { current?.generation == generation }
    }

    public func setChangeHandler(_ handler: (@Sendable () -> Void)?) {
        lock.withLock { changeHandler = handler }
    }

    @discardableResult
    public func install(grant: PortalGrant, sink: any PortalInputSink) -> UInt64 {
        let (generation, handler) = lock.withLock {
            let generation = nextGeneration
            current = Live(
                grant: grant, sink: sink, generation: generation,
                monitors: grant.streams.map { Monitor(stream: $0) }
            )
            nextGeneration += 1
            return (generation, changeHandler)
        }
        handler?()
        return generation
    }

    public func end() {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard current != nil else { return nil }
            current = nil
            return changeHandler
        }
        handler?()
    }

    public func recordFrame(nodeID: UInt32, generation: UInt64, width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        updateMonitor(nodeID: nodeID, generation: generation) { monitor in
            guard !monitor.failed else { return false }
            if let size = monitor.frameSize, size.width == width, size.height == height {
                return false
            }
            if monitor.firstFrameSize == nil {
                monitor.firstFrameSize = (width, height)
            }
            monitor.frameSize = (width, height)
            return true
        }
    }

    func failStream(nodeID: UInt32, generation: UInt64) {
        updateMonitor(nodeID: nodeID, generation: generation) { monitor in
            guard !monitor.failed else { return false }
            monitor.failed = true
            return true
        }
    }

    private func updateMonitor(nodeID: UInt32, generation: UInt64, _ update: (inout Monitor) -> Bool) {
        let handler: (@Sendable () -> Void)? = lock.withLock {
            guard var live = current, live.generation == generation,
                  let index = live.monitors.firstIndex(where: { $0.stream.nodeID == nodeID }) else { return nil }
            var monitor = live.monitors[index]
            guard update(&monitor) else { return nil }
            live.monitors[index] = monitor
            current = live
            return changeHandler
        }
        handler?()
    }
}

#endif

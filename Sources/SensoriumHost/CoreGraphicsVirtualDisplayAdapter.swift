import SensoriumVirtualDisplayBridge
import Foundation

public enum CoreGraphicsVirtualDisplayError: Error, Equatable {
    /// The macOS runtime classes the bridge creates a display with are not
    /// present at all. No identity can help; the machine cannot host.
    case runtimeUnavailable
    case creationFailed
    case metricsUnavailable
}

public struct VirtualDisplayMetrics: Equatable, Sendable {
    public let maxPixelsWide: Int
    public let maxPixelsHigh: Int
    public let hiDPIScale: Int
}

/// Creates one display under one named identity.
///
/// Separate from the adapter so the identity walk and the creation of one
/// display are separable.
@MainActor
public protocol VirtualDisplayCreating: AnyObject {
    func create(
        configuration: VirtualCanvasConfiguration,
        identity: CanvasDisplayIdentity
    ) throws -> VirtualDisplayHandle
    func destroy(_ handle: VirtualDisplayHandle)
    func metrics(for handle: VirtualDisplayHandle) throws -> VirtualDisplayMetrics
}

/// The real creator: the Objective-C bridge to the macOS virtual-display
/// runtime classes.
///
/// The bridge owns the runtime object. Swift retains only the opaque handle
/// and display ID, keeping Objective-C messaging out of Swift's concurrency
/// and KVC layers.
@MainActor
public final class BridgeVirtualDisplayCreator: VirtualDisplayCreating {
    private var displays: [UInt32: UnsafeMutableRawPointer] = [:]
    /// What every display this creator makes is called on the host. Fixed when
    /// the creator is made, because a display is named once, when macOS is
    /// asked for it.
    private let displayName: String

    public init(displayName: String = CanvasPurpose.session.displayName) {
        self.displayName = displayName
    }

    public func create(
        configuration: VirtualCanvasConfiguration,
        identity: CanvasDisplayIdentity
    ) throws -> VirtualDisplayHandle {
        var displayID: UInt32 = 0
        let handle = displayName.withCString { name in
            sensorium_create_virtual_display(
                name,
                Int32(configuration.logicalWidth),
                Int32(configuration.logicalHeight),
                Int32(configuration.logicalWidth * configuration.scale),
                Int32(configuration.logicalHeight * configuration.scale),
                identity.vendorID,
                identity.productID,
                identity.serialNumber,
                &displayID
            )
        }
        guard let handle else {
            // Asked only once creation has already failed, and only to tell
            // the two failures apart: a machine without the runtime classes
            // can never host, while a refusal with them present is something
            // a different identity may get past.
            throw sensorium_virtual_display_runtime_available() == 0
                ? CoreGraphicsVirtualDisplayError.runtimeUnavailable
                : CoreGraphicsVirtualDisplayError.creationFailed
        }

        // A handle always carries a usable display ID: a display whose ID reads
        // as 0 is one the bridge released before returning nothing at all.
        displays[displayID] = handle
        return VirtualDisplayHandle(rawValue: displayID)
    }

    public func destroy(_ handle: VirtualDisplayHandle) {
        guard let display = displays.removeValue(forKey: handle.rawValue) else {
            return
        }
        sensorium_destroy_virtual_display(display)
    }

    public func metrics(for handle: VirtualDisplayHandle) throws -> VirtualDisplayMetrics {
        guard let display = displays[handle.rawValue] else {
            throw CoreGraphicsVirtualDisplayError.metricsUnavailable
        }

        var maxPixelsWide: UInt32 = 0
        var maxPixelsHigh: UInt32 = 0
        var hiDPIScale: UInt32 = 0
        guard sensorium_virtual_display_get_metrics(
            display,
            &maxPixelsWide,
            &maxPixelsHigh,
            &hiDPIScale
        ) != 0 else {
            throw CoreGraphicsVirtualDisplayError.metricsUnavailable
        }
        return VirtualDisplayMetrics(
            maxPixelsWide: Int(maxPixelsWide),
            maxPixelsHigh: Int(maxPixelsHigh),
            hiDPIScale: Int(hiDPIScale)
        )
    }
}

/// Main-actor adapter for one canvas, owning that canvas's identity policy.
@MainActor
public final class CoreGraphicsVirtualDisplayAdapter: VirtualDisplayAdapter, @unchecked Sendable {
    private let identities: [CanvasDisplayIdentity]
    private let purpose: CanvasPurpose
    private let creator: any VirtualDisplayCreating
    private let log: (String) -> Void
    /// The identity each display this adapter created is presenting, until it
    /// is released. Kept so a release can name the identity it gives back, and
    /// so a release of a display this adapter never created is recognisable as
    /// exactly that rather than passing unnoticed.
    private var identitiesByDisplay: [VirtualDisplayHandle: CanvasDisplayIdentity] = [:]
    /// Where this adapter's live canvases are recorded so the process can
    /// release them before it ends, however it ends. `nil` for an adapter no
    /// process lifetime depends on -- a test's, most of all.
    private let shutdown: CanvasShutdown?
    /// This process's record of whether it can still get a picture out of
    /// this machine at all.
    private let captureAvailability: HostCaptureAvailability
    /// Whether this adapter has released a canvas of its own. What turns
    /// "every identity refused" from an ordinary refusal -- a canvas an
    /// earlier run left behind, or a machine with no virtual-display runtime
    /// -- into this process having made its own identities unusable, which
    /// nothing but ending the process clears.
    private var hasReleasedACanvas = false

    /// The identity the canvas this adapter last created actually presents,
    /// so a caller can report what happened rather than what it asked for.
    /// The stable identity unless a fallback was needed.
    public private(set) var identityInUse: CanvasDisplayIdentity

    /// One adapter per canvas: the identity every display it creates presents
    /// comes from the surface and the purpose, and no two canvases alive at
    /// once may present the same one. There is no default surface, because an
    /// adapter that quietly claimed surface 0 would collide with the real
    /// surface 0 rather than fail. The purpose does default, to the canvas a
    /// session streams, which is what all but one caller creates.
    public convenience init(
        surface: CanvasSurfaceID,
        purpose: CanvasPurpose = .session,
        shutdown: CanvasShutdown? = nil,
        captureAvailability: HostCaptureAvailability = .shared,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.init(
            surface: surface,
            purpose: purpose,
            creator: BridgeVirtualDisplayCreator(displayName: purpose.displayName),
            shutdown: shutdown,
            captureAvailability: captureAvailability,
            log: log
        )
    }

    public init(
        surface: CanvasSurfaceID,
        purpose: CanvasPurpose = .session,
        creator: any VirtualDisplayCreating,
        shutdown: CanvasShutdown? = nil,
        captureAvailability: HostCaptureAvailability = .shared,
        log: @escaping (String) -> Void = { _ in }
    ) {
        self.captureAvailability = captureAvailability
        identities = CanvasIdentityFallback.identities(for: surface, purpose: purpose)
        identityInUse = identities[0]
        self.purpose = purpose
        self.creator = creator
        self.shutdown = shutdown
        self.log = log
    }

    /// Walks this canvas's identities in order, taking the first macOS
    /// accepts.
    ///
    /// The stable identity is nearly always the one used; a later one is
    /// reached only when macOS refuses the ones before it, which is what a
    /// canvas an earlier host left behind when it ended mid-session causes.
    /// A refusal that no identity can get past -- the virtual-display
    /// runtime missing altogether -- ends the walk immediately rather than
    /// spending four more doomed attempts on it.
    public func acquire(configuration: VirtualCanvasConfiguration) throws -> VirtualDisplayHandle {
        for identity in identities {
            do {
                let handle = try creator.create(configuration: configuration, identity: identity)
                if identity != identities[0] {
                    reportFallback(to: identity)
                }
                identityInUse = identity
                identitiesByDisplay[handle] = identity
                // Strongly captured on purpose: while this canvas is live,
                // the adapter that can release it has to be too.
                shutdown?.record(handle) { self.release($0) }
                return handle
            } catch CoreGraphicsVirtualDisplayError.creationFailed {
                continue
            }
        }
        if hasReleasedACanvas {
            // Every identity refused, including ones this process was using
            // minutes ago and handed back. Nothing it does next gets them
            // returned; only the process ending does.
            captureAvailability.markUnavailable(log: log)
        }
        throw CoreGraphicsVirtualDisplayError.creationFailed
    }

    /// Said for every canvas that needed a fallback, not once per adapter: an
    /// adapter creates its canvas again on every reconnect, and a session
    /// running on an identity other than its own is a fact about that session,
    /// which the log has to be able to answer for whichever session is asked
    /// about. Each line names the canvas it is about and the identities that
    /// canvas asked for.
    private func reportFallback(to identity: CanvasDisplayIdentity) {
        log(
            "\(purpose.logDescription) identity \(identities[0].serialNumber) is already taken, "
                + "most likely by a canvas an earlier host left behind; using identity "
                + "\(identity.serialNumber) instead"
        )
    }

    public func metrics(for handle: VirtualDisplayHandle) throws -> VirtualDisplayMetrics {
        try creator.metrics(for: handle)
    }

    /// Releases the display and says so, whichever of the two things happened.
    ///
    /// A canvas that is not released outlives the process that created it,
    /// since no public API removes another process's virtual display, so
    /// every release is logged and one this adapter cannot account for is
    /// logged louder. The display goes to the creator either way: the
    /// creator is the authority on what it still holds.
    public func release(_ handle: VirtualDisplayHandle) {
        if let identity = identitiesByDisplay.removeValue(forKey: handle) {
            log(
                "\(purpose.logDescription) released display \(handle.rawValue); "
                    + "identity \(identity.serialNumber) is free again"
            )
        } else {
            log(
                "defect: \(purpose.logDescription) was asked to release display \(handle.rawValue), "
                    + "which it never created"
            )
        }
        hasReleasedACanvas = true
        shutdown?.forget(handle)
        creator.destroy(handle)
    }
}

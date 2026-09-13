import Foundation

/// Identifies which connection currently owns the session canvas.
///
/// A reconnecting viewer races its own dropped connection: the host may not have
/// noticed the dead socket yet. Without a token the late teardown releases the
/// canvas the new session is already streaming, and the person at the viewer
/// sees the canvas vanish moments after it came back.
public struct CanvasOwnerToken: Hashable, Sendable {
    private let id: UUID

    public init() {
        id = UUID()
    }
}

@MainActor
public final class VirtualDisplaySession {
    private let adapter: any VirtualDisplayAdapter
    private var handle: VirtualDisplayHandle?
    private var owner: CanvasOwnerToken?
    /// Shared with the workspace that places this canvas so ownership can
    /// never change while that workspace's own placement — including its
    /// readiness wait, which pumps the run loop and can dispatch a second
    /// connection's `.canvasRequest` — is still in flight. See
    /// `CanvasCreationGate`.
    private let creationGate: CanvasCreationGate

    public init(adapter: any VirtualDisplayAdapter, creationGate: CanvasCreationGate = CanvasCreationGate()) {
        self.adapter = adapter
        self.creationGate = creationGate
    }

    public var isActive: Bool {
        handle != nil
    }

    /// There is one host machine and one canvas, so a later owner takes over the live
    /// handle rather than acquiring a second display — but only once no
    /// creation is in flight on the shared gate. A request that arrives while
    /// this canvas's placement is still settling is rejected instead of
    /// silently taking ownership out from under it.
    ///
    /// `configuration` has no default on purpose: a default size would
    /// silently disagree with the size requested, which shows up as a
    /// wrongly cropped picture rather than an error.
    @discardableResult
    public func start(
        owner: CanvasOwnerToken,
        configuration: VirtualCanvasConfiguration
    ) throws -> VirtualDisplayHandle {
        try creationGate.run {
            if let handle {
                self.owner = owner
                return handle
            }

            let acquired = try adapter.acquire(configuration: configuration)
            handle = acquired
            self.owner = owner
            return acquired
        }
    }

    /// Releases only if the caller still owns the canvas.
    public func stop(owner: CanvasOwnerToken) {
        guard self.owner == owner else {
            return
        }
        stop()
    }

    /// Unconditional release, for host shutdown and for the preflight harness,
    /// which owns the whole process.
    ///
    /// The actual `adapter.release` is routed through `creationGate` rather
    /// than called inline: this gate is shared with the workspace that places
    /// this canvas, and releasing concurrently with an in-flight registration
    /// is the hazard `CanvasCreationGate` exists to prevent. Going through it
    /// here defers the release until that registration has finished instead
    /// of either racing it or dropping the release (which would leak the
    /// display and leave `handle`/`owner` inconsistent with reality).
    /// `handle`/`owner` are cleared immediately, though, so this session's
    /// own state reflects the stop right away even while the underlying
    /// release is still pending.
    ///
    /// The deferral is unreachable in the shipped host: `stop` is
    /// `@MainActor`, so a release arriving during a placement is a
    /// main-queue job a pumping placement cannot dispatch; the routing
    /// stays because the gate is shared.
    public func stop() {
        guard let handle else {
            owner = nil
            return
        }

        self.handle = nil
        owner = nil
        creationGate.runAfterCreation { [adapter] in
            adapter.release(handle)
        }
    }
}

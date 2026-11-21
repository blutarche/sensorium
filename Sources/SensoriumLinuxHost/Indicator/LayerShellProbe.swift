#if os(Linux)
import CWayland
import CWaylandGlue
import Foundation

extension LayerShellSupport {
    /// Asks the compositor once which globals it offers and returns what
    /// stops the corner pill from being shown, or nil when nothing does.
    ///
    /// The host runs this at launch: a desktop that cannot show the pill is
    /// offered no host screen at all, rather than offering one every request
    /// for it then fails. It opens a connection of its own and closes it
    /// before returning; nothing is drawn.
    public static func probe(displayName: String? = nil) -> IndicatorError? {
        guard let display = wl_display_connect(displayName) else {
            return .noDisplay("no Wayland compositor is reachable")
        }
        defer { wl_display_disconnect(display) }
        guard let registry = wl_display_get_registry(display) else {
            return .noDisplay("the compositor gave no registry")
        }
        defer { wl_registry_destroy(registry) }
        let collected = ProbedGlobals()
        let context = Unmanaged.passRetained(collected)
        defer { context.release() }
        wl_registry_add_listener(registry, probeListener, context.toOpaque())
        guard wl_display_roundtrip(display) >= 0 else {
            return .noDisplay("the compositor stopped answering")
        }
        do {
            try check(collected.globals)
            return nil
        } catch let problem as IndicatorError {
            return problem
        } catch {
            return .noDisplay("\(error)")
        }
    }
}

private final class ProbedGlobals {
    var globals: [WaylandGlobal] = []
}

nonisolated(unsafe) private let probeListener: UnsafePointer<wl_registry_listener> = {
    let pointer = UnsafeMutablePointer<wl_registry_listener>.allocate(capacity: 1)
    pointer.initialize(to: wl_registry_listener(
        global: { data, _, name, interface, version in
            let collected = Unmanaged<ProbedGlobals>.fromOpaque(data!).takeUnretainedValue()
            collected.globals.append(WaylandGlobal(name: name, interface: String(cString: interface!), version: version))
        },
        global_remove: { _, _, _ in }
    ))
    return UnsafePointer(pointer)
}()
#endif

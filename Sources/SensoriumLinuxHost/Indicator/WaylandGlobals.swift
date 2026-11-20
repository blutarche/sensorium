#if os(Linux)
import Foundation

/// One global a Wayland compositor announced on its registry.
public struct WaylandGlobal: Equatable, Sendable {
    public let name: UInt32
    public let interface: String
    public let version: UInt32

    public init(name: UInt32, interface: String, version: UInt32) {
        self.name = name
        self.interface = interface
        self.version = version
    }
}

/// What the compositor must advertise before a corner pill can be shown.
///
/// Decided from the list of announced globals alone, so the answer to "can
/// this desktop show the pill" is testable without a compositor.
public enum LayerShellSupport {
    /// Throws the first thing missing, in the order a person would fix it:
    /// the layer shell, then the core globals, then a screen.
    public static func check(_ globals: [WaylandGlobal]) throws {
        func has(_ interface: String) -> Bool {
            globals.contains { $0.interface == interface }
        }
        guard has("zwlr_layer_shell_v1") else { throw IndicatorError.layerShellUnavailable }
        guard has("wl_compositor") else { throw IndicatorError.compositorIncomplete("wl_compositor") }
        guard has("wl_shm") else { throw IndicatorError.compositorIncomplete("wl_shm") }
        guard has("wl_output") else { throw IndicatorError.noOutputs }
    }
}
#endif

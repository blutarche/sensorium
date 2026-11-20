#if os(Linux)
import CGLib
import CWayland
import CWaylandGlue
import CWaylandProtocols
import Foundation

/// The corner pill on every output, drawn through `zwlr_layer_shell_v1` on
/// the overlay layer.
///
/// The pill owns a Wayland connection of its own for as long as it is shown, so
/// it cannot be stalled by, or disturb, whatever else the host does with
/// Wayland. Its events are read from the GLib main loop of the thread that
/// calls `present`, which must therefore be running one.
@MainActor
public final class LayerShellPillPresenter: IndicatorPresenting {
    public var onStop: (() -> Void)?
    public var appearance: IndicatorAppearance

    /// The Wayland display to connect to; the environment's when `nil`.
    private let displayName: String?
    private var session: WaylandPillSession?

    public init(displayName: String? = nil, appearance: IndicatorAppearance = .dark) {
        self.displayName = displayName
        self.appearance = appearance
    }

    public func present(deviceName: String) throws {
        dismiss()
        let started = try WaylandPillSession.start(
            displayName: displayName, deviceName: deviceName, appearance: appearance,
            onStop: { [weak self] in
                MainActor.assumeIsolated { self?.onStop?() }
            }
        )
        session = started
    }

    public func dismiss() {
        session?.teardown()
        session = nil
    }
}

/// One output the compositor announced, and the pill shown on it.
private final class OutputRecord {
    let name: UInt32
    let proxy: OpaquePointer
    /// Integer scale the compositor reports for the output.
    var scale: Int32 = 1
    var pill: PillSurface?

    init(name: UInt32, proxy: OpaquePointer) {
        self.name = name
        self.proxy = proxy
    }
}

/// How many times in a row a pill is re-created after the compositor closes
/// it before the compositor is taken to be refusing it.
private let maximumRecreations = 3
/// A pill that lived this long was not being refused; its close is a fresh
/// event, not a continuation of an earlier one.
private let healthyLifetimeSeconds = 10.0

/// A connection and every pill surface on it. Not isolated to an actor,
/// because libwayland's callbacks are plain C functions; every method runs on
/// the thread that created it, which is the thread running the GLib loop.
final class WaylandPillSession: @unchecked Sendable {
    private let deviceName: String
    private let appearance: IndicatorAppearance
    private let onStop: () -> Void
    private let displayName: String?

    private var display: OpaquePointer?
    private var registry: OpaquePointer?
    private var compositor: OpaquePointer?
    private var shm: OpaquePointer?
    private var layerShell: OpaquePointer?
    private var viewporter: OpaquePointer?
    private var fractionalScaleManager: OpaquePointer?
    private var seat: OpaquePointer?
    private var pointer: OpaquePointer?

    private var globals: [WaylandGlobal] = []
    fileprivate private(set) var outputs: [UInt32: OutputRecord] = [:]
    fileprivate var pillsBySurface: [UInt: PillSurface] = [:]

    private var pointerFocus: PillSurface?
    private var pointerX = 0.0
    private var pointerY = 0.0

    private var fdSource: UInt32 = 0
    /// `false` until `start` has confirmed every pill is configured. A pill the
    /// compositor closes before that is a refusal, not something to re-create.
    fileprivate private(set) var isLive = false
    private var hasGivenUp = false
    /// Set by a callback that wants the session ended; acted on by `pump`.
    private var stopWanted = false
    fileprivate let renderedLayout: (layout: IndicatorPillLayout, logicalWidth: Int, logicalHeight: Int)

    private init(displayName: String?, deviceName: String, appearance: IndicatorAppearance, onStop: @escaping () -> Void) {
        self.displayName = displayName
        self.deviceName = deviceName
        self.appearance = appearance
        self.onStop = onStop
        renderedLayout = IndicatorPillRenderer.layout(for: deviceName)
    }

    static func start(
        displayName: String?, deviceName: String, appearance: IndicatorAppearance, onStop: @escaping () -> Void
    ) throws -> WaylandPillSession {
        let session = WaylandPillSession(
            displayName: displayName, deviceName: deviceName, appearance: appearance, onStop: onStop
        )
        do {
            try session.connect()
        } catch {
            session.teardown()
            throw error
        }
        return session
    }

    // MARK: - Connecting

    private func connect() throws {
        guard let display = wl_display_connect(displayName) else {
            throw IndicatorError.noDisplay("no Wayland compositor is reachable")
        }
        self.display = display
        guard let registry = wl_display_get_registry(display) else {
            throw IndicatorError.noDisplay("the compositor gave no registry")
        }
        self.registry = registry
        wl_registry_add_listener(registry, registryListener, Unmanaged.passUnretained(self).toOpaque())
        // The first round trip delivers the globals, the second what the
        // bound outputs and seat said about themselves.
        guard wl_display_roundtrip(display) >= 0, wl_display_roundtrip(display) >= 0 else {
            throw IndicatorError.noDisplay("the compositor stopped answering")
        }
        try LayerShellSupport.check(globals)
        guard compositor != nil, shm != nil, layerShell != nil else { throw IndicatorError.surfaceRefused }

        for output in outputs.values {
            createPill(on: output)
        }
        var rounds = 0
        while !allPresented, rounds < 5 {
            guard wl_display_roundtrip(display) >= 0 else {
                throw IndicatorError.noDisplay("the compositor stopped answering")
            }
            rounds += 1
        }
        // One more round trip, so a protocol error raised by the last commit
        // surfaces here and not after `show` has already said yes.
        guard wl_display_roundtrip(display) >= 0 else {
            throw IndicatorError.surfaceRefused
        }
        guard allPresented, !outputs.isEmpty else { throw IndicatorError.surfaceRefused }

        isLive = true
        fdSource = g_unix_fd_add(
            wl_display_get_fd(display),
            GIOCondition(rawValue: G_IO_IN.rawValue | G_IO_ERR.rawValue | G_IO_HUP.rawValue),
            { _, condition, data in
                let session = Unmanaged<WaylandPillSession>.fromOpaque(data!).takeUnretainedValue()
                return session.pump(condition: condition) ? 1 : 0
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// Whether every output has a pill that is configured and has a buffer
    /// on it. A pill that is merely configured can still be invisible.
    private var allPresented: Bool {
        outputs.values.allSatisfy { $0.pill?.isPresented == true }
    }

    // MARK: - Event loop

    /// Reads and dispatches whatever the compositor sent, then ends the session
    /// if a callback asked for that. Answers `false` when the connection is
    /// gone, which removes the GLib source.
    ///
    /// A callback never calls `onStop` itself: the owner answers it by tearing
    /// this session down, and the connection must not be closed from inside
    /// its own dispatch.
    private func pump(condition: GIOCondition) -> Bool {
        guard let display else { return false }
        var connected = condition.rawValue & (G_IO_ERR.rawValue | G_IO_HUP.rawValue) == 0
        if connected {
            while wl_display_prepare_read(display) != 0 {
                if wl_display_dispatch_pending(display) < 0 {
                    connected = false
                    break
                }
            }
            if connected {
                connected = wl_display_read_events(display) >= 0 && wl_display_dispatch_pending(display) >= 0
            }
        }
        if connected {
            wl_display_flush(display)
        } else {
            // A live session without its indicator is the one state this host
            // never allows, so a lost connection ends the session.
            fdSource = 0
            giveUp("the connection to the compositor was lost")
        }
        if stopWanted {
            stopWanted = false
            onStop()
        }
        return connected && self.display != nil
    }

    fileprivate func giveUp(_ reason: String) {
        guard !hasGivenUp else { return }
        hasGivenUp = true
        print("Sensorium: the live-session indicator can no longer be shown (\(reason)); ending the session")
        stopWanted = true
    }

    // MARK: - Outputs

    fileprivate func addOutput(name: UInt32, version: UInt32, proxy: OpaquePointer) {
        let record = OutputRecord(name: name, proxy: proxy)
        outputs[name] = record
        wl_output_add_listener(proxy, outputListener, Unmanaged.passUnretained(record).toOpaque())
        if isLive {
            createPill(on: record)
            wl_display_flush(display)
        }
    }

    fileprivate func removeOutput(name: UInt32) {
        guard let record = outputs.removeValue(forKey: name) else { return }
        record.pill?.destroy()
        record.pill = nil
        if wl_output_get_version(record.proxy) >= 3 {
            wl_output_release(record.proxy)
        } else {
            wl_proxy_destroy(record.proxy)
        }
    }

    fileprivate func createPill(on output: OutputRecord) {
        guard let compositor, let layerShell else { return }
        let pill = PillSurface(session: self, output: output)
        output.pill = pill
        pill.create(compositor: compositor, layerShell: layerShell, viewporter: viewporter, fractionalManager: fractionalScaleManager)
    }

    /// The compositor closed `pill`. Re-create it while its output exists, up
    /// to a bounded number of times, then give up.
    fileprivate func pillClosed(_ pill: PillSurface) {
        let output = pill.output
        let survived = pill.age
        let failures = survived > healthyLifetimeSeconds ? 1 : pill.failures + 1
        pill.destroy()
        guard isLive else {
            output.pill = pill // left closed: `connect` reads this as a refusal
            return
        }
        guard outputs[output.name] === output else { return }
        guard failures <= maximumRecreations else {
            output.pill = nil
            giveUp("the compositor keeps closing the indicator")
            return
        }
        createPill(on: output)
        output.pill?.failures = failures
        wl_display_flush(display)
    }

    // MARK: - Pointer

    fileprivate func seatCapabilities(_ capabilities: UInt32) {
        guard let seat else { return }
        let hasPointer = capabilities & WL_SEAT_CAPABILITY_POINTER.rawValue != 0
        if hasPointer, pointer == nil {
            pointer = wl_seat_get_pointer(seat)
            wl_pointer_add_listener(pointer, pointerListener, Unmanaged.passUnretained(self).toOpaque())
        } else if !hasPointer, let existing = pointer {
            wl_pointer_release(existing)
            pointer = nil
            pointerFocus = nil
        }
    }

    fileprivate func pointerEntered(surface: OpaquePointer?, x: Double, y: Double) {
        pointerFocus = surface.flatMap { pillsBySurface[UInt(bitPattern: $0)] }
        pointerX = x
        pointerY = y
    }

    fileprivate func pointerLeft() {
        pointerFocus = nil
    }

    fileprivate func pointerMoved(x: Double, y: Double) {
        pointerX = x
        pointerY = y
    }

    /// A press of the primary button on Stop stops at once. Surface-local
    /// coordinates are in logical points whatever the output's scale, so the
    /// layout's rectangles apply unchanged.
    fileprivate func pointerButton(button: UInt32, pressed: Bool) {
        let primaryButton: UInt32 = 0x110
        guard isLive, pressed, button == primaryButton, pointerFocus != nil else { return }
        if renderedLayout.layout.hitsStop(x: pointerX, y: pointerY) {
            stopWanted = true
        }
    }

    // MARK: - Teardown

    func teardown() {
        if fdSource != 0 {
            g_source_remove(fdSource)
            fdSource = 0
        }
        isLive = false
        for output in outputs.values {
            output.pill?.destroy()
            output.pill = nil
        }
        pillsBySurface.removeAll()
        pointerFocus = nil
        if let display {
            wl_display_flush(display)
            wl_display_disconnect(display)
        }
        display = nil
        registry = nil
        outputs.removeAll()
    }

    deinit {
        if display != nil { teardown() }
    }

    // MARK: - Registry

    fileprivate func registryGlobal(name: UInt32, interface: String, version: UInt32) {
        globals.append(WaylandGlobal(name: name, interface: interface, version: version))
        guard let registry else { return }
        func bind(_ highest: UInt32) -> OpaquePointer? {
            sensorium_wayland_bind(registry, name, interface, min(version, highest)).map { OpaquePointer($0) }
        }
        switch interface {
        case "wl_compositor": compositor = bind(4)
        case "wl_shm": shm = bind(1)
        case "zwlr_layer_shell_v1": layerShell = bind(1)
        case "wp_viewporter": viewporter = bind(1)
        case "wp_fractional_scale_manager_v1": fractionalScaleManager = bind(1)
        case "wl_seat":
            seat = bind(5)
            if let seat {
                wl_seat_add_listener(seat, seatListener, Unmanaged.passUnretained(self).toOpaque())
            }
        case "wl_output":
            if let proxy = bind(3) {
                addOutput(name: name, version: version, proxy: proxy)
            }
        default: break
        }
    }

    fileprivate func registryGlobalRemoved(name: UInt32) {
        globals.removeAll { $0.name == name }
        removeOutput(name: name)
    }

    fileprivate var shmFactory: OpaquePointer? { shm }
    fileprivate var shownDeviceName: String { deviceName }
    fileprivate var shownAppearance: IndicatorAppearance { appearance }
    fileprivate var displayProxy: OpaquePointer? { display }
}

// MARK: - One pill

/// The pill on one output: a layer surface, the shm buffer drawn into it, and
/// the scale it is drawn at.
private final class PillSurface {
    unowned let session: WaylandPillSession
    let output: OutputRecord
    var failures = 0

    private(set) var isConfigured = false
    /// A buffer has been attached and committed, so the pill is on screen.
    private(set) var isPresented = false
    private var surface: OpaquePointer?
    private var layerSurface: OpaquePointer?
    private var viewport: OpaquePointer?
    private var fractionalScale: OpaquePointer?
    private var buffer: OpaquePointer?
    /// Device pixels per logical point as the compositor last said, when it
    /// speaks fractional scale; the output's integer scale otherwise.
    private var preferredScale: Double?
    private let createdAt = DispatchTime.now()

    init(session: WaylandPillSession, output: OutputRecord) {
        self.session = session
        self.output = output
    }

    var age: Double {
        Double(DispatchTime.now().uptimeNanoseconds - createdAt.uptimeNanoseconds) / 1_000_000_000
    }

    func create(compositor: OpaquePointer, layerShell: OpaquePointer, viewporter: OpaquePointer?, fractionalManager: OpaquePointer?) {
        let size = session.renderedLayout
        surface = wl_compositor_create_surface(compositor)
        guard let surface else { return }
        session.pillsBySurface[UInt(bitPattern: surface)] = self

        if let viewporter, let fractionalManager {
            viewport = wp_viewporter_get_viewport(viewporter, surface)
            fractionalScale = wp_fractional_scale_manager_v1_get_fractional_scale(fractionalManager, surface)
            wp_fractional_scale_v1_add_listener(fractionalScale, fractionalScaleListener, Unmanaged.passUnretained(self).toOpaque())
        }

        layerSurface = zwlr_layer_shell_v1_get_layer_surface(
            layerShell, surface, output.proxy, ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY.rawValue, "sensorium-host-indicator"
        )
        guard let layerSurface else { return }
        zwlr_layer_surface_v1_add_listener(layerSurface, layerSurfaceListener, Unmanaged.passUnretained(self).toOpaque())
        zwlr_layer_surface_v1_set_size(layerSurface, UInt32(size.logicalWidth), UInt32(size.logicalHeight))
        zwlr_layer_surface_v1_set_anchor(
            layerSurface, ZWLR_LAYER_SURFACE_V1_ANCHOR_TOP.rawValue | ZWLR_LAYER_SURFACE_V1_ANCHOR_RIGHT.rawValue
        )
        let margin = Int32(IndicatorPillMetrics.cornerMargin)
        zwlr_layer_surface_v1_set_margin(layerSurface, margin, margin, 0, 0)
        // -1: sit where it is anchored even where a panel reserves the corner.
        zwlr_layer_surface_v1_set_exclusive_zone(layerSurface, -1)
        // The pill never takes the keyboard from whatever has it.
        zwlr_layer_surface_v1_set_keyboard_interactivity(layerSurface, ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_NONE.rawValue)

        // Pointer input lands on the pill and nowhere else.
        let region = wl_compositor_create_region(compositor)
        wl_region_add(region, 0, 0, Int32(size.logicalWidth), Int32(size.logicalHeight))
        wl_surface_set_input_region(surface, region)
        wl_region_destroy(region)

        // A first commit without a buffer asks the compositor to configure.
        wl_surface_commit(surface)
    }

    func configure(serial: UInt32) {
        guard let layerSurface else { return }
        zwlr_layer_surface_v1_ack_configure(layerSurface, serial)
        isConfigured = true
        redraw()
    }

    func scaleChanged(_ scale: Double) {
        preferredScale = scale
        if isConfigured { redraw() }
    }

    func outputScaleChanged() {
        if isConfigured, fractionalScale == nil { redraw() }
    }

    /// Draws again. A pill that never got its first buffer, in a session that
    /// is already live, cannot be shown at all, which ends the session; a
    /// failed redraw of a pill already on screen leaves the old picture up.
    private func redraw() {
        if !draw(), !isPresented, session.isLive {
            session.giveUp("the indicator could not be drawn")
        }
    }

    /// Whether a buffer was attached and committed.
    private func draw() -> Bool {
        guard let surface, let shm = session.shmFactory else { return false }
        let size = session.renderedLayout
        let scale = fractionalScale != nil ? (preferredScale ?? Double(output.scale)) : Double(output.scale)
        let bitmap = IndicatorPillRenderer.render(
            deviceName: session.shownDeviceName, appearance: session.shownAppearance, scale: scale
        )
        guard let newBuffer = makeBuffer(bitmap, shm: shm) else { return false }

        if let viewport {
            wp_viewport_set_destination(viewport, Int32(size.logicalWidth), Int32(size.logicalHeight))
        } else {
            wl_surface_set_buffer_scale(surface, output.scale)
        }
        wl_surface_attach(surface, newBuffer, 0, 0)
        wl_surface_damage(surface, 0, 0, Int32(size.logicalWidth), Int32(size.logicalHeight))
        wl_surface_commit(surface)
        // The new buffer is attached, so the one it replaced is no longer needed.
        if let previous = buffer { wl_buffer_destroy(previous) }
        buffer = newBuffer
        isPresented = true
        wl_display_flush(session.displayProxy)
        return true
    }

    /// Copies `bitmap` into a fresh shared-memory buffer.
    private func makeBuffer(_ bitmap: IndicatorBitmap, shm: OpaquePointer) -> OpaquePointer? {
        let byteCount = bitmap.stride * bitmap.pixelHeight
        guard let runtimeDirectory = ProcessInfo.processInfo.environment["XDG_RUNTIME_DIR"] else { return nil }
        var template = Array("\(runtimeDirectory)/sensorium-indicator-XXXXXX".utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { return nil }
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
        unlink(template)
        defer { close(descriptor) }
        guard ftruncate(descriptor, off_t(byteCount)) == 0 else { return nil }
        guard let mapping = mmap(nil, byteCount, PROT_READ | PROT_WRITE, MAP_SHARED, descriptor, 0),
              mapping != MAP_FAILED else { return nil }
        defer { munmap(mapping, byteCount) }
        bitmap.pixels.withUnsafeBytes { mapping.copyMemory(from: $0.baseAddress!, byteCount: byteCount) }

        guard let pool = wl_shm_create_pool(shm, descriptor, Int32(byteCount)) else { return nil }
        defer { wl_shm_pool_destroy(pool) }
        return wl_shm_pool_create_buffer(
            pool, 0, Int32(bitmap.pixelWidth), Int32(bitmap.pixelHeight), Int32(bitmap.stride),
            WL_SHM_FORMAT_ARGB8888.rawValue
        )
    }

    func destroy() {
        if let buffer { wl_buffer_destroy(buffer) }
        buffer = nil
        if let fractionalScale { wp_fractional_scale_v1_destroy(fractionalScale) }
        fractionalScale = nil
        if let viewport { wp_viewport_destroy(viewport) }
        viewport = nil
        if let layerSurface { zwlr_layer_surface_v1_destroy(layerSurface) }
        layerSurface = nil
        if let surface {
            session.pillsBySurface[UInt(bitPattern: surface)] = nil
            wl_surface_destroy(surface)
        }
        surface = nil
        isConfigured = false
        isPresented = false
    }
}

// MARK: - Listeners
//
// libwayland keeps the address of a listener for as long as its object lives,
// so each one is allocated once and never freed.

private func session(from data: UnsafeMutableRawPointer?) -> WaylandPillSession {
    Unmanaged<WaylandPillSession>.fromOpaque(data!).takeUnretainedValue()
}

nonisolated(unsafe) private let registryListener: UnsafePointer<wl_registry_listener> = {
    let pointer = UnsafeMutablePointer<wl_registry_listener>.allocate(capacity: 1)
    pointer.initialize(to: wl_registry_listener(
        global: { data, _, name, interface, version in
            session(from: data).registryGlobal(name: name, interface: String(cString: interface!), version: version)
        },
        global_remove: { data, _, name in
            session(from: data).registryGlobalRemoved(name: name)
        }
    ))
    return UnsafePointer(pointer)
}()

nonisolated(unsafe) private let outputListener: UnsafePointer<wl_output_listener> = {
    let pointer = UnsafeMutablePointer<wl_output_listener>.allocate(capacity: 1)
    pointer.initialize(to: wl_output_listener(
        geometry: { _, _, _, _, _, _, _, _, _, _ in },
        mode: { _, _, _, _, _, _ in },
        done: { _, _ in },
        scale: { data, _, factor in
            let record = Unmanaged<OutputRecord>.fromOpaque(data!).takeUnretainedValue()
            record.scale = max(factor, 1)
            record.pill?.outputScaleChanged()
        },
        name: { _, _, _ in },
        description: { _, _, _ in }
    ))
    return UnsafePointer(pointer)
}()

nonisolated(unsafe) private let seatListener: UnsafePointer<wl_seat_listener> = {
    let pointer = UnsafeMutablePointer<wl_seat_listener>.allocate(capacity: 1)
    pointer.initialize(to: wl_seat_listener(
        capabilities: { data, _, capabilities in
            session(from: data).seatCapabilities(capabilities)
        },
        name: { _, _, _ in }
    ))
    return UnsafePointer(pointer)
}()

private func fixed(_ value: Int32) -> Double {
    Double(value) / 256
}

// Fields are assigned on a zeroed listener, not passed to its initializer, so
// events a newer libwayland adds do not stop this from building. The events
// this does not name are never delivered to it.
nonisolated(unsafe) private let pointerListener: UnsafePointer<wl_pointer_listener> = {
    let pointer = UnsafeMutablePointer<wl_pointer_listener>.allocate(capacity: 1)
    var listener = wl_pointer_listener()
    listener.enter = { data, _, _, surface, x, y in
        session(from: data).pointerEntered(surface: surface, x: fixed(x), y: fixed(y))
    }
    listener.leave = { data, _, _, _ in
        session(from: data).pointerLeft()
    }
    listener.motion = { data, _, _, x, y in
        session(from: data).pointerMoved(x: fixed(x), y: fixed(y))
    }
    listener.button = { data, _, _, _, button, state in
        session(from: data).pointerButton(button: button, pressed: state == WL_POINTER_BUTTON_STATE_PRESSED.rawValue)
    }
    listener.axis = { _, _, _, _, _ in }
    listener.frame = { _, _ in }
    listener.axis_source = { _, _, _ in }
    listener.axis_stop = { _, _, _, _ in }
    listener.axis_discrete = { _, _, _, _ in }
    listener.axis_value120 = { _, _, _, _ in }
    listener.axis_relative_direction = { _, _, _, _ in }
    pointer.initialize(to: listener)
    return UnsafePointer(pointer)
}()

nonisolated(unsafe) private let layerSurfaceListener: UnsafePointer<zwlr_layer_surface_v1_listener> = {
    let pointer = UnsafeMutablePointer<zwlr_layer_surface_v1_listener>.allocate(capacity: 1)
    pointer.initialize(to: zwlr_layer_surface_v1_listener(
        configure: { data, _, serial, _, _ in
            Unmanaged<PillSurface>.fromOpaque(data!).takeUnretainedValue().configure(serial: serial)
        },
        closed: { data, _ in
            let pill = Unmanaged<PillSurface>.fromOpaque(data!).takeUnretainedValue()
            pill.session.pillClosed(pill)
        }
    ))
    return UnsafePointer(pointer)
}()

nonisolated(unsafe) private let fractionalScaleListener: UnsafePointer<wp_fractional_scale_v1_listener> = {
    let pointer = UnsafeMutablePointer<wp_fractional_scale_v1_listener>.allocate(capacity: 1)
    pointer.initialize(to: wp_fractional_scale_v1_listener(
        preferred_scale: { data, _, scale120 in
            Unmanaged<PillSurface>.fromOpaque(data!).takeUnretainedValue().scaleChanged(Double(scale120) / 120)
        }
    ))
    return UnsafePointer(pointer)
}()
#endif

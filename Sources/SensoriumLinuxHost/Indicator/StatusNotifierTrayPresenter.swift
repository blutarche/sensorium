#if os(Linux)
import CGio
import CGLib
import Foundation

/// The tray item: a StatusNotifierItem on the session bus, with a
/// `com.canonical.dbusmenu` menu holding Stop. It shows while a session is
/// live and names the device in its title and tooltip.
///
/// A desktop without a tray, or without a StatusNotifierWatcher yet, is not an
/// error: the item registers the moment a watcher appears, and again whenever
/// the watcher is replaced. The corner pill, not this item, is what makes the
/// session visible.
///
/// Callbacks arrive on the GLib main loop of the thread that called `present`.
@MainActor
final class StatusNotifierTrayPresenter: IndicatorPresenting {
    var onStop: (() -> Void)?
    private var export: TrayExport?

    func present(deviceName: String) throws {
        dismiss()
        let created = TrayExport(model: StatusNotifierModel(deviceName: deviceName)) { [weak self] in
            MainActor.assumeIsolated { self?.onStop?() }
        }
        created.start()
        export = created
    }

    func dismiss() {
        export?.stop()
        export = nil
    }
}

private let itemInterfaceXML = """
<node>
  <interface name="org.kde.StatusNotifierItem">
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="WindowId" type="i" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="OverlayIconName" type="s" access="read"/>
    <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionIconName" type="s" access="read"/>
    <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionMovieName" type="s" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="Menu" type="o" access="read"/>
    <method name="ContextMenu"><arg type="i" name="x" direction="in"/><arg type="i" name="y" direction="in"/></method>
    <method name="Activate"><arg type="i" name="x" direction="in"/><arg type="i" name="y" direction="in"/></method>
    <method name="SecondaryActivate"><arg type="i" name="x" direction="in"/><arg type="i" name="y" direction="in"/></method>
    <method name="Scroll"><arg type="i" name="delta" direction="in"/><arg type="s" name="orientation" direction="in"/></method>
    <signal name="NewTitle"/>
    <signal name="NewIcon"/>
    <signal name="NewAttentionIcon"/>
    <signal name="NewOverlayIcon"/>
    <signal name="NewToolTip"/>
    <signal name="NewStatus"><arg type="s" name="status"/></signal>
  </interface>
</node>
"""

private let menuInterfaceXML = """
<node>
  <interface name="com.canonical.dbusmenu">
    <property name="Version" type="u" access="read"/>
    <property name="TextDirection" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconThemePath" type="as" access="read"/>
    <method name="GetLayout">
      <arg type="i" name="parentId" direction="in"/>
      <arg type="i" name="recursionDepth" direction="in"/>
      <arg type="as" name="propertyNames" direction="in"/>
      <arg type="u" name="revision" direction="out"/>
      <arg type="(ia{sv}av)" name="layout" direction="out"/>
    </method>
    <method name="GetGroupProperties">
      <arg type="ai" name="ids" direction="in"/>
      <arg type="as" name="propertyNames" direction="in"/>
      <arg type="a(ia{sv})" name="properties" direction="out"/>
    </method>
    <method name="GetProperty">
      <arg type="i" name="id" direction="in"/>
      <arg type="s" name="name" direction="in"/>
      <arg type="v" name="value" direction="out"/>
    </method>
    <method name="Event">
      <arg type="i" name="id" direction="in"/>
      <arg type="s" name="eventId" direction="in"/>
      <arg type="v" name="data" direction="in"/>
      <arg type="u" name="timestamp" direction="in"/>
    </method>
    <method name="EventGroup">
      <arg type="a(isvu)" name="events" direction="in"/>
      <arg type="ai" name="idErrors" direction="out"/>
    </method>
    <method name="AboutToShow">
      <arg type="i" name="id" direction="in"/>
      <arg type="b" name="needUpdate" direction="out"/>
    </method>
    <method name="AboutToShowGroup">
      <arg type="ai" name="ids" direction="in"/>
      <arg type="ai" name="updatesNeeded" direction="out"/>
      <arg type="ai" name="idErrors" direction="out"/>
    </method>
    <signal name="ItemsPropertiesUpdated">
      <arg type="a(ia{sv})" name="updatedProps"/>
      <arg type="a(ias)" name="removedProps"/>
    </signal>
    <signal name="LayoutUpdated">
      <arg type="u" name="revision"/>
      <arg type="i" name="parent"/>
    </signal>
    <signal name="ItemActivationRequested">
      <arg type="i" name="id"/>
      <arg type="u" name="timestamp"/>
    </signal>
  </interface>
</node>
"""

private let watcherName = "org.kde.StatusNotifierWatcher"

/// The exported item for one session: the bus name, the two objects and the
/// watch on the watcher. Callbacks are plain C functions that reach it through
/// an unretained pointer, so it must outlive them, which `stop` guarantees by
/// ending every registration before the owner lets go of it.
private final class TrayExport: @unchecked Sendable {
    let model: StatusNotifierModel
    private let onStop: () -> Void
    private var ownerID: UInt32 = 0
    private var watchID: UInt32 = 0
    private var registrationIDs: [UInt32] = []
    private var connection: OpaquePointer?
    private var nodes: [UnsafeMutablePointer<GDBusNodeInfo>] = []
    private let busName = "org.kde.StatusNotifierItem-\(getpid())-1"

    init(model: StatusNotifierModel, onStop: @escaping () -> Void) {
        self.model = model
        self.onStop = onStop
    }

    func start() {
        ownerID = g_bus_own_name(
            G_BUS_TYPE_SESSION, busName, GBusNameOwnerFlags(rawValue: 0),
            { connection, _, data in
                Unmanaged<TrayExport>.fromOpaque(data!).takeUnretainedValue().busAcquired(connection)
            },
            { connection, _, data in
                Unmanaged<TrayExport>.fromOpaque(data!).takeUnretainedValue().nameAcquired(connection)
            },
            { _, name, _ in
                // No session bus, or the name was taken: there is no tray item,
                // and the corner pill still stands.
                print("Sensorium: the tray item could not take its bus name \(name.map { String(cString: $0) } ?? "")")
            },
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }

    func stop() {
        if watchID != 0 { g_bus_unwatch_name(watchID) }
        watchID = 0
        if let connection {
            for id in registrationIDs { _ = g_dbus_connection_unregister_object(connection, id) }
        }
        registrationIDs.removeAll()
        if ownerID != 0 { g_bus_unown_name(ownerID) }
        ownerID = 0
        for node in nodes { g_dbus_node_info_unref(node) }
        nodes.removeAll()
        connection = nil
    }

    // MARK: - Bus

    private func busAcquired(_ connection: OpaquePointer?) {
        self.connection = connection
        guard let connection else { return }
        register(connection, xml: itemInterfaceXML, interface: "org.kde.StatusNotifierItem", path: StatusNotifierModel.objectPath)
        register(connection, xml: menuInterfaceXML, interface: "com.canonical.dbusmenu", path: StatusNotifierModel.menuPath)
    }

    private func register(_ connection: OpaquePointer, xml: String, interface: String, path: String) {
        var error: UnsafeMutablePointer<GError>?
        guard let node = g_dbus_node_info_new_for_xml(xml, &error),
              let info = g_dbus_node_info_lookup_interface(node, interface) else {
            if let error { g_error_free(error) }
            return
        }
        nodes.append(node)
        let id = g_dbus_connection_register_object(
            connection, path, info, itemVTable, Unmanaged.passUnretained(self).toOpaque(), nil, &error
        )
        if id == 0 {
            if let error { g_error_free(error) }
        } else {
            registrationIDs.append(id)
        }
    }

    /// With the name owned, watch for a StatusNotifierWatcher and register with
    /// it whenever one appears.
    private func nameAcquired(_ connection: OpaquePointer?) {
        guard let connection, watchID == 0 else { return }
        watchID = g_bus_watch_name_on_connection(
            connection, watcherName, GBusNameWatcherFlags(rawValue: 0),
            { connection, _, _, data in
                Unmanaged<TrayExport>.fromOpaque(data!).takeUnretainedValue().registerWithWatcher(connection)
            },
            nil,
            Unmanaged.passUnretained(self).toOpaque(),
            nil
        )
    }

    private func registerWithWatcher(_ connection: OpaquePointer?) {
        guard let connection else { return }
        let arguments = variant(from: .tuple([.string(busName)]))
        g_dbus_connection_call(
            connection, watcherName, "/StatusNotifierWatcher", watcherName, "RegisterStatusNotifierItem",
            arguments, nil, GDBusCallFlags(rawValue: 0), -1, nil, nil, nil
        )
    }

    // MARK: - Calls

    fileprivate func handleMethod(
        interface: String, method: String, arguments: [DBusValue], invocation: OpaquePointer?
    ) {
        guard let invocation else { return }
        var reply: DBusValue?
        var stops = false
        switch (interface, method) {
        case ("org.kde.StatusNotifierItem", _):
            // The menu is what Activate would open; none of these end a session.
            break
        case ("com.canonical.dbusmenu", "GetLayout"):
            if case .int32(let parent)? = arguments.first, arguments.count > 1, case .int32(let depth) = arguments[1],
               case .tuple(let parts) = model.menuLayout(parentID: parent, recursionDepth: depth) {
                reply = .tuple(parts)
            }
        case ("com.canonical.dbusmenu", "GetGroupProperties"):
            var ids: [Int32] = []
            if case .array(_, let values)? = arguments.first {
                ids = values.compactMap { if case .int32(let id) = $0 { return id } else { return nil } }
            }
            reply = .tuple([model.menuGroupProperties(ids: ids)])
        case ("com.canonical.dbusmenu", "GetProperty"):
            if case .int32(let id)? = arguments.first, arguments.count > 1, case .string(let name) = arguments[1],
               let value = model.menuItemProperty(id: id, name: name) {
                reply = .tuple([.variant(value)])
            }
        case ("com.canonical.dbusmenu", "Event"):
            if case .int32(let id)? = arguments.first, arguments.count > 1, case .string(let kind) = arguments[1] {
                stops = model.menuEvent(id: id, kind: kind)
            }
        case ("com.canonical.dbusmenu", "EventGroup"):
            if case .array(_, let events)? = arguments.first {
                for case .tuple(let event) in events {
                    if case .int32(let id) = event[0], case .string(let kind) = event[1], model.menuEvent(id: id, kind: kind) {
                        stops = true
                    }
                }
            }
            reply = .tuple([.array(elementSignature: "i", [])])
        case ("com.canonical.dbusmenu", "AboutToShow"):
            reply = .tuple([.boolean(false)])
        case ("com.canonical.dbusmenu", "AboutToShowGroup"):
            reply = .tuple([.array(elementSignature: "i", []), .array(elementSignature: "i", [])])
        default:
            break
        }

        let isAnswerable = interface == "org.kde.StatusNotifierItem" || ["Event"].contains(method) || reply != nil
        if isAnswerable {
            g_dbus_method_invocation_return_value(invocation, reply.map(variant(from:)))
        } else {
            g_dbus_method_invocation_return_error_literal(
                invocation, g_dbus_error_quark(), Int32(G_DBUS_ERROR_INVALID_ARGS.rawValue), "Invalid arguments"
            )
        }
        // The reply is sent first, and Stop acts on the next pass of the loop:
        // the owner answers by tearing this export down, which must not happen
        // from inside the call that is being answered.
        if stops { scheduleStop() }
    }

    private func scheduleStop() {
        let box = Unmanaged.passRetained(StopBox(onStop))
        g_idle_add({ data in
            Unmanaged<StopBox>.fromOpaque(data!).takeRetainedValue().run()
            return 0
        }, box.toOpaque())
    }
}

private final class StopBox {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

// MARK: - GVariant conversion

private func variant(from value: DBusValue) -> OpaquePointer {
    switch value {
    case .string(let text): return g_variant_new_string(text)
    case .objectPath(let path): return g_variant_new_object_path(path)
    case .int32(let number): return g_variant_new_int32(number)
    case .uint32(let number): return g_variant_new_uint32(number)
    case .boolean(let flag): return g_variant_new_boolean(flag ? 1 : 0)
    case .byte(let byte): return g_variant_new_byte(byte)
    case .array(let element, let items):
        let type = g_variant_type_new(element)
        defer { g_variant_type_free(type) }
        var children: [OpaquePointer?] = items.map { variant(from: $0) }
        return children.withUnsafeMutableBufferPointer { g_variant_new_array(type, $0.baseAddress, UInt($0.count)) }
    case .tuple(let parts):
        var children: [OpaquePointer?] = parts.map { variant(from: $0) }
        return children.withUnsafeMutableBufferPointer { g_variant_new_tuple($0.baseAddress, UInt($0.count)) }
    case .dictEntry(let key, let entry): return g_variant_new_dict_entry(variant(from: key), variant(from: entry))
    case .variant(let inner): return g_variant_new_variant(variant(from: inner))
    }
}

/// Reads the arguments of a method call. Types the tray never reads become
/// `nil` and are left out.
private func value(from variant: OpaquePointer) -> DBusValue? {
    switch Character(UnicodeScalar(UInt8(g_variant_classify(variant).rawValue))) {
    case "s", "o", "g": return .string(String(cString: g_variant_get_string(variant, nil)))
    case "i": return .int32(g_variant_get_int32(variant))
    case "u": return .uint32(g_variant_get_uint32(variant))
    case "b": return .boolean(g_variant_get_boolean(variant) != 0)
    case "y": return .byte(g_variant_get_byte(variant))
    case "v": return g_variant_get_variant(variant).flatMap { inner in
        defer { g_variant_unref(inner) }
        return value(from: inner).map { .variant($0) }
    }
    case "a", "(", "{":
        let count = g_variant_n_children(variant)
        var items: [DBusValue] = []
        for index in 0..<count {
            guard let child = g_variant_get_child_value(variant, index) else { continue }
            defer { g_variant_unref(child) }
            if let decoded = value(from: child) { items.append(decoded) }
        }
        let type = String(cString: g_variant_get_type_string(variant))
        if type.hasPrefix("a") { return .array(elementSignature: String(type.dropFirst()), items) }
        if type.hasPrefix("(") { return .tuple(items) }
        return items.count == 2 ? .dictEntry(items[0], items[1]) : nil
    default: return nil
    }
}

// MARK: - Vtable

nonisolated(unsafe) private let itemVTable: UnsafePointer<GDBusInterfaceVTable> = {
    let pointer = UnsafeMutablePointer<GDBusInterfaceVTable>.allocate(capacity: 1)
    var table = GDBusInterfaceVTable()
    table.method_call = { _, _, _, interface, method, parameters, invocation, data in
        let export = Unmanaged<TrayExport>.fromOpaque(data!).takeUnretainedValue()
        var arguments: [DBusValue] = []
        if let parameters, case .tuple(let parts)? = value(from: parameters) {
            arguments = parts
        }
        export.handleMethod(
            interface: String(cString: interface!), method: String(cString: method!),
            arguments: arguments, invocation: invocation
        )
    }
    table.get_property = { _, _, _, interface, property, _, data in
        let export = Unmanaged<TrayExport>.fromOpaque(data!).takeUnretainedValue()
        let name = String(cString: property!)
        let found = String(cString: interface!) == "org.kde.StatusNotifierItem"
            ? export.model.property(name) : export.model.menuProperty(name)
        return found.map(variant(from:))
    }
    pointer.initialize(to: table)
    return UnsafePointer(pointer)
}()
#endif

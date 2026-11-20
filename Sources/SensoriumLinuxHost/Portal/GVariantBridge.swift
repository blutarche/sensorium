#if os(Linux)

import CGio
import Foundation

/// Converts between `PortalValue` and `GVariant`. A `GVariant` here is always
/// an `OpaquePointer`; a value built by `makeVariant` is floating, and one
/// given to `value(from:)` stays the caller's.
public enum GVariantBridge {
    /// A new floating `GVariant` for `value`.
    public static func makeVariant(_ value: PortalValue) -> OpaquePointer {
        switch value {
        case let .string(text):
            return g_variant_new_string(text)
        case let .objectPath(path):
            return g_variant_new_object_path(path)
        case let .bool(flag):
            return g_variant_new_boolean(flag ? 1 : 0)
        case let .int32(number):
            return g_variant_new_int32(number)
        case let .uint32(number):
            return g_variant_new_uint32(number)
        case let .uint64(number):
            return g_variant_new_uint64(guint64(number))
        case let .double(number):
            return g_variant_new_double(number)
        case let .variant(inner):
            return g_variant_new_variant(makeVariant(inner))
        case let .tuple(items):
            return makeTuple(items)
        case let .array(items, elementSignature):
            let type = g_variant_type_new(elementSignature)
            defer { g_variant_type_free(type) }
            let children: [OpaquePointer?] = items.map { makeVariant($0) }
            return children.withUnsafeBufferPointer {
                g_variant_new_array(type, $0.baseAddress, gsize($0.count))
            }
        case let .vardict(entries):
            let type = g_variant_type_new("{sv}")
            defer { g_variant_type_free(type) }
            let children: [OpaquePointer?] = entries.keys.sorted().map { key in
                g_variant_new_dict_entry(
                    g_variant_new_string(key),
                    g_variant_new_variant(makeVariant(entries[key]!))
                )
            }
            return children.withUnsafeBufferPointer {
                g_variant_new_array(type, $0.baseAddress, gsize($0.count))
            }
        case let .unsupported(signature):
            preconditionFailure("a value of unsupported type \(signature) cannot be sent")
        }
    }

    /// A new floating tuple of `items`, the shape of a method's arguments.
    public static func makeTuple(_ items: [PortalValue]) -> OpaquePointer {
        let children: [OpaquePointer?] = items.map { makeVariant($0) }
        return children.withUnsafeBufferPointer {
            g_variant_new_tuple($0.baseAddress, gsize($0.count))
        }
    }

    public static func typeString(of variant: OpaquePointer) -> String {
        String(cString: g_variant_get_type_string(variant))
    }

    /// The `PortalValue` for `variant`. The `v` slots of an `a{sv}` are
    /// unwrapped; a top-level `v` stays a `.variant`.
    public static func value(from variant: OpaquePointer) -> PortalValue {
        let signature = typeString(of: variant)
        switch signature {
        case "s":
            return .string(String(cString: g_variant_get_string(variant, nil)))
        case "o":
            return .objectPath(String(cString: g_variant_get_string(variant, nil)))
        case "b":
            return .bool(g_variant_get_boolean(variant) != 0)
        case "i":
            return .int32(g_variant_get_int32(variant))
        case "u":
            return .uint32(g_variant_get_uint32(variant))
        case "t":
            return .uint64(UInt64(g_variant_get_uint64(variant)))
        case "d":
            return .double(g_variant_get_double(variant))
        case "v":
            let inner = g_variant_get_variant(variant)!
            defer { g_variant_unref(inner) }
            return .variant(value(from: inner))
        case "a{sv}":
            var entries: [String: PortalValue] = [:]
            for index in 0..<g_variant_n_children(variant) {
                let entry = g_variant_get_child_value(variant, index)!
                defer { g_variant_unref(entry) }
                let key = g_variant_get_child_value(entry, 0)!
                let boxed = g_variant_get_child_value(entry, 1)!
                let inner = g_variant_get_variant(boxed)!
                defer {
                    g_variant_unref(key)
                    g_variant_unref(boxed)
                    g_variant_unref(inner)
                }
                entries[String(cString: g_variant_get_string(key, nil))] = value(from: inner)
            }
            return .vardict(entries)
        default:
            if signature.hasPrefix("a") {
                return .array(children(of: variant), elementSignature: String(signature.dropFirst()))
            }
            if signature.hasPrefix("(") {
                return .tuple(children(of: variant))
            }
            return .unsupported(signature: signature)
        }
    }

    private static func children(of variant: OpaquePointer) -> [PortalValue] {
        (0..<g_variant_n_children(variant)).map { index in
            let child = g_variant_get_child_value(variant, index)!
            defer { g_variant_unref(child) }
            return value(from: child)
        }
    }

    /// Takes ownership of a floating `variant`, converts it and releases it.
    public static func consume(_ variant: OpaquePointer) -> PortalValue {
        g_variant_ref_sink(variant)
        defer { g_variant_unref(variant) }
        return value(from: variant)
    }
}

#endif

#if os(Linux)

/// The D-Bus values the portal conversation uses, as a plain Swift type, so
/// the portal logic can run against a fake bus and never touch GVariant.
/// `GDBusConnecting` converts to and from `GVariant` at the one place a real
/// bus is involved.
public indirect enum PortalValue: Equatable, Sendable {
    case string(String)
    case objectPath(String)
    case bool(Bool)
    case int32(Int32)
    case uint32(UInt32)
    case uint64(UInt64)
    case double(Double)
    /// A value in a `v` slot.
    case variant(PortalValue)
    /// An array of values that share `elementSignature`, kept so an empty
    /// array still has a type.
    case array([PortalValue], elementSignature: String)
    /// A struct, `(...)`.
    case tuple([PortalValue])
    /// An `a{sv}`: the options and results dictionary every portal call and
    /// response uses. Its values are variants on the wire; they are held here
    /// unwrapped.
    case vardict([String: PortalValue])
    /// A value this client has no use for, kept by its type string.
    case unsupported(signature: String)

    public var stringValue: String? {
        switch self {
        case let .string(value), let .objectPath(value): value
        case let .variant(inner): inner.stringValue
        default: nil
        }
    }

    public var uint32Value: UInt32? {
        switch self {
        case let .uint32(value): value
        case let .variant(inner): inner.uint32Value
        default: nil
        }
    }

    public var uint64Value: UInt64? {
        switch self {
        case let .uint64(value): value
        case let .variant(inner): inner.uint64Value
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case let .bool(value): value
        case let .variant(inner): inner.boolValue
        default: nil
        }
    }

    public var int32Pair: (Int32, Int32)? {
        switch self {
        case let .tuple(items) where items.count == 2:
            if case let .int32(first) = items[0], case let .int32(second) = items[1] {
                return (first, second)
            }
            return nil
        case let .variant(inner): return inner.int32Pair
        default: return nil
        }
    }

    public var vardictValue: [String: PortalValue]? {
        switch self {
        case let .vardict(value): value
        case let .variant(inner): inner.vardictValue
        default: nil
        }
    }

    public var arrayValue: [PortalValue]? {
        switch self {
        case let .array(items, _): items
        case let .variant(inner): inner.arrayValue
        default: nil
        }
    }

    public var tupleValue: [PortalValue]? {
        switch self {
        case let .tuple(items): items
        case let .variant(inner): inner.tupleValue
        default: nil
        }
    }

    /// The D-Bus type string of this value.
    public var signature: String {
        switch self {
        case .string: "s"
        case .objectPath: "o"
        case .bool: "b"
        case .int32: "i"
        case .uint32: "u"
        case .uint64: "t"
        case .double: "d"
        case .variant: "v"
        case let .array(_, element): "a" + element
        case let .tuple(items): "(" + items.map(\.signature).joined() + ")"
        case .vardict: "a{sv}"
        case let .unsupported(signature): signature
        }
    }
}

#endif

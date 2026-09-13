import Foundation

/// Which of the host's session canvases a message addresses.
///
/// The cap is exactly two. Making that a property of this type rather than a
/// bounds check remembered at every use is what stops per-surface host state
/// from growing on a value a paired machine chooses: there is no way to name a
/// third surface, so there is no way to allocate a third injector, display
/// session, media pipeline or workspace.
public struct CanvasSurfaceID: Hashable, Sendable {
    public static let capacity = 2
    public static let allCases = [CanvasSurfaceID(index: 0), CanvasSurfaceID(index: 1)]

    /// 0 or 1, by construction.
    public let index: Int

    private init(index: Int) {
        self.index = index
    }

    /// `nil` on the wire means surface 0, which is how a viewer that never
    /// sends a surfaceID keeps the single-canvas behaviour. Anything outside
    /// the cap is `nil` here, and every caller turns that into a refusal.
    public init?(wireValue: UInt32?) {
        switch wireValue {
        case .none, .some(0):
            self.init(index: 0)
        case .some(1):
            self.init(index: 1)
        default:
            return nil
        }
    }

    public var wireValue: UInt32 {
        UInt32(index)
    }
}

/// Fixed two-slot storage keyed by `CanvasSurfaceID`.
///
/// Deliberately not a dictionary: every slot exists before any viewer
/// message arrives, so nothing a viewer sends can add, remove or resize
/// storage.
public struct CanvasSurfaceSlots<Element> {
    private var slot0: Element
    private var slot1: Element

    public init(surface0: Element, surface1: Element) {
        slot0 = surface0
        slot1 = surface1
    }

    public init(_ makeElement: (CanvasSurfaceID) -> Element) {
        slot0 = makeElement(CanvasSurfaceID.allCases[0])
        slot1 = makeElement(CanvasSurfaceID.allCases[1])
    }

    public subscript(surface: CanvasSurfaceID) -> Element {
        get { surface.index == 0 ? slot0 : slot1 }
        set {
            if surface.index == 0 {
                slot0 = newValue
            } else {
                slot1 = newValue
            }
        }
    }

    public var all: [Element] {
        [slot0, slot1]
    }
}

extension CanvasSurfaceSlots: Sendable where Element: Sendable {}

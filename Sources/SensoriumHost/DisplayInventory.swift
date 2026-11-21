import Foundation

public enum DisplayInventory {
    /// Display IDs present in `current` that were absent from `baseline` --
    /// the specific display a create/release cycle left behind, as opposed
    /// to one that was already online before the cycle started.
    public static func newlyOnlineIDs(baseline: [DisplaySnapshot], current: [DisplaySnapshot]) -> [UInt32] {
        let baselineIDs = Set(baseline.map { $0.id })
        return current.map { $0.id }.filter { !baselineIDs.contains($0) }.sorted()
    }
}

#if !os(macOS)
extension DisplayInventory {
    /// A platform with no display inventory of its own reports no displays,
    /// so nothing is offered as a host screen until its host target supplies
    /// one through `hostScreenCurrentDisplaysProvider`.
    public static func online() -> [DisplaySnapshot] { [] }

    public static func active() -> [DisplaySnapshot] { [] }
}
#endif

import Foundation

struct DisplaySnapshot: Equatable {
    let id: Int
    let main: Bool
}

@MainActor
enum DisplayInventory {
    static var activeDisplays: [DisplaySnapshot] = []
    static var onlineDisplays: [DisplaySnapshot] = []
    static var onlineReads = 0
    static func active() -> [DisplaySnapshot] { activeDisplays }
    static func online() -> [DisplaySnapshot] {
        onlineReads += 1
        return onlineDisplays
    }
}

@main
@MainActor
struct DisplaySelectionChecks {
    static func main() {
        let secondary = DisplaySnapshot(id: 1, main: false)
        let primary = DisplaySnapshot(id: 2, main: true)
        DisplayInventory.onlineDisplays = [secondary, primary]
        guard Probe.targetDisplay() == primary else {
            print("FAIL: an online display that slept during the idle wait must remain selectable")
            exit(1)
        }
        DisplayInventory.activeDisplays = [secondary]
        DisplayInventory.onlineReads = 0
        precondition(Probe.targetDisplay() == secondary && DisplayInventory.onlineReads == 0)
        DisplayInventory.activeDisplays = [secondary, primary]
        precondition(Probe.targetDisplay() == primary)
        DisplayInventory.activeDisplays = []
        DisplayInventory.onlineDisplays = [secondary]
        precondition(Probe.targetDisplay() == secondary)
        DisplayInventory.onlineDisplays = []
        precondition(Probe.targetDisplay() == nil)
        print("PASS: host-screen probe prefers active displays and retains an online target while asleep")
    }
}

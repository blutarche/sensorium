import Foundation
import SensoriumCore

/// The two credential strengths host screen accepts: a private half held
/// in hardware that cannot be extracted and confirms every use, or one held
/// by the OS keystore behind a presence check that an attacker who already
/// owns that machine can defeat. There is deliberately no third, weaker
/// case.
///
/// This is a report, not proof: see `HostScreenDeviceArming.minimumCredentialStrength`.
public enum HostScreenCredentialStrength: String, Codable, Equatable, Hashable, Sendable {
    case hardwareBound
    case softwarePresence
}

extension HostScreenCredentialStrength: Comparable {
    /// Weakest to strongest: `.softwarePresence` can be extracted after one
    /// presence check; `.hardwareBound` never can.
    public static func < (lhs: Self, rhs: Self) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private static func rank(_ strength: Self) -> Int {
        switch strength {
        case .softwarePresence: return 0
        case .hardwareBound: return 1
        }
    }
}

/// A display's identity for arming, stable enough to survive a restart.
/// `CGDirectDisplayID` cannot be used here: it is not stable across sleep or
/// replug. This reuses the same EDID vendor/model pair
/// `PhysicalDisplayEvidence` already reads off `DisplaySnapshot` to tell a
/// display Sensorium created from one it did not. It does not disambiguate
/// two identical monitors of the same model; `DisplayInventory` carries no
/// finer identity.
public struct HostScreenDisplayIdentity: Codable, Equatable, Hashable, Sendable {
    public var vendorNumber: UInt32
    public var modelNumber: UInt32

    public init(vendorNumber: UInt32, modelNumber: UInt32) {
        self.vendorNumber = vendorNumber
        self.modelNumber = modelNumber
    }

    public init(_ snapshot: DisplaySnapshot) {
        vendorNumber = snapshot.vendorNumber
        modelNumber = snapshot.modelNumber
    }

    /// Opaque to a viewer and not secret: an EDID vendor/model pair
    /// identifies a display model, not a person.
    public var wireStableIdentifier: String {
        String(format: "%08x-%08x", vendorNumber, modelNumber)
    }
}

/// Why one of this Mac's displays is missing from what `offerHostScreenList`
/// actually offers -- the same four gaps, decided by `HostScreenOfferEligibility`
/// alone, so the operator log and the Host Setup window never disagree about why.
public enum HostScreenOfferGapReason: Equatable, Sendable {
    /// `CGDisplayIsOnline` is false: genuinely disconnected, not merely
    /// quiet. `DisplayInventory.online()` still lists a sleeping or mirrored
    /// display, so this case means neither of those.
    case notOnline
    /// `CGDisplayIsAsleep`: online, physically present, showing nothing
    /// right now, and nothing else standing in its way. Told apart from
    /// `notOnline` precisely so a display that is asleep only at the moment
    /// of one offer reads as recoverable rather than gone -- this is the one
    /// gap waking a display can close.
    case asleep
    /// `CGDisplayMirrorsDisplay` names another display: this one shows that
    /// display's picture, never its own, so it is never a legitimate
    /// host-screen target.
    case mirrored
    /// The display is a canvas Sensorium itself created, never a display a
    /// person could be looking at.
    case createdBySensorium

    /// The plain-words reason an operator log line or a paired-machine row
    /// names this gap by.
    public var words: String {
        switch self {
        case .notOnline:
            "not online"
        case .asleep:
            "asleep"
        case .mirrored:
            "mirrored"
        case .createdBySensorium:
            "created by Sensorium"
        }
    }
}

/// Which of this Mac's displays an armed machine may be offered. Arming is
/// per machine, exactly as it is for the screen sharing macOS ships: a
/// machine armed here may be offered whatever this Mac has when a session
/// starts, including a monitor attached after this host launched. Nothing
/// here reads the arming record, and nothing here is reachable from the
/// wire.
///
/// A session canvas Sensorium itself created is the one display that never
/// qualifies. `CanvasDisplayIdentity.vendorID` is what tells it apart, so a
/// host whose only screen is a canvas offers nothing rather than offering
/// its own canvas back.
public enum HostScreenOfferEligibility {
    /// A display that can be captured and shown right now: not ours, online,
    /// awake, and showing its own picture rather than another display's.
    public static func isOfferable(_ display: DisplaySnapshot) -> Bool {
        offerGapReason(for: display) == nil
    }

    /// Every display in `displays` that `isOfferable` accepts, in the order
    /// given.
    public static func offerable(from displays: [DisplaySnapshot]) -> [DisplaySnapshot] {
        displays.filter(isOfferable)
    }

    /// Why `display` cannot be offered right now, `nil` when it can. A
    /// canvas answers `.createdBySensorium` rather than `nil`, so a caller
    /// that hands one in is never told it is offerable.
    ///
    /// Mirroring is answered before sleep, so `.asleep` means sleep is the
    /// only thing in the way. That is what lets the wake path treat this one
    /// answer as "waking this display would make it offerable", rather than
    /// waking a mirror no session could stream however awake it gets.
    public static func offerGapReason(for display: DisplaySnapshot) -> HostScreenOfferGapReason? {
        if PhysicalDisplayEvidence.isSensoriumCanvas(display) {
            return .createdBySensorium
        }
        if !display.online {
            return .notOnline
        }
        if display.mirrorsDisplay != 0 {
            return .mirrored
        }
        if display.asleep {
            return .asleep
        }
        return nil
    }
}

/// One device's grant to drive this machine's host screen.
///
/// `devicePublicKey` matches the key `ApprovedDeviceStoring` already holds
/// for the same device. This is deliberately a separate record from
/// `approved-devices.json` rather than a field folded into it: that file's
/// single meaning, *this device may connect*, should not be overloaded with
/// *this device may drive my screen*.
public struct HostScreenDeviceArming: Codable, Equatable, Sendable {
    public var devicePublicKey: Data
    /// What the person at this machine typed while arming, never a value
    /// read back from a live connection.
    public var deviceName: String
    /// Only decoded so a file written by an earlier version still loads;
    /// nothing reads it.
    public var credentialKind: HostScreenCredentialStrength?
    /// The registered credential's strength as it was when this device was
    /// armed, never re-read live, so a credential registered more weakly
    /// later cannot soften what was already approved. `nil` is a record
    /// predating this field and is refused outright, not treated
    /// permissively.
    public var minimumCredentialStrength: HostScreenCredentialStrength?
    public var armedAt: Date
    /// Whether this device's own session should still ask the person at
    /// this machine when it saw recent local input. Arming a machine is
    /// itself the consent this feature needs; asking first is an extra the
    /// person arming may switch on, so this defaults to `false`.
    public var asksWhenSomeoneIsUsingThisMachine: Bool

    public init(
        devicePublicKey: Data,
        deviceName: String,
        credentialKind: HostScreenCredentialStrength? = nil,
        minimumCredentialStrength: HostScreenCredentialStrength? = nil,
        armedAt: Date,
        asksWhenSomeoneIsUsingThisMachine: Bool = false
    ) {
        self.devicePublicKey = devicePublicKey
        self.deviceName = deviceName
        self.credentialKind = credentialKind
        self.minimumCredentialStrength = minimumCredentialStrength
        self.armedAt = armedAt
        self.asksWhenSomeoneIsUsingThisMachine = asksWhenSomeoneIsUsingThisMachine
    }

    /// No key for the per-display list an earlier version wrote: arming is
    /// per machine now, and a key nothing decodes is a key a file may still
    /// carry. An existing record keeps working, and is written back without
    /// it.
    private enum CodingKeys: String, CodingKey {
        case devicePublicKey, deviceName, credentialKind, minimumCredentialStrength, armedAt
        case asksWhenSomeoneIsUsingThisMachine
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devicePublicKey = try container.decode(Data.self, forKey: .devicePublicKey)
        deviceName = try container.decode(String.self, forKey: .deviceName)
        credentialKind = try container.decodeIfPresent(HostScreenCredentialStrength.self, forKey: .credentialKind)
        minimumCredentialStrength = try container.decodeIfPresent(
            HostScreenCredentialStrength.self, forKey: .minimumCredentialStrength
        )
        armedAt = try container.decode(Date.self, forKey: .armedAt)
        asksWhenSomeoneIsUsingThisMachine = try container.decodeIfPresent(
            Bool.self, forKey: .asksWhenSomeoneIsUsingThisMachine
        ) ?? false
    }
}

extension HostScreenDeviceArming {
    /// Host screen's own default: a machine that pairs and registers a
    /// presence credential is armed at once, for this Mac's displays as they
    /// stand whenever a session starts. `nil` when the pairing device
    /// registered no credential -- it may still pair and use a session
    /// canvas, but this pairing does not arm host screen for it.
    ///
    /// `HostScreenArmingCoordinator.toggle(isOn: true)` in `sensoriumd`
    /// builds through this exact function rather than repeating the same
    /// checks, so the two paths that can ever arm a device cannot drift
    /// apart.
    public static func onPairing(
        devicePublicKey: Data,
        approvedStore: any ApprovedDeviceStoring,
        now: Date
    ) -> HostScreenDeviceArming? {
        guard let strength = approvedStore.presenceCredential(for: devicePublicKey)?.strength else {
            return nil
        }
        return HostScreenDeviceArming(
            devicePublicKey: devicePublicKey,
            deviceName: ApprovedDeviceDisplayName.resolve(for: devicePublicKey, in: approvedStore),
            minimumCredentialStrength: strength,
            armedAt: now,
            asksWhenSomeoneIsUsingThisMachine: false
        )
    }
}

/// Every device currently armed for host screen. Empty is the ordinary,
/// safe state this machine starts in and returns to once every device is
/// disarmed.
public struct HostScreenArming: Codable, Equatable, Sendable {
    public var devices: [HostScreenDeviceArming]

    public init(devices: [HostScreenDeviceArming] = []) {
        self.devices = devices
    }
}

/// Where arming is read and written, and the one property this whole
/// feature depends on: **host-set only**. `writeCount` exists so a test can
/// prove a session driven entirely by wire messages never moves it. This
/// type is never handed to `HostSessionController` or
/// `HostSessionCoordinator`; there is no mutating API for either to be
/// handed in the first place.
///
/// Stored as `~/Library/Application Support/Sensorium/host-screen-arming.json`
/// by `sensoriumd`: this is a policy record, not a secret, and its owner
/// should be able to read it with `cat` and revoke it with `rm`.
public final class HostScreenArmingStore {
    private let url: URL
    public private(set) var writeCount = 0

    public init(url: URL) {
        self.url = url
    }

    public func load() -> HostScreenArming {
        guard let data = try? Data(contentsOf: url),
              let arming = try? JSONDecoder().decode(HostScreenArming.self, from: data) else {
            return HostScreenArming()
        }
        return arming
    }

    private func save(_ arming: HostScreenArming) {
        writeCount += 1
        guard let data = try? JSONEncoder().encode(arming) else {
            return
        }
        try? OwnerOnlyFileWrite.write(data, to: url)
    }

    /// Arms `device`, replacing any earlier arming for the same public key
    /// rather than accumulating two records for one device.
    public func arm(_ device: HostScreenDeviceArming) {
        var arming = load()
        arming.devices.removeAll { $0.devicePublicKey == device.devicePublicKey }
        arming.devices.append(device)
        save(arming)
    }

    /// Disarms one device. Absent is not an error: disarming a device that
    /// was never armed, or armed twice from two racing clicks, both leave
    /// the same end state.
    public func disarm(devicePublicKey: Data) {
        var arming = load()
        arming.devices.removeAll { $0.devicePublicKey == devicePublicKey }
        save(arming)
    }

    /// Removing a paired device removes its arming with it. Same operation
    /// as `disarm`; a distinct name at the
    /// call site in the "Remove paired device" flow, so that flow reads as
    /// what it is rather than as an arming decision.
    public func revoke(devicePublicKey: Data) {
        disarm(devicePublicKey: devicePublicKey)
    }

    /// The person arming a device's own choice of whether their machine
    /// should still ask when it saw recent local input. Absent from
    /// `devices` is not an error -- there is nothing to flip on a device
    /// that is not armed at all -- and this leaves the rest of that
    /// device's own record untouched.
    public func setAsksWhenInUse(devicePublicKey: Data, _ asksWhenInUse: Bool) {
        var arming = load()
        guard let index = arming.devices.firstIndex(where: { $0.devicePublicKey == devicePublicKey }) else {
            return
        }
        arming.devices[index].asksWhenSomeoneIsUsingThisMachine = asksWhenInUse
        save(arming)
    }
}

/// What the menu bar and the Host Setup window say about arming, decided
/// once here so both draw the same words. Deliberately AppKit-free, so the
/// words are testable without a window server.
public enum HostScreenArmingPresentation {
    public struct DeviceLine: Equatable, Sendable {
        public let devicePublicKey: Data
        public let deviceName: String
        /// Worded as a report, never as proof -- see
        /// `HostScreenDeviceArming.minimumCredentialStrength`'s own note.
        /// `nil` for a device armed before that field was snapshotted; a
        /// caller that needs to say something in that case uses
        /// `needsRearmingNotice` on a line of its own, not appended to the
        /// device's name.
        public let credentialSummary: String?

        public init(devicePublicKey: Data, deviceName: String, credentialSummary: String?) {
            self.devicePublicKey = devicePublicKey
            self.deviceName = deviceName
            self.credentialSummary = credentialSummary
        }
    }

    /// One line per armed device, in the order they were armed. Empty when
    /// nothing is armed, which the menu bar and the Host Setup window both
    /// read as "show nothing extra."
    ///
    /// `credentialSummary` reads `HostScreenDeviceArming.minimumCredentialStrength`.
    public static func lines(for arming: HostScreenArming) -> [DeviceLine] {
        arming.devices.map { device in
            DeviceLine(
                devicePublicKey: device.devicePublicKey,
                deviceName: device.deviceName,
                credentialSummary: device.minimumCredentialStrength.map { words(for: $0, deviceName: device.deviceName) }
            )
        }
    }

    /// One row per paired machine, every machine that has ever paired, not
    /// only the ones currently sharing a real screen. `approvedDevices` is
    /// every key `ApprovedDeviceStoring` holds,
    /// paired with the name given at pairing; `arming` says which of them is
    /// currently sharing and, for that one, what credential it registered.
    public struct PairedMachineRow: Equatable, Sendable {
        public let devicePublicKey: Data
        public let deviceName: String
        /// "Key 5DB742A2" when `deviceName` is the name the device actually
        /// gave -- a small secondary line telling apart two machines someone
        /// happened to name alike. `nil` when `deviceName` is itself the
        /// fingerprint fallback (no name recorded), where a second line
        /// would only repeat the title.
        public let keyFingerprintLine: String?
        public let isSharingRealScreen: Bool
        /// Not-yet-armed: the credential registered right now. Armed: the
        /// snapshot taken at arm time. `nil` when there is nothing to
        /// report.
        public let credentialSummary: String?
        /// Why sharing cannot be turned on for this machine right now, or why
        /// its own snapshot needs refreshing, in plain words on its own
        /// line -- `nil` once neither applies. `noCredentialNotice` when no
        /// credential is registered at all; `needsRearmingNotice` for an
        /// armed device with nothing snapshotted.
        public let blockedReason: String?
        /// "May share Built-in Display.", the permission, not a live share.
        /// Names the displays this Mac could hand this machine right now,
        /// since arming is per machine; `nil` when there are none.
        public let sharedDisplaysLine: String?
        /// Why this row has no `sharedDisplaysLine`: this Mac has displays,
        /// but none of them can be shared right now. `nil` whenever
        /// `sharedDisplaysLine` has something to say instead, this row is
        /// not sharing, or the caller passed no display list to judge.
        public let notOfferedReason: String?
        /// Whether this device's own sharing session still asks the person
        /// at this machine when it saw recent local input. `false` for a row
        /// that is not sharing -- there is no arming record to read it from.
        public let asksWhenInUse: Bool

        public init(
            devicePublicKey: Data,
            deviceName: String,
            keyFingerprintLine: String? = nil,
            isSharingRealScreen: Bool,
            credentialSummary: String?,
            blockedReason: String?,
            sharedDisplaysLine: String? = nil,
            notOfferedReason: String? = nil,
            asksWhenInUse: Bool = false
        ) {
            self.devicePublicKey = devicePublicKey
            self.deviceName = deviceName
            self.keyFingerprintLine = keyFingerprintLine
            self.isSharingRealScreen = isSharingRealScreen
            self.credentialSummary = credentialSummary
            self.blockedReason = blockedReason
            self.sharedDisplaysLine = sharedDisplaysLine
            self.notOfferedReason = notOfferedReason
            self.asksWhenInUse = asksWhenInUse
        }
    }

    /// The checkbox label under a sharing row's toggle, shared so the Host
    /// Setup window and any test asserting on it read the same words.
    public static let asksWhenInUseLabel = "Ask me first if this machine is in use"

    /// One row per approved device, in `ApprovedDeviceStoring`'s own order.
    /// A not-yet-armed row gates on the credential registered now; an
    /// armed row on the strength snapshotted when it was armed, with
    /// `needsRearmingNotice` when that snapshot is missing. `activeDisplays`
    /// is this Mac's own displays right now, which is what an armed row
    /// names: arming is per machine, so what a machine may share is decided
    /// afresh from that list. Passing none leaves an armed row silent about
    /// displays rather than claiming this Mac has none.
    public static func pairedMachineRows(
        approvedDevices: [(publicKey: Data, name: String?, credentialStrength: HostScreenCredentialStrength?)],
        arming: HostScreenArming,
        activeDisplays: [DisplaySnapshot] = []
    ) -> [PairedMachineRow] {
        approvedDevices.map { device in
            let resolvedName = device.name ?? ApprovedDeviceDisplayName.fingerprint(of: device.publicKey)
            let keyFingerprintLine = device.name != nil ? "Key \(ApprovedDeviceDisplayName.hex(of: device.publicKey))" : nil
            if let armed = arming.devices.first(where: { $0.devicePublicKey == device.publicKey }) {
                let snapshotted = armed.minimumCredentialStrength
                let sharedDisplaysLine = sharedDisplaysLine(activeDisplays: activeDisplays)
                let notOfferedReason = sharedDisplaysLine == nil && !activeDisplays.isEmpty
                    ? noShareableDisplayNotice
                    : nil
                return PairedMachineRow(
                    devicePublicKey: device.publicKey,
                    deviceName: resolvedName,
                    keyFingerprintLine: keyFingerprintLine,
                    isSharingRealScreen: true,
                    credentialSummary: snapshotted.map { words(for: $0, deviceName: resolvedName) },
                    blockedReason: snapshotted == nil ? needsRearmingNotice : nil,
                    sharedDisplaysLine: sharedDisplaysLine,
                    notOfferedReason: notOfferedReason,
                    asksWhenInUse: armed.asksWhenSomeoneIsUsingThisMachine
                )
            }
            let credentialSummary = device.credentialStrength.map { words(for: $0, deviceName: resolvedName) }
            return PairedMachineRow(
                devicePublicKey: device.publicKey,
                deviceName: resolvedName,
                keyFingerprintLine: keyFingerprintLine,
                isSharingRealScreen: false,
                credentialSummary: credentialSummary,
                blockedReason: credentialSummary == nil ? noCredentialNotice(deviceName: resolvedName) : nil
            )
        }
    }

    /// "May share Built-in Display." for one, "May share Built-in Display
    /// and External Display." for two, an Oxford-style list for three or more.
    /// `nil` when this Mac has no display an armed machine could be handed
    /// right now -- an asleep, mirrored, or Sensorium-created display is
    /// never actually shareable, so it is left out here exactly as
    /// `offerHostScreenList` leaves it out. An empty sentence is worse than
    /// no sentence.
    private static func sharedDisplaysLine(activeDisplays: [DisplaySnapshot]) -> String? {
        let matched = HostScreenOfferEligibility.offerable(from: activeDisplays)
        guard !matched.isEmpty else { return nil }
        let mainDisplay = activeDisplays.first { $0.main }
        let labels = disambiguatedLabels(for: matched, mainDisplay: mainDisplay)
        return "May share \(oxfordList(labels))."
    }

    /// A caller with a full list of displays to offer at once -- the wire's
    /// `hostScreenList` entries and this machine's own arming rows -- so
    /// two displays that would otherwise print the same label can be told
    /// apart. See `disambiguatedLabels(for:mainDisplay:)`.
    public static func displayLabels(for displays: [DisplaySnapshot]) -> [String] {
        disambiguatedLabels(for: displays, mainDisplay: displays.first { $0.main })
    }

    /// `displayLabel(for:)` names one display alone; two can still collide
    /// within the list actually being offered. A display macOS named
    /// (`DisplaySnapshot.name`) that collides with another of the same name
    /// (two monitors of the same model) is told apart by offer order --
    /// the first keeps the plain name, the second reads "(2)", the third
    /// "(3)", and so on -- never by a physical detail like size or position,
    /// since a name collision means those may well be identical too. A
    /// display with no name that falls back to its kind ("External
    /// Display") is told apart by physical detail instead, tried in order: pixel
    /// size ("External Display (3840\u{00d7}2160)"), then where the display
    /// sits relative to `mainDisplay` ("External Display (left)"), and only
    /// when both of those also tie, the display's own id -- never guessed
    /// at, since an id is at least always distinct. A label nothing else in
    /// `displays` shares keeps the plain label.
    private static func disambiguatedLabels(for displays: [DisplaySnapshot], mainDisplay: DisplaySnapshot?) -> [String] {
        let baseLabels = displays.map(displayLabel(for:))
        var countsByLabel: [String: Int] = [:]
        for label in baseLabels { countsByLabel[label, default: 0] += 1 }
        guard countsByLabel.values.contains(where: { $0 > 1 }) else { return baseLabels }
        var ordinalsSeenByLabel: [String: Int] = [:]
        return zip(displays, baseLabels).map { display, label in
            guard countsByLabel[label, default: 0] > 1 else { return label }
            if display.name != nil {
                ordinalsSeenByLabel[label, default: 0] += 1
                let ordinal = ordinalsSeenByLabel[label]!
                return ordinal == 1 ? label : "\(label) (\(ordinal))"
            }
            let group = zip(displays, baseLabels).filter { $0.1 == label }.map { $0.0 }
            return "\(label) (\(disambiguator(for: display, in: group, mainDisplay: mainDisplay)))"
        }
    }

    private static func disambiguator(for display: DisplaySnapshot, in group: [DisplaySnapshot], mainDisplay: DisplaySnapshot?) -> String {
        let sizeLabels = group.map(pixelSizeLabel(for:))
        if Set(sizeLabels).count == group.count {
            return pixelSizeLabel(for: display)
        }
        if let mainDisplay {
            let positionLabels = group.map { positionLabel(for: $0, relativeTo: mainDisplay) }
            if positionLabels.allSatisfy({ $0 != nil }), Set(positionLabels.compactMap { $0 }).count == group.count {
                return positionLabel(for: display, relativeTo: mainDisplay)!
            }
        }
        return "\(display.id)"
    }

    private static func pixelSizeLabel(for display: DisplaySnapshot) -> String {
        "\(display.modePixelWidth)\u{00d7}\(display.modePixelHeight)"
    }

    /// `nil` for `mainDisplay` itself (no direction relative to itself) and
    /// for a display whose bounds sit exactly on `mainDisplay`'s own centre
    /// -- both cases where a caller must fall back to something else rather
    /// than print a meaningless direction.
    private static func positionLabel(for display: DisplaySnapshot, relativeTo mainDisplay: DisplaySnapshot) -> String? {
        guard display.id != mainDisplay.id else { return nil }
        let dx = display.bounds.midX - mainDisplay.bounds.midX
        let dy = display.bounds.midY - mainDisplay.bounds.midY
        guard dx != 0 || dy != 0 else { return nil }
        if abs(dx) >= abs(dy) {
            return dx < 0 ? "left" : "right"
        }
        return dy < 0 ? "above" : "below"
    }

    private static func oxfordList(_ items: [String]) -> String {
        switch items.count {
        case 0:
            return ""
        case 1:
            return items[0]
        case 2:
            return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", and \(items[items.count - 1])"
        }
    }

    /// What a device with no registered credential cannot yet do, said in
    /// words about the missing fact rather than the internal state that
    /// produced it. Shared so the Host Setup window and the menu bar say
    /// exactly the same thing. Named by `deviceName`, not "This machine" --
    /// this row's own words are read at the host, where "this machine" already
    /// means the host itself; the paired device needs its own name.
    public static func noCredentialNotice(deviceName: String) -> String {
        "Pair \(deviceName) again to turn this on."
    }

    /// An armed device whose snapshot predates this machine recording one at
    /// arm time -- never claims no credential exists, since one plainly
    /// does (it is armed), only that this machine never captured it. Turning
    /// sharing off and back on re-arms it and takes a fresh snapshot.
    /// An armed machine with nothing to hand it: this Mac has displays, but
    /// every one of them is offline, asleep, mirroring another, or a canvas
    /// Sensorium created. Nothing about the machine's own arming is wrong,
    /// so this never reads as a permission problem.
    public static let noShareableDisplayNotice =
        "No display on this Mac can be shared right now."

    public static let needsRearmingNotice =
        "How this machine holds its presence key was not recorded when it paired. Turn Share host screen off and on again to record it."

    /// The words `hostScreenList`'s own `label` field already uses --
    /// shared so a caller that names the same display later (the session
    /// log, the badge) says exactly the same thing rather than deriving it
    /// a second time. macOS's own name for the display (`DisplaySnapshot.name`)
    /// is used when it has one, so two external monitors of different
    /// models read as themselves rather than both reading "External
    /// Display"; a display with no name falls back to its kind. Two
    /// displays sharing the same name are told apart by `displayLabels(for:)`,
    /// not here -- this function alone has no sibling displays to compare
    /// against.
    public static func displayLabel(for display: DisplaySnapshot) -> String {
        display.name ?? (display.builtin ? "Built-in Display" : "External Display")
    }

    static func words(for strength: HostScreenCredentialStrength, deviceName: String) -> String {
        switch strength {
        case .hardwareBound:
            return "Presence key on \(deviceName): reported as hardware-held."
        case .softwarePresence:
            return "Presence key on \(deviceName): reported as software-held."
        }
    }
}

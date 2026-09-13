import Foundation

/// Why `HostScreenSelectionGuard` refused a display: one case per
/// obligation, so a caller -- and a test -- can tell which one failed
/// rather than being handed one generic "no" standing in for six different
/// reasons.
public enum HostScreenSelectionRefusal: Error, Equatable, Sendable {
    /// This device holds no arming record at all.
    case deviceNotArmed
    /// The device is armed, but not for the display the token names.
    case displayNotArmed
    /// The token does not match one this session actually minted.
    case tokenNotMinted
    /// The display the token names is not in the live inventory right now,
    /// is present but offline, is asleep, or is a mirror of another
    /// display -- none of those is a display this session can actually
    /// capture, whatever an earlier offer once named.
    case displayGone
    /// The display carries `CanvasDisplayIdentity.vendorID` -- it is a
    /// session canvas Sensorium created, never a legitimate host-screen
    /// target, however it came to be armed or minted.
    case displayIsSensoriumCanvas
    /// The display is live now but was not part of the snapshot taken
    /// before this session began, e.g. a monitor plugged in after
    /// `hostScreenList` was already offered.
    case displayAbsentFromPreSessionSnapshot
}

/// Admits a display for host-screen capture only when every obligation
/// holds, and refuses the whole request the instant any one does not.
///
/// `admit` returns either the live `CGDirectDisplayID` (`DisplaySnapshot.id`)
/// of a display that passed all six checks, or a `HostScreenSelectionRefusal`
/// naming the one that did not. There is no third case: nothing here
/// represents a partial, view-only, or otherwise reduced admission, so no
/// combination of inputs can produce one -- a caller that wants degraded
/// output would have to invent a type this function does not return.
public enum HostScreenSelectionGuard {
    /// - Parameters:
    ///   - deviceKey: the requesting, already-authenticated device's public key.
    ///   - token: the opaque token the viewer sent back from `hostScreenList`.
    ///   - mintedTokens: every token this session itself minted, mapped to
    ///     the display identity it was minted for. A token this session
    ///     never minted -- forged, replayed from another session, or simply
    ///     wrong -- is not in this map by construction.
    ///   - arming: the host's current arming record.
    ///   - currentDisplays: a fresh `DisplayInventory.online()` read, taken
    ///     at admission time.
    ///   - preSessionSnapshot: the same kind of read, taken once before this
    ///     session offered `hostScreenList`, and not refreshed since.
    ///
    /// The token is resolved to a display identity before the armed-display
    /// check, because which display is in question is not known until then;
    /// this changes only the order, never which obligation a refusal names.
    public static func admit(
        deviceKey: Data,
        token: Data,
        mintedTokens: [Data: HostScreenDisplayIdentity],
        arming: HostScreenArming,
        currentDisplays: [DisplaySnapshot],
        preSessionSnapshot: [DisplaySnapshot]
    ) -> Result<UInt32, HostScreenSelectionRefusal> {
        guard let device = arming.devices.first(where: { $0.devicePublicKey == deviceKey }) else {
            return .failure(.deviceNotArmed)
        }
        guard let identity = mintedTokens[token] else {
            return .failure(.tokenNotMinted)
        }
        guard device.armedDisplays.contains(identity) else {
            return .failure(.displayNotArmed)
        }
        guard let live = currentDisplays.first(where: {
            $0.online && !$0.asleep && $0.mirrorsDisplay == 0 && HostScreenDisplayIdentity($0) == identity
        }) else {
            return .failure(.displayGone)
        }
        guard !PhysicalDisplayEvidence.isSensoriumCanvas(live) else {
            return .failure(.displayIsSensoriumCanvas)
        }
        guard preSessionSnapshot.contains(where: { HostScreenDisplayIdentity($0) == identity }) else {
            return .failure(.displayAbsentFromPreSessionSnapshot)
        }
        return .success(live.id)
    }
}

import Foundation

/// Why `HostScreenSelectionGuard` refused a display: one case per
/// obligation, so a caller -- and a test -- can tell which one failed
/// rather than being handed one generic "no" standing in for four different
/// reasons.
public enum HostScreenSelectionRefusal: Error, Equatable, Sendable {
    /// This device holds no arming record at all. Arming is per machine, so
    /// this is the only arming question there is to ask.
    case deviceNotArmed
    /// The token does not match one this session actually minted.
    case tokenNotMinted
    /// The display the token names is not in the live inventory right now,
    /// is present but offline, is asleep, or is a mirror of another
    /// display -- none of those is a display this session can actually
    /// capture, whatever an earlier offer once named.
    case displayGone
    /// The display carries `CanvasDisplayIdentity.vendorID` -- it is a
    /// session canvas Sensorium created, never a legitimate host-screen
    /// target, however it came to be minted.
    case displayIsSensoriumCanvas
}

/// Admits a display for host-screen capture only when every obligation
/// holds, and refuses the whole request the instant any one does not.
///
/// `admit` returns either the live `CGDirectDisplayID` (`DisplaySnapshot.id`)
/// of a display that passed all four checks, or a `HostScreenSelectionRefusal`
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
    public static func admit(
        deviceKey: Data,
        token: Data,
        mintedTokens: [Data: HostScreenDisplayIdentity],
        arming: HostScreenArming,
        currentDisplays: [DisplaySnapshot]
    ) -> Result<UInt32, HostScreenSelectionRefusal> {
        guard arming.devices.contains(where: { $0.devicePublicKey == deviceKey }) else {
            return .failure(.deviceNotArmed)
        }
        guard let identity = mintedTokens[token] else {
            return .failure(.tokenNotMinted)
        }
        let matches = currentDisplays.filter { HostScreenDisplayIdentity($0) == identity }
        guard let live = matches.first(where: HostScreenOfferEligibility.isOfferable) else {
            return .failure(
                matches.contains(where: PhysicalDisplayEvidence.isSensoriumCanvas)
                    ? .displayIsSensoriumCanvas
                    : .displayGone
            )
        }
        return .success(live.id)
    }
}

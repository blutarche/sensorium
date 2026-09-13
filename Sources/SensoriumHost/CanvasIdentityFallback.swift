import Foundation

/// The identities one canvas may present, in the order they are tried.
///
/// A host that ends without releasing its canvas leaves that display up,
/// and the window server keeps it alive with no owner. The stable
/// identity of that surface stays taken, macOS refuses to create a second
/// display claiming the same vendor, product and serial, and this machine can
/// then host nothing at all until it is restarted. Trying a few alternative
/// serials after the stable one turns that into a session that starts anyway,
/// on a differently numbered identity.
///
/// The sequence is a pure function of the surface and of what the canvas is
/// for: a session's first entry is always the stable identity
/// `CanvasDisplayIdentity` describes, so nothing changes for a host whose
/// previous run shut down properly, and no entry is ever another surface's or
/// another purpose's.
public enum CanvasIdentityFallback {
    /// Enough to keep a machine hosting through a day of leftovers, because
    /// every one of them stays until that machine is restarted: a host that
    /// ends without releasing its canvas leaves it online with no owner, and
    /// no later process can remove it. Larger would only add waiting before
    /// the host reports it cannot start. A machine with no virtual-display
    /// runtime at all never reaches them -- that refusal ends the walk at
    /// the first attempt, whatever this is.
    public static let alternativeCount = 12

    public static func identities(
        for surface: CanvasSurfaceID,
        purpose: CanvasPurpose = .session
    ) -> [CanvasDisplayIdentity] {
        let first = firstAttempt(for: purpose)
        return (0...alternativeCount).map {
            CanvasDisplayIdentity(surface: surface, attempt: first + $0)
        }
    }

    /// Where a purpose's identities begin.
    ///
    /// The capability probe's band starts past every attempt a session can
    /// reach. The probe creates and releases a canvas of its own moments
    /// before the first session creates one, and a probe holding an identity
    /// that session is about to ask for -- even only until it lets go of it --
    /// would push the session onto a fallback it never needed.
    private static func firstAttempt(for purpose: CanvasPurpose) -> Int {
        switch purpose {
        case .session:
            return 0
        case .capabilityProbe:
            return alternativeCount + 1
        }
    }
}

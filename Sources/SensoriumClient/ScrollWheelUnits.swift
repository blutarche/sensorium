/// How far a discrete mouse-wheel notch scrolls, shared by every viewer.
public enum ScrollWheelUnits {
    /// In the points a host scrolls by when it does not read a wheel's lines.
    /// A wheel reports notches, or lines, rather than a distance, and such a
    /// host applies the points as pixels, so a figure has to be chosen here:
    /// 10 is the low end of libinput's notional 10 to 15 units per click,
    /// which keeps a notch close to one line of text rather than a jump.
    public static let pointsPerNotch: Double = 10
}

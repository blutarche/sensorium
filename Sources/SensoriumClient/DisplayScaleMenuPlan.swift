import Foundation
import SensoriumCore

/// One row of the Display menu's resolution picker: the scale it selects
/// (`nil` for Automatic, the geometry-derived default), its title
/// naming the pixel size that scale streams at, and whether it is the user's
/// current choice.
public struct DisplayScaleMenuItem: Equatable, Sendable {
    public let scale: Double?
    public let title: String
    public let isSelected: Bool

    public init(scale: Double?, title: String, isSelected: Bool) {
        self.scale = scale
        self.title = title
        self.isSelected = isSelected
    }
}

/// The Display menu's whole content, as data: every row and the one line
/// explaining a clamped picture, when there is one to explain. AppKit-free, so
/// what the menu says is verified without a menu bar --
/// `ViewerMainMenuController` only asks this for today's rows and draws them.
public struct DisplayScaleMenuState: Equatable, Sendable {
    public let items: [DisplayScaleMenuItem]
    public let clampNotice: String?

    public init(items: [DisplayScaleMenuItem], clampNotice: String?) {
        self.items = items
        self.clampNotice = clampNotice
    }
}

public enum DisplayScaleMenuPlan {
    /// "Automatic" first, then each explicit step `StreamScalePolicy` allows,
    /// labelled with the pixel size that step streams, rather than a bare
    /// multiplier.
    public static func items(
        selectedPreference: StreamScalePreference,
        canvasLogicalWidth: Double,
        canvasLogicalHeight: Double
    ) -> [DisplayScaleMenuItem] {
        var result = [
            DisplayScaleMenuItem(
                scale: nil,
                title: "Automatic",
                isSelected: selectedPreference == .automatic
            )
        ]
        for step in StreamScalePolicy.steps {
            let width = Int((canvasLogicalWidth * step).rounded())
            let height = Int((canvasLogicalHeight * step).rounded())
            result.append(DisplayScaleMenuItem(
                scale: step,
                title: "\(scaleText(step)) (\(width) x \(height))",
                isSelected: selectedPreference == .fixed(step)
            ))
        }
        return result
    }

    /// The one line explaining why the picture is softer than what was asked
    /// for -- `nil` whenever there is nothing to explain, so it is never a
    /// permanent menu item. `clampedFromUserChoice` -- the host's own,
    /// unambiguous report that a fixed choice was held back -- is checked
    /// first; the plain geometry comparison beneath it is what is left to go
    /// on under `.automatic`, where there is no explicit choice to name.
    public static func clampNotice(
        appliedStreamScale: Double?,
        requestedStreamScale: Double?,
        clampedFromUserChoice: Double? = nil
    ) -> String? {
        if let clampedFromUserChoice, let appliedStreamScale, appliedStreamScale < clampedFromUserChoice {
            return "Held to \(scaleText(appliedStreamScale)) \u{2014} you asked for \(scaleText(clampedFromUserChoice))"
        }
        guard let appliedStreamScale, let requestedStreamScale, appliedStreamScale < requestedStreamScale else {
            return nil
        }
        return "Held to \(scaleText(appliedStreamScale)) \u{2014} asked for \(scaleText(requestedStreamScale))"
    }

    private static func scaleText(_ scale: Double) -> String {
        String(format: "%.2fx", scale)
    }
}

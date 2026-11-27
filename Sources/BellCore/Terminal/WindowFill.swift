import CoreGraphics

/// Where a terminal window goes to fill its screen, as Window › Fill does: the screen's
/// usable area, without the menu bar and the Dock, on the same desktop.
///
/// Frames are in the accessibility API's coordinates (origin at the top left of the
/// primary screen, y down); screens come in AppKit's (origin at its bottom left, y up).
public enum WindowFill {
    /// A window this close to every edge already fills the screen: terminals size
    /// themselves in whole cells, so a filled one falls a little short.
    static let slack: CGFloat = 32

    /// The frame to give the window, or nil when it already fills its screen.
    public static func target(window: CGRect, visibleFrames: [CGRect], primaryHeight: CGFloat) -> CGRect? {
        let areas = visibleFrames.map { flipped($0, primaryHeight: primaryHeight) }
        let center = CGPoint(x: window.midX, y: window.midY)
        // The screen the window is on; it is not moved to another.
        guard let area = areas.first(where: { $0.contains(center) })
            ?? areas.max(by: { overlap($0, window) < overlap($1, window) })
        else { return nil }
        return fills(window, area) ? nil : area
    }

    static func fills(_ window: CGRect, _ area: CGRect) -> Bool {
        abs(window.minX - area.minX) <= slack && abs(window.minY - area.minY) <= slack
            && abs(window.maxX - area.maxX) <= slack && abs(window.maxY - area.maxY) <= slack
    }

    static func flipped(_ frame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let shared = a.intersection(b)
        return shared.isNull ? 0 : shared.width * shared.height
    }
}

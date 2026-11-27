import CoreGraphics
import Foundation

/// The bubbles beside the desktop icon: what the system notifications say, newest on top.
public struct BubbleQueue: Equatable, Sendable {
    public static let limit = 3
    /// How long a bubble that needs nothing from you stays, counting only while you are
    /// at the computer: long enough to read its three lines.
    public static let lifetime: TimeInterval = 12
    /// What is left once the pointer leaves a bubble it rested on.
    public static let lingerAfterHover: TimeInterval = 4

    public private(set) var items: [Notice] = []

    public init() {}

    public mutating func apply(_ changes: Notices.Changes) {
        items.removeAll { changes.withdraw.contains($0.id) }
        for notice in changes.post {
            // One bubble per session: its latest news.
            items.removeAll { $0.session == notice.session }
            items.insert(notice, at: 0)
        }
        while items.count > Self.limit {
            // A question left unanswered matters more than news that would fade anyway.
            let index = items.lastIndex(where: Self.expires) ?? items.count - 1
            items.remove(at: index)
        }
    }

    public mutating func remove(_ id: String) {
        items.removeAll { $0.id == id }
    }

    /// A question stays until it is answered and a failure until it is seen to; only
    /// news that asks nothing of you fades after `lifetime`.
    public static func expires(_ notice: Notice) -> Bool {
        notice.kind == .done
    }
}

/// Where the desktop icon and its bubbles sit, in screen coordinates (origin bottom left).
public enum DesktopPlacement {
    static let margin: CGFloat = 24
    static let gap: CGFloat = 4

    /// The bottom right of the screen's usable area, clear of the Dock.
    public static func defaultOrigin(size: CGSize, visible: CGRect) -> CGPoint {
        CGPoint(x: visible.maxX - size.width - margin, y: visible.minY + margin)
    }

    /// Keep the edge nearest the corresponding side of the screen in place.
    public static func resizedIcon(_ frame: CGRect, to size: CGSize, visible: CGRect) -> CGRect {
        let x = frame.midX > visible.midX ? frame.maxX - size.width : frame.minX
        let y = frame.midY > visible.midY ? frame.maxY - size.height : frame.minY
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return CGRect(x: min(max(x, visible.minX), maxX), y: min(max(y, visible.minY), maxY),
                      width: size.width, height: size.height)
    }

    /// Eyes look towards nearby points and gradually return to center at the edge of range.
    /// Converts the vertical direction from screen coordinates to SwiftUI offsets.
    public static func mascotGaze(pointer: CGPoint, icon: CGRect) -> CGSize {
        let dx = pointer.x - (icon.minX + icon.width * 0.615)
        let dy = pointer.y - (icon.minY + icon.height * 0.415)
        let distance = hypot(dx, dy)
        let strength = min(1, max(0, (92 - distance) / 44))
        let distanceForFullTurn = max(distance, 25)
        return CGSize(width: 2.5 * dx / distanceForFullTurn * strength,
                      height: -1.7 * dy / distanceForFullTurn * strength)
    }

    /// Beside the icon on the side facing the middle of the screen, tops aligned, kept
    /// on screen.
    public static func bubbleFrame(size: CGSize, icon: CGRect, visible: CGRect) -> CGRect {
        let towardsLeft = icon.midX > visible.midX
        let x = towardsLeft ? icon.minX - gap - size.width : icon.maxX + gap
        let y = icon.maxY - size.height
        return CGRect(
            x: min(max(x, visible.minX), visible.maxX - size.width),
            y: min(max(y, visible.minY), visible.maxY - size.height),
            width: size.width,
            height: size.height
        )
    }
}

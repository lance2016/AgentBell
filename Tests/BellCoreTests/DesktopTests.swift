import CoreGraphics
import Foundation
import Testing
@testable import BellCore

struct BubbleQueueTests {
    func notice(_ session: String, _ kind: Notice.Kind) -> Notice {
        Notice(session: session, kind: kind, title: "\(session) \(kind)", subtitle: nil, body: nil)
    }

    @Test func newestFirstAndOnePerSession() {
        var queue = BubbleQueue()
        queue.apply(Notices.Changes(post: [notice("a", .waiting)]))
        queue.apply(Notices.Changes(post: [notice("b", .done)]))
        #expect(queue.items.map(\.id) == ["b.done", "a.waiting"])
        // The session moved on: its newer news replaces the old bubble.
        queue.apply(Notices.Changes(post: [notice("a", .failed)]))
        #expect(queue.items.map(\.id) == ["a.failed", "b.done"])
    }

    @Test func withdrawnNoticesLeave() {
        var queue = BubbleQueue()
        queue.apply(Notices.Changes(post: [notice("a", .waiting), notice("b", .waiting)]))
        queue.apply(Notices.Changes(withdraw: ["a.waiting"]))
        #expect(queue.items.map(\.id) == ["b.waiting"])
        queue.remove("b.waiting")
        #expect(queue.items.isEmpty)
    }

    @Test func overTheLimitDropsWhatWouldExpireAnyway() {
        var queue = BubbleQueue()
        queue.apply(Notices.Changes(post: [notice("a", .waiting)]))
        queue.apply(Notices.Changes(post: [notice("b", .done)]))
        queue.apply(Notices.Changes(post: [notice("c", .waiting)]))
        queue.apply(Notices.Changes(post: [notice("d", .waiting)]))
        #expect(queue.items.map(\.id) == ["d.waiting", "c.waiting", "a.waiting"])
        queue.apply(Notices.Changes(post: [notice("e", .waiting)]))
        #expect(queue.items.map(\.id) == ["e.waiting", "d.waiting", "c.waiting"])
    }

    @Test func onlyNewsThatAsksNothingFades() {
        #expect(!BubbleQueue.expires(notice("a", .waiting)))
        #expect(!BubbleQueue.expires(notice("a", .failed)))
        #expect(BubbleQueue.expires(notice("a", .done)))
    }
}

struct DesktopPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)

    @Test func startsAtTheBottomRight() {
        let origin = DesktopPlacement.defaultOrigin(size: CGSize(width: 72, height: 72), visible: screen)
        #expect(origin == CGPoint(x: 1440 - 72 - 24, y: 24))
    }

    @Test func resizingKeepsTheBottomRightAnchorAndCanReturnToTheOldSize() {
        let frame = CGRect(x: 1352, y: 24, width: 64, height: 64)
        let larger = DesktopPlacement.resizedIcon(frame, to: CGSize(width: 128, height: 128), visible: screen)
        #expect(larger == CGRect(x: 1288, y: 24, width: 128, height: 128))
        #expect(DesktopPlacement.resizedIcon(larger, to: frame.size, visible: screen) == frame)
    }

    @Test func resizingClampsAPartiallyOffscreenIconOnASecondaryDisplay() {
        let display = CGRect(x: -900, y: 50, width: 900, height: 850)
        let frame = CGRect(x: -62, y: 848, width: 88, height: 88)
        let resized = DesktopPlacement.resizedIcon(frame, to: CGSize(width: 128, height: 128), visible: display)
        #expect(resized == CGRect(x: -128, y: 772, width: 128, height: 128))
    }

    @Test func mascotLooksOutsideItsWindowAndReturnsToCenter() {
        let icon = CGRect(x: 200, y: 300, width: 64, height: 64)
        let near = DesktopPlacement.mascotGaze(pointer: CGPoint(x: 280, y: 370), icon: icon)
        let farther = DesktopPlacement.mascotGaze(pointer: CGPoint(x: 295, y: 385), icon: icon)
        #expect(near.width > farther.width && farther.width > 0)
        #expect(near.height < farther.height && farther.height < 0)
        #expect(DesktopPlacement.mascotGaze(pointer: CGPoint(x: 400, y: 400), icon: icon) == .zero)
    }

    @Test func bubbleOpensTowardsTheMiddle() {
        let size = CGSize(width: 280, height: 64)
        let right = CGRect(x: 1300, y: 400, width: 72, height: 72)
        #expect(DesktopPlacement.bubbleFrame(size: size, icon: right, visible: screen)
            == CGRect(x: 1300 - 4 - 280, y: 472 - 64, width: 280, height: 64))
        let left = CGRect(x: 40, y: 400, width: 72, height: 72)
        #expect(DesktopPlacement.bubbleFrame(size: size, icon: left, visible: screen).minX == CGFloat(116))
    }

    @Test func bubbleStaysOnScreen() {
        let size = CGSize(width: 280, height: 220)
        let low = CGRect(x: 1300, y: 10, width: 72, height: 72)
        #expect(DesktopPlacement.bubbleFrame(size: size, icon: low, visible: screen).minY == 0)
    }
}

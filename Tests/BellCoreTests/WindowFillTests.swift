import CoreGraphics
import Testing
@testable import BellCore

struct WindowFillTests {
    /// A 1512×982 laptop screen: a 37 pt menu bar on top, the Dock hidden.
    let laptop = CGRect(x: 0, y: 0, width: 1512, height: 945)
    /// A second screen to its right, its top level with the laptop's, a Dock 70 pt high.
    let external = CGRect(x: 1512, y: -98, width: 1920, height: 1010)

    @Test func smallWindowFillsItsScreen() {
        let window = CGRect(x: 200, y: 150, width: 800, height: 500)
        let target = WindowFill.target(window: window, visibleFrames: [laptop], primaryHeight: 982)
        #expect(target == CGRect(x: 0, y: 37, width: 1512, height: 945))
    }

    /// Terminals round their size to whole cells: a few points short is filled already.
    @Test func filledWindowIsLeftAlone() {
        let window = CGRect(x: 0, y: 37, width: 1505, height: 930)
        #expect(WindowFill.target(window: window, visibleFrames: [laptop], primaryHeight: 982) == nil)
    }

    @Test func windowStaysOnItsOwnScreen() {
        let window = CGRect(x: 1800, y: 300, width: 900, height: 600)
        let target = WindowFill.target(window: window, visibleFrames: [laptop, external], primaryHeight: 982)
        // AppKit's y −98 at the bottom is 982 − (−98 + 1010) = 70 from the top.
        #expect(target == CGRect(x: 1512, y: 70, width: 1920, height: 1010))
    }

    /// Centre off every screen, as a window dragged half past an edge: the screen it
    /// overlaps most.
    @Test func windowPastAnEdgeGoesToTheScreenItMostlyCovers() {
        let window = CGRect(x: -600, y: 100, width: 800, height: 500)
        let target = WindowFill.target(window: window, visibleFrames: [laptop, external], primaryHeight: 982)
        #expect(target == CGRect(x: 0, y: 37, width: 1512, height: 945))
    }

    @Test func noScreenNoChange() {
        #expect(WindowFill.target(window: CGRect(x: 0, y: 0, width: 10, height: 10), visibleFrames: [], primaryHeight: 0) == nil)
    }
}

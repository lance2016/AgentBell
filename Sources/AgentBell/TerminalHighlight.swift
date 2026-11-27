import AppKit
import ApplicationServices

/// A short ring around the terminal the user was just taken to, so that split stands out
/// among the others. Ported from AI Pet's `split_highlight.rs`.
///
/// Ghostty's scripting places a terminal by window and tab, not on screen; its focused
/// split can only be read through the accessibility API. Without that permission nothing
/// is drawn and nothing is asked. The terminal comes forward after the jump returns, at
/// times switching spaces on the way, so the ring waits until the app is in front and
/// its focused terminal holds still.
@MainActor
enum TerminalHighlight {
    private static let fadeIn: TimeInterval = 0.15
    private static let hold: TimeInterval = 0.9
    private static let fadeOut: TimeInterval = 0.45
    /// A focused element smaller than this is not a terminal worth ringing.
    private static let minSide: CGFloat = 40
    private static let settlePoll: Duration = .milliseconds(100)
    private static let settleWithin: TimeInterval = 2
    /// What a terminal is to accessibility, in Ghostty 1.4 and Terminal.app alike.
    private static let terminalRole = "AXTextArea"

    private static var ring: NSPanel?
    /// Bumped by every ring, so the steps of one that was taken over do nothing.
    private static var generation = 0

    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security › Accessibility.
    static func askPermission() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Rings the focused terminal of the app with this pid once it is in front.
    static func flash(pid: pid_t) {
        guard isAllowed else { return }
        generation += 1
        let mine = generation
        Task {
            guard let frame = await settledFrame(pid: pid), mine == generation else { return }
            show(frame)
            try? await Task.sleep(for: .seconds(fadeIn + hold))
            guard mine == generation else { return }
            fade(to: 0, over: fadeOut)
            try? await Task.sleep(for: .seconds(fadeOut))
            guard mine == generation else { return }
            ring?.orderOut(nil)
        }
    }

    /// The app's focused terminal once the app is in front and the terminal is where it
    /// was a poll ago; nil if that takes longer than `settleWithin`.
    private static func settledFrame(pid: pid_t) async -> CGRect? {
        let deadline = Date().addingTimeInterval(settleWithin)
        var last: CGRect?
        while Date() < deadline {
            let frame = frontmostPID() == pid ? focusedTerminalFrame(pid: pid) : nil
            if let frame, frame == last { return frame }
            last = frame
            try? await Task.sleep(for: settlePoll)
        }
        return nil
    }

    private static func show(_ frame: CGRect) {
        // Accessibility counts down from the top of the main screen, AppKit up from its bottom.
        guard let main = NSScreen.screens.first else { return }
        let rect = CGRect(x: frame.minX, y: main.frame.height - frame.maxY, width: frame.width, height: frame.height)
        let ring = self.ring ?? makeRing()
        self.ring = ring
        ring.setFrame(rect, display: false)
        ring.alphaValue = 0
        ring.orderFrontRegardless()
        fade(to: 1, over: fadeIn)
    }

    private static func fade(to alpha: CGFloat, over duration: TimeInterval) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            ring?.animator().alphaValue = alpha
        }
    }

    /// A see-through panel above other apps on whichever space is showing. The ring sits
    /// inside the terminal's frame, so it never covers a neighbor.
    private static func makeRing() -> NSPanel {
        let ring = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        ring.isReleasedWhenClosed = false
        ring.isOpaque = false
        ring.backgroundColor = .clear
        ring.hasShadow = false
        ring.ignoresMouseEvents = true
        ring.level = .statusBar
        ring.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let outline = NSBox()
        outline.boxType = .custom
        outline.titlePosition = .noTitle
        outline.borderWidth = 4
        outline.cornerRadius = 8
        outline.borderColor = .controlAccentColor
        outline.fillColor = .clear
        ring.contentView = outline
        return ring
    }

    // MARK: - Accessibility

    private static func frontmostPID() -> pid_t? {
        let system = AXUIElementCreateSystemWide()
        guard let front: AXUIElement = attribute(system, kAXFocusedApplicationAttribute) else { return nil }
        var pid: pid_t = 0
        return AXUIElementGetPid(front, &pid) == .success ? pid : nil
    }

    private static func focusedTerminalFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        guard let focused: AXUIElement = attribute(app, kAXFocusedUIElementAttribute),
              let role: String = attribute(focused, kAXRoleAttribute), role == terminalRole,
              var visible = frame(of: focused)
        else { return nil }
        // Terminal.app's text area holds the whole scrollback and runs far above the
        // window; what shows is the part inside its scroll area and window.
        var element = focused
        for _ in 0..<maxAncestors {
            guard let parent: AXUIElement = attribute(element, kAXParentAttribute),
                  let parentRole: String = attribute(parent, kAXRoleAttribute),
                  parentRole != kAXApplicationRole
            else { break }
            if let outer = frame(of: parent) { visible = visible.intersection(outer) }
            element = parent
        }
        guard !visible.isNull, visible.width >= minSide, visible.height >= minSide else { return nil }
        return visible
    }

    /// A real chain is a scroll area, a split or two and the window.
    private static let maxAncestors = 12

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position: AXValue = attribute(element, kAXPositionAttribute),
              let size: AXValue = attribute(element, kAXSizeAttribute)
        else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position, .cgPoint, &origin), AXValueGetValue(size, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}

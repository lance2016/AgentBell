import AppKit
import ApplicationServices
import BellCore

/// Fills the screen with the terminal window AgentBell just brought forward, when it does
/// not already, and the setting is on. Like the ring, it goes through the accessibility
/// API: no terminal's scripting can say how big a window is. Without that permission
/// nothing happens and nothing is asked.
@MainActor
enum TerminalFill {
    static let defaultsKey = "terminal.fillScreen"
    private static let poll: Duration = .milliseconds(100)
    private static let within: TimeInterval = 2

    static var isOn: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// Waits for the app to be in front with a window focused, then fills its screen.
    static func apply(pid: pid_t) async {
        guard isOn, AXIsProcessTrusted() else { return }
        let deadline = Date().addingTimeInterval(within)
        while Date() < deadline {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid, let window = focusedWindow(pid) {
                fill(window)
                return
            }
            try? await Task.sleep(for: poll)
        }
    }

    private static func fill(_ window: AXUIElement) {
        // A window in native full screen has a desktop of its own; leave it there.
        if let fullScreen: Bool = attribute(window, "AXFullScreen"), fullScreen { return }
        guard let position: CGPoint = point(window, kAXPositionAttribute),
              let size: CGSize = size(window, kAXSizeAttribute),
              let primary = NSScreen.screens.first,
              let target = WindowFill.target(window: CGRect(origin: position, size: size),
                                             visibleFrames: NSScreen.screens.map(\.visibleFrame),
                                             primaryHeight: primary.frame.height)
        else { return }
        // Moved first, then sized: a window may not grow past the screen's edge from
        // where it stands. Moved once more in case the system nudged it while sizing.
        set(window, kAXPositionAttribute, target.origin)
        set(window, kAXSizeAttribute, target.size)
        set(window, kAXPositionAttribute, target.origin)
    }

    private static func focusedWindow(_ pid: pid_t) -> AXUIElement? {
        attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
    }

    private static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }

    private static func point(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value: AXValue = attribute(element, name) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func size(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value: AXValue = attribute(element, name) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    private static func set(_ element: AXUIElement, _ name: String, _ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        AXUIElementSetAttributeValue(element, name as CFString, value)
    }

    private static func set(_ element: AXUIElement, _ name: String, _ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        AXUIElementSetAttributeValue(element, name as CFString, value)
    }
}

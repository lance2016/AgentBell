import AppKit
import BellCore
import Observation

/// The menu bar icon (UI_DESIGN.md §3). It never animates: "working" is a solid lamp.
@MainActor
final class StatusItemController: NSObject {
    var openSettings: (() -> Void)?

    private let store: SessionStore
    private let panel: PanelController
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    init(store: SessionStore, panel: PanelController) {
        self.store = store
        self.panel = panel
        super.init()
        guard let button = item.button else { return }
        button.target = self
        button.action = #selector(clicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.imagePosition = .imageLeft
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        // Looks pressed while the panel hangs from it, like a native menu bar item.
        // Set on the next turn: the button resets its highlight when click tracking ends.
        panel.onVisibilityChange = { [weak button] shown in
            Task { @MainActor in button?.highlight(shown) }
        }
        panel.defaultAnchor = { [weak self] in self?.buttonFrame() }
        observe()
    }

    /// Settings › 通用 can take the icon off the menu bar.
    func setVisible(_ visible: Bool) {
        guard item.isVisible != visible else { return }
        if !visible { panel.hide() }
        item.isVisible = visible
    }

    /// Re-renders whenever the sessions change.
    private func observe() {
        let status = withObservationTracking {
            PanelLayout.overallStatus(store.liveSessions)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        render(status)
    }

    private func render(_ status: OverallStatus) {
        guard let button = item.button else { return }
        button.image = MenuBarIcon.image(for: status)
        if case .waiting(let count) = status {
            button.title = "\(count)"
        } else {
            button.title = ""
        }
        button.setAccessibilityLabel(Copy.statusItemLabel(status))
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            panel.toggle { [weak self] in self?.buttonFrame() }
        }
    }

    private func buttonFrame() -> NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func showMenu() {
        panel.hide()
        let menu = NSMenu()
        menu.addItem(withTitle: "打开面板", action: #selector(openPanel), keyEquivalent: "").target = self
        menu.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        guard let button = item.button else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
    }

    @objc private func openPanel() {
        panel.show { [weak self] in self?.buttonFrame() }
    }

    @objc private func showSettings() {
        openSettings?()
    }
}

/// The clay terminal's screen, eyes, and antenna at menu bar scale.
/// The antenna tip doubles as the status lamp.
enum MenuBarIcon {
    static func image(for status: OverallStatus) -> NSImage {
        let size = NSSize(width: 17, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            let ink: NSColor
            let lamp: NSColor?
            switch status {
            case .idle: (ink, lamp) = (.black, nil)
            case .working: (ink, lamp) = (.black, .black)
            case .waiting: (ink, lamp) = (.labelColor, Palette.amberLamp)
            case .failed: (ink, lamp) = (.labelColor, .systemRed)
            }
            draw(ink: ink, lamp: lamp)
            return true
        }
        switch status {
        case .idle, .working: image.isTemplate = true
        case .waiting, .failed: image.isTemplate = false
        }
        return image
    }

    private static func draw(ink: NSColor, lamp: NSColor?) {
        ink.setStroke()
        let box = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 2, width: 14, height: 10), xRadius: 3, yRadius: 3)
        box.lineWidth = 1.5
        box.stroke()

        ink.setFill()
        for x in [5.5, 9.5] {
            NSBezierPath(ovalIn: NSRect(x: x, y: 5.5, width: 2, height: 3)).fill()
        }

        let antenna = NSBezierPath()
        antenna.move(to: NSPoint(x: 8.75, y: 12))
        antenna.line(to: NSPoint(x: 10.75, y: 14.5))
        antenna.lineWidth = 1.5
        antenna.lineCapStyle = .round
        antenna.stroke()

        let lampRect = NSRect(x: 9.75, y: 13.25, width: 4.5, height: 4.5)
        if let lamp {
            lamp.setFill()
            NSBezierPath(ovalIn: lampRect).fill()
        } else {
            let ring = NSBezierPath(ovalIn: lampRect.insetBy(dx: 0.6, dy: 0.6))
            ring.lineWidth = 1.2
            ring.stroke()
        }
    }
}

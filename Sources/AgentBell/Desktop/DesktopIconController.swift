import AppKit
import BellCore
import SwiftUI

/// The two ways into AgentBell. Both default to on, and Settings keeps at least one on.
enum Entry {
    static let menuBarKey = "entry.menuBar"
    static let desktopKey = "entry.desktop"
    static let desktopSizeKey = "entry.desktopSize"
    static let desktopSizeRange = 64...128
    static let defaultDesktopSize = 88

    static func desktopSize(_ value: Int) -> Int {
        min(max(value, desktopSizeRange.lowerBound), desktopSizeRange.upperBound)
    }

    static var desktopSize: Int {
        desktopSize(UserDefaults.standard.object(forKey: desktopSizeKey) as? Int ?? defaultDesktopSize)
    }

    static var menuBar: Bool { UserDefaults.standard.object(forKey: menuBarKey) as? Bool ?? true }
    static var desktop: Bool { UserDefaults.standard.object(forKey: desktopKey) as? Bool ?? true }
}

/// Never takes the keyboard: a click on the icon leaves the terminal focused.
private final class IconPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The terminal mascot floating on the desktop, with session status on its screen. Dragged
/// anywhere, it stays where it was left; a click opens the session window.
@MainActor
final class DesktopIconController: NSObject {
    var onClick: (() -> Void)?
    var openWindow: (() -> Void)?
    var openSettings: (() -> Void)?
    let bubbles: BubbleController

    private static let frameName = "DesktopIcon"
    private let panel: IconPanel
    private let mouse = IconMouseView()
    private let mascot = DesktopMascotState()
    private var positionReference = CGRect.zero
    private var celebration: Task<Void, Never>?
    private var previousRoundStates: [String: RoundState] = [:]
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?

    init(store: SessionStore) {
        let side = CGFloat(Entry.desktopSize)
        let size = NSSize(width: side, height: side)
        panel = IconPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.acceptsMouseMovedEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        bubbles = BubbleController(icon: panel)
        super.init()

        mascot.size = side
        let hosting = NSHostingView(rootView: DesktopIconView(state: mascot))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        mouse.frame = hosting.frame
        mouse.addSubview(hosting)
        mouse.onClick = { [weak self] in self?.onClick?() }
        mouse.onMoved = { [weak self] in self?.bubbles.reposition() }
        mouse.onDropped = { [weak self] in self?.rememberPosition() }
        mouse.onMenu = { [weak self] event in self?.showMenu(event) }
        mouse.onPointer = { [weak self] in self?.updateGaze() }
        mouse.onDragTilt = { [weak self] tilt in
            self?.mascot.dragTilt = tilt
            self?.updateGaze()
        }
        mouse.setAccessibilityElement(true)
        mouse.setAccessibilityRole(.button)
        panel.contentView = mouse
        placeAtStart(size: size)
        observe(store)
    }

    func setVisible(_ visible: Bool) {
        guard visible != panel.isVisible else { return }
        mascot.isVisible = visible
        if visible {
            panel.orderFrontRegardless()
            startPointerMonitoring()
            updatePresentation()
        } else {
            stopPointerMonitoring()
            mouse.resetDrag()
            mascot.dragTilt = nil
            mascot.gaze = .zero
            mascot.watchingPointer = false
            stopCelebration()
            panel.orderOut(nil)
        }
        bubbles.iconVisible = visible
    }

    func applyNotices(_ changes: Notices.Changes) {
        bubbles.apply(changes)
    }

    private func startCelebration() {
        stopCelebration()
        mascot.celebrating = true
        updatePresentation()
        celebration = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(1))
                self?.mascot.celebrating = false
                self?.celebration = nil
                self?.updatePresentation()
            } catch {
                // A new outcome replaced this one, or the icon was hidden.
            }
        }
    }

    private func stopCelebration() {
        celebration?.cancel()
        celebration = nil
        mascot.celebrating = false
    }

    private func startPointerMonitoring() {
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateGaze() }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            MainActor.assumeIsolated { self?.updateGaze() }
            return event
        }
    }

    private func stopPointerMonitoring() {
        if let globalPointerMonitor { NSEvent.removeMonitor(globalPointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        globalPointerMonitor = nil
        localPointerMonitor = nil
    }

    private func updateGaze() {
        guard mascot.isVisible else { return }
        let pointer = NSEvent.mouseLocation
        let canWatch = mascot.appearance == .idle && mascot.dragTilt == nil
        let gaze = canWatch ? DesktopPlacement.mascotGaze(pointer: pointer, icon: panel.frame) : .zero
        let watching = canWatch && (gaze != .zero || panel.frame.contains(pointer))
        if watching != mascot.watchingPointer { mascot.watchingPointer = watching }
        if gaze != mascot.gaze { mascot.gaze = gaze }
    }

    func applySize(_ points: Int) {
        let side = CGFloat(points)
        guard side != mascot.size else { return }
        let size = NSSize(width: side, height: side)
        let frame = panel.frame
        let screen = panel.screen ?? NSScreen.screens.first { $0.visibleFrame.intersects(frame) } ?? NSScreen.main
        mascot.size = side
        // Use the last explicitly placed frame for each slider tick so resizing cannot drift.
        let updated = screen.map { DesktopPlacement.resizedIcon(positionReference, to: size, visible: $0.visibleFrame) }
            ?? NSRect(origin: frame.origin, size: size)
        panel.setFrame(updated, display: panel.isVisible)
        bubbles.reposition()
        updateGaze()
    }

    /// Restore the saved position while taking the current size from settings.
    private func placeAtStart(size: NSSize) {
        if panel.setFrameUsingName(Self.frameName),
           let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(CGPoint(x: panel.frame.midX, y: panel.frame.midY)) })
                ?? NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) {
            positionReference = panel.frame
            panel.setFrame(DesktopPlacement.resizedIcon(positionReference, to: size, visible: screen.visibleFrame), display: false)
            return
        }
        let origin = NSScreen.main.map { DesktopPlacement.defaultOrigin(size: size, visible: $0.visibleFrame) }
            ?? panel.frame.origin
        positionReference = NSRect(origin: origin, size: size)
        panel.setFrame(positionReference, display: false)
    }

    private func rememberPosition() {
        positionReference = panel.frame
        panel.saveFrame(usingName: Self.frameName)
    }

    /// Keep the screen, tooltip and accessibility label on the same status.
    private func observe(_ store: SessionStore) {
        let sessions = withObservationTracking {
            store.liveSessions
        } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                self.observe(store)
            }
        }
        updateStatus(PanelLayout.overallStatus(sessions))
        // A restored completed session has no previously observed state. Flash only
        // for a live transition, independent of notification duration and preferences.
        if mascot.isVisible, !mascot.needsAttention, sessions.contains(where: { session in
            session.state == .completed && previousRoundStates[session.id].map { $0 != .completed } == true
        }) {
            startCelebration()
        }
        previousRoundStates = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
    }

    private func updateStatus(_ status: OverallStatus) {
        mascot.status = status
        if mascot.needsAttention { stopCelebration() }
        updatePresentation()
    }

    private func updatePresentation() {
        updateGaze()
        let label = mascot.appearance == .completed ? "刚完成一轮任务" : Copy.statusItemLabel(mascot.status)
        mouse.toolTip = label
        mouse.setAccessibilityLabel(label)
    }

    private func showMenu(_ event: NSEvent) {
        let menu = NSMenu()
        menu.addItem(withTitle: "打开会话窗口", action: #selector(openWindowItem), keyEquivalent: "").target = self
        menu.addItem(withTitle: "桌面设置…", action: #selector(openSettingsItem), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let hide = menu.addItem(withTitle: "隐藏桌面图标", action: #selector(hideIcon), keyEquivalent: "")
        hide.target = self
        // The menu bar icon is then the only way back in; without it, nothing would be.
        if !Entry.menuBar { hide.action = nil }
        menu.addItem(withTitle: "退出 AgentBell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: mouse)
    }

    @objc private func openWindowItem() { openWindow?() }
    @objc private func openSettingsItem() { openSettings?() }
    @objc private func hideIcon() { UserDefaults.standard.set(false, forKey: Entry.desktopKey) }
}

/// Takes every mouse event over the icon: a press that moves drags the panel, one that
/// does not is a click.
private final class IconMouseView: NSView {
    var onClick: (() -> Void)?
    var onMoved: (() -> Void)?
    var onDropped: (() -> Void)?
    var onMenu: ((NSEvent) -> Void)?
    var onPointer: (() -> Void)?
    var onDragTilt: ((Double?) -> Void)?
    private var pointerTracking: NSTrackingArea?

    private var pressedAt: NSPoint?
    private var originAtPress: NSPoint?
    private var dragging = false

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        guard let onClick else { return false }
        onClick()
        return true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let tracking = NSTrackingArea(rect: .zero,
                                      options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .inVisibleRect],
                                      owner: self, userInfo: nil)
        addTrackingArea(tracking)
        pointerTracking = tracking
    }

    override func mouseEntered(with event: NSEvent) { onPointer?() }
    override func mouseExited(with event: NSEvent) { onPointer?() }

    override func mouseDown(with event: NSEvent) {
        pressedAt = NSEvent.mouseLocation
        originAtPress = window?.frame.origin
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressedAt, let originAtPress, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - pressedAt.x
        let dy = now.y - pressedAt.y
        // A hand that shakes a little while clicking is still clicking.
        if !dragging && hypot(dx, dy) < 4 { return }
        dragging = true
        let origin = NSPoint(x: originAtPress.x + dx, y: originAtPress.y + dy)
        let horizontalStep = origin.x - window.frame.minX
        onDragTilt?(Double(min(5, max(-5, horizontalStep * 0.9))))
        window.setFrameOrigin(origin)
        onMoved?()
    }

    override func mouseUp(with event: NSEvent) {
        let didDrag = dragging
        let wasPressed = pressedAt != nil
        resetDrag()
        if didDrag {
            onDropped?()
            onDragTilt?(nil)
        } else if wasPressed {
            onClick?()
        }
    }

    func resetDrag() {
        pressedAt = nil
        originAtPress = nil
        dragging = false
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?(event)
    }
}

private struct DesktopIconView: View {
    let state: DesktopMascotState

    private var size: CGFloat { state.size }

    var body: some View {
        if let artwork = DesktopMascotArtwork.bundled {
            DesktopMascotView(state: state, artwork: artwork, size: size)
        } else {
            fallbackIcon
        }
    }

    /// The standard app icon covers bare Swift builds and incomplete bundles.
    private var fallbackIcon: some View {
        ZStack(alignment: .topTrailing) {
            BellAppIcon(size: size * 0.82)
                .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                .frame(width: size, height: size)
            badge(state.status)
        }
        .frame(width: size, height: size)
    }

    @ViewBuilder private func badge(_ status: OverallStatus) -> some View {
        switch status {
        case .idle:
            EmptyView()
        case .working:
            Image(systemName: "waveform")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.blueLamp)
                .padding(4)
                .background(Circle().fill(.white))
                .padding(4)
        case .waiting(let count):
            Text("\(count)")
                .font(.system(size: 11, weight: .bold).monospacedDigit())
                .foregroundStyle(.black)
                .padding(.horizontal, 5)
                .frame(minWidth: 19, minHeight: 19)
                .background(Capsule().fill(Color.amberLamp))
                .overlay(Capsule().stroke(.white, lineWidth: 1.5))
                .padding(2)
        case .failed:
            Image(systemName: "exclamationmark")
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(Circle().fill(Color.bellRed))
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .padding(2)
        }
    }
}

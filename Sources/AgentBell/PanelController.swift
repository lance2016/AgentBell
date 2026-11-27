import AppKit
import BellCore
import SwiftUI

/// A borderless panel that can take keyboard focus without activating the app, and
/// shows above full-screen apps.
private final class BellPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct KeyPress: Sendable {
    let windowNumber: Int
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags
    var command: Bool { modifiers.contains(.command) }
    let characters: String?
}

/// Shows the session panel, either hanging from the status item or in a window of its
/// own. `MenuBarExtra` is not used: it cannot be opened from code and cannot float above
/// full-screen apps.
@MainActor
final class PanelController {
    enum Presentation {
        /// Under the status item; goes away on a click elsewhere, Esc, or a jump.
        case popover
        /// A regular window: moved, resized and closed by the user, and left open after
        /// a jump back to a terminal.
        case window
    }

    /// The status item looks pressed while its popover is open; the window shows the
    /// Dock icon while it is open.
    var onVisibilityChange: ((Bool) -> Void)?
    var openSettings: (() -> Void)?
    var openReview: (() -> Void)?
    /// Where the panel hangs from when it opens without a click on the status item.
    var defaultAnchor: (() -> NSRect?)?

    let presentation: Presentation
    private let store: SessionStore
    private let state = PanelState()
    private let panel: NSWindow
    private let shape: PanelShapeView
    private var anchor: (() -> NSRect?)?
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var jumpTask: Task<Void, Never>?
    private var launchTask: Task<Void, Never>?

    var isShown: Bool { panel.isVisible }

    init(store: SessionStore, presentation: Presentation) {
        self.store = store
        self.presentation = presentation
        switch presentation {
        case .popover:
            shape = PanelShapeView(arrow: true)
            panel = Self.makePopover()
        case .window:
            shape = PanelShapeView(arrow: false)
            panel = Self.makeWindow()
        }
        panel.contentView = makeContent()

        switch presentation {
        case .popover:
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hide()
                }
            }
        case .window:
            // The close button, ⌘W and the Window menu all close it this way.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: panel, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.didHide() }
            }
        }
    }

    private static func makePopover() -> NSWindow {
        let panel = BellPanel(
            contentRect: NSRect(x: 0, y: 0, width: BellLayout.width(for: .list), height: BellLayout.height + PanelShapeView.arrowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// The panel draws under a transparent title bar: the sidebar runs to the top behind
    /// the traffic lights, and the content pane's header shares their row. No toolbar:
    /// it would cover the SwiftUI header underneath it.
    private static func makeWindow() -> NSWindow {
        // Roomier than the popover: wide enough beside the sidebar for the detail's two
        // columns. The user's own size wins once saved.
        let width: CGFloat = PanelStyle.current == .sidebar ? 840 : 480
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.title = "AgentBell"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: BellLayout.width(for: .list), height: 420)
        window.center()
        // Restores the size and place the user left it at, if any.
        // Renamed with the larger default, so a size saved for the old layout is not kept.
        window.setFrameAutosaveName("SessionWindow.v2")
        return window
    }

    // MARK: - Show / hide

    /// - Parameter anchor: the status button's frame in screen coordinates.
    func toggle(anchor: (() -> NSRect?)? = nil) {
        isShown ? hide() : show(anchor: anchor)
    }

    /// - Parameter anchor: where the popover hangs from; the window ignores it.
    func show(anchor: (() -> NSRect?)? = nil) {
        let wasShown = isShown
        if !wasShown {
            state.resetSelection(store)
            state.isVisible = true
            store.panelDidShow()
            // Before activating: the window turns the Dock icon on, and only an app that
            // has one gets the menu bar when it comes forward.
            onVisibilityChange?(true)
        }
        if presentation == .popover {
            self.anchor = anchor
            reposition()
        }
        // Become the active app while the panel is open, as native menu bar panels do.
        // Without it, controls in the panel lose their click to the app in front, and
        // macOS 14 lets only the active app hand activation over to the terminal.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        if !wasShown {
            // The sidebar's search field would take the keyboard as the window comes up,
            // and the arrow keys with it. It gets focus on a click or ⌘F instead.
            panel.makeFirstResponder(nil)
            installMonitors()
        }
    }

    /// The desktop icon: brings the window forward, or closes it when it already is.
    func toggleFromIcon() {
        if isShown && panel.isKeyWindow && NSApp.isActive {
            panel.performClose(nil)
        } else {
            show()
        }
    }

    /// A notification or bubble was clicked: back to that session's terminal. When the
    /// session is gone, the panel opens instead.
    func open(sessionID: String) {
        guard let session = store.tracker.live[sessionID] else {
            if !isShown { showUnprompted() }
            if store.tracker.recent.contains(where: { $0.id == sessionID }) {
                state.detailID = sessionID
            }
            return
        }
        activate(session)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        didHide()
    }

    private func didHide() {
        state.isVisible = false
        store.panelDidHide()
        removeMonitors()
        onVisibilityChange?(false)
        guard presentation == .popover else { return }
        // The panel activated the app; hand the keyboard back to whatever was in front
        // before, unless the settings window is still open.
        let otherWindowOpen = NSApp.windows.contains { $0 !== panel && $0.isVisible && $0.canBecomeMain }
        if NSApp.isActive && !otherWindowOpen {
            NSApp.hide(nil)
        }
    }

    /// The popover gets out of the way of what comes next; the window stays.
    private func dismiss() {
        if presentation == .popover { hide() }
    }

    /// The open-panel shortcut: shows it, or puts it away when it is already in front.
    func toggleUnprompted() {
        switch presentation {
        case .window: toggleFromIcon()
        case .popover: isShown ? hide() : showUnprompted()
        }
    }

    /// Opened by something other than a click on the status item.
    func showUnprompted() {
        switch presentation {
        case .window: show()
        case .popover: if let defaultAnchor { show(anchor: defaultAnchor) }
        }
    }

    /// Keep the popover anchored to the status item without resizing on navigation; the
    /// width follows the layout picked in Settings.
    private func reposition() {
        guard let button = anchor?(),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(button.origin) }) ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        let width = min(BellLayout.width(for: PanelStyle.current), visible.width - 16)
        let top = button.minY - 2
        let height = min(BellLayout.height + PanelShapeView.arrowHeight, top - visible.minY - 8)
        let x = min(max(button.midX - width / 2, visible.minX + 8), visible.maxX - width - 8)
        shape.arrowX = button.midX - x
        panel.setFrame(NSRect(x: x, y: top - height, width: width, height: height), display: true)
        panel.invalidateShadow()
    }

    // MARK: - Content

    private func makeContent() -> NSView {
        let actions = PanelActions(
            activate: { [weak self] in self?.activate($0) },
            copyResume: { [weak self] in self?.copyResume($0, message: "已复制恢复命令") },
            reveal: { [weak self] in self?.revealDirectory($0.cwd) },
            revealProject: { [weak self] in self?.revealDirectory($0) },
            launchInProject: { [weak self] in self?.launchClaude(project: $0) },
            launchInFolder: { [weak self] in self?.launchClaude(project: nil) },
            openReview: { [weak self] in
                self?.openReview?()
                self?.dismiss()
            },
            chooseClaude: { [weak self] in
                guard let self else { return }
                self.dismiss()
                ClaudePicker.choose(store: self.store)
            },
            refreshSessions: { [weak self] in self?.store.pollNow() },
            openTerminalApp: { [weak self] in self?.openTerminalApp(for: $0) },
            connectHooks: { [weak self] in self?.store.hooks.connect() },
            explainHooks: { [weak self] in self?.explainHooks() },
            openSettings: { [weak self] in
                // Settings first: with a window up, hiding the panel keeps the app active.
                self?.openSettings?()
                self?.dismiss()
            },
            quit: { NSApp.terminate(nil) },
            tasks: TaskActions(
                newTask: { [weak self] session in
                    guard let self else { return }
                    let task = self.store.tasks.add(from: session)
                    self.state.openTask(task.id, focusTitle: true)
                },
                link: { [weak self] session, id in
                    guard let self else { return }
                    self.store.tasks.link(session, to: id)
                    let title = self.store.tasks.task(id)?.title ?? ""
                    self.state.showFeedback("已加入任务「\(title)」", for: session.id)
                },
                open: { [weak self] in self?.state.openTask($0) },
                activate: { [weak self] in self?.activate($0) },
                resume: { [weak self] in self?.resume($0) },
                reveal: { [weak self] in self?.revealDirectory($0) }
            )
        )
        let root = PanelView(store: store, state: state, actions: actions, inWindow: presentation == .window)
        shape.install(FirstClickHostingView(rootView: root))
        return shape
    }

    // MARK: - Actions

    private func launchClaude(project: String?) {
        guard launchTask == nil else { return }
        launchTask = Task {
            defer { launchTask = nil }
            guard case .ready(let executable) = store.claude,
                  FileManager.default.isExecutableFile(atPath: executable.path)
            else {
                launchAlert("请在 AgentBell 设置中选择可用的 Claude Code 可执行文件。")
                return
            }

            let directory: String?
            if let project {
                let checkouts = await ProjectCheckout.list(root: project)
                guard isShown else { return }
                guard !checkouts.isEmpty else {
                    launchAlert("找不到项目目录。可以从「新建会话」菜单重新选择文件夹。")
                    return
                }
                directory = checkouts.count == 1 ? checkouts[0].path : chooseCheckout(checkouts)
            } else {
                directory = chooseLaunchFolder()
            }
            guard let directory else { return }
            await launchClaude(executable: executable, directory: directory)
        }
    }

    private func resume(_ workspace: TaskWorkspace) {
        if let live = store.tracker.live[workspace.sessionID] {
            activate(live)
            return
        }
        guard launchTask == nil else { return }
        launchTask = Task {
            defer { launchTask = nil }
            guard case .ready(let executable) = store.claude,
                  FileManager.default.isExecutableFile(atPath: executable.path) else {
                launchAlert("请在 AgentBell 设置中选择可用的 Claude Code 可执行文件。")
                return
            }

            let original = ProjectInfo.lookup(cwd: workspace.cwd)
            var directory = workspace.cwd
            if !Self.isDirectory(directory) || original.root != workspace.projectRoot || original.branch != workspace.branch {
                let checkouts = await ProjectCheckout.list(root: workspace.projectRoot)
                    .sorted { ($0.branch == workspace.branch ? 0 : 1) < ($1.branch == workspace.branch ? 0 : 1) }
                guard isShown else { return }
                let reason = "原工作目录已移除，或当前分支与保存时不同。请选择恢复会话的目录。AgentBell 不会切换分支。"
                if checkouts.isEmpty {
                    let alert = NSAlert()
                    alert.messageText = "选择恢复目录"
                    alert.informativeText = reason
                    alert.addButton(withTitle: "选择文件夹…")
                    alert.addButton(withTitle: "取消")
                    dismiss()
                    NSApp.activate()
                    guard alert.runModal() == .alertFirstButtonReturn,
                          let selected = chooseLaunchFolder(prompt: "恢复会话") else { return }
                    directory = selected
                } else {
                    guard let selected = chooseCheckout(
                        checkouts, title: "继续工作", message: reason, button: "恢复会话"
                    ) else { return }
                    directory = selected
                }
            }
            if let live = store.tracker.live[workspace.sessionID] {
                activate(live)
                return
            }
            await launchClaude(executable: executable, directory: directory, resumeSessionID: workspace.sessionID)
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }

    private func launchClaude(executable: URL, directory: String, resumeSessionID: String? = nil) async {
        guard Self.isDirectory(directory) else {
            launchAlert("选定的工作目录已移除，请重新选择。")
            return
        }
        do {
            try await TerminalJumper.launchClaude(
                in: .current, executable: executable, directory: directory, resumeSessionID: resumeSessionID
            ) { dismiss() }
            dismiss()
            store.pollNow()
            // The terminal can open before Claude registers with its session list.
            Task { [store] in
                try? await Task.sleep(for: .seconds(2))
                store.pollNow()
            }
        } catch {
            launchAlert(error.localizedDescription)
        }
    }

    private func chooseCheckout(
        _ checkouts: [ProjectCheckout],
        title: String = "新建会话",
        message: String = "选择已有的工作目录。会话将在该目录中的分支上启动。",
        button: String = "打开 Claude"
    ) -> String? {
        let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 400, height: 28))
        for checkout in checkouts {
            let path = (checkout.path as NSString).abbreviatingWithTildeInPath
            let title = checkout.branch.map { "\($0)  ·  \(path)" } ?? path
            picker.addItem(withTitle: title)
            picker.lastItem?.toolTip = checkout.path
        }
        picker.selectItem(at: 0)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.accessoryView = picker
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: "取消")
        dismiss()
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn,
              checkouts.indices.contains(picker.indexOfSelectedItem) else { return nil }
        return checkouts[picker.indexOfSelectedItem].path
    }

    private func chooseLaunchFolder(prompt: String = "打开 Claude") -> String? {
        dismiss()
        let picker = NSOpenPanel()
        picker.title = "选择 Claude 会话的工作目录"
        picker.prompt = prompt
        picker.canChooseFiles = false
        picker.canChooseDirectories = true
        picker.allowsMultipleSelection = false
        NSApp.activate()
        return picker.runModal() == .OK ? picker.url?.path : nil
    }

    private func launchAlert(_ message: String) {
        dismiss()
        let alert = NSAlert()
        alert.messageText = "无法启动 Claude Code"
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }

    /// Back to the session's terminal. An ended session has none, so its row copies
    /// `claude --resume <id>` instead.
    private func activate(_ session: Session) {
        guard !session.isEnded else {
            copyResume(session, message: "已复制恢复命令")
            return
        }
        guard jumpTask == nil else { return }
        state.terminalFallback = nil
        jumpTask = Task { [weak self] in
            let outcome = await TerminalJumper.jump(to: session) { self?.dismiss() }
            guard let self else { return }
            self.jumpTask = nil
            switch outcome {
            case .focusedTerminal:
                self.dismiss()
            case .appOnly(let pid):
                self.showTerminalFallback(for: session, pid: pid)
            case .notFound:
                self.showTerminalFallback(for: session, pid: nil)
            }
        }
    }

    private func showTerminalFallback(for session: Session, pid: pid_t?) {
        if !isShown { showUnprompted() }
        state.selectedID = session.id
        state.detailID = session.id
        state.terminalFallback = (session.id, pid)
    }

    private func openTerminalApp(for session: Session) {
        guard let fallback = state.terminalFallback, fallback.sessionID == session.id, let pid = fallback.pid else { return }
        if TerminalJumper.openTerminalApp(pid: pid) {
            dismiss()
        } else {
            showTerminalFallback(for: session, pid: nil)
        }
    }

    private func copyResume(_ session: Session, message: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(session.resumeCommand, forType: .string)
        state.showFeedback(message, for: session.id)
    }

    private func explainHooks() {
        dismiss()
        let alert = NSAlert()
        alert.messageText = "连接 Claude Code 会改动什么"
        alert.informativeText = HookController.changesExplained
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }

    private func revealDirectory(_ path: String) {
        dismiss()
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    // MARK: - Event monitors

    private func installMonitors() {
        removeMonitors()
        // Clicks in other apps close the popover. Clicks on our own status item are
        // handled by its toggle.
        if presentation == .popover {
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.hide()
                }
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // NSEvent is not Sendable; hand only plain values to the main actor.
            let key = KeyPress(
                windowNumber: event.windowNumber,
                keyCode: event.keyCode,
                modifiers: event.modifierFlags.intersection([.command, .shift, .option, .control]),
                characters: event.charactersIgnoringModifiers
            )
            let handled = MainActor.assumeIsolated {
                guard let self, key.windowNumber == self.panel.windowNumber else { return false }
                return self.handleKey(key)
            }
            return handled ? nil : event
        }
    }

    private func removeMonitors() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
    }

    /// UI_DESIGN.md §4.7.
    private func handleKey(_ key: KeyPress) -> Bool {
        let inDetail = state.detailSession(store) != nil
        let editor = panel.firstResponder as? NSTextView
        let editingText = editor?.isFieldEditor == true
        if key.keyCode == 53 && (!key.modifiers.isEmpty || editor?.hasMarkedText() == true) { return false }
        let listNavigation = !inDetail && !editingText && key.modifiers.isEmpty
        let sidebar = PanelStyle.current == .sidebar && !state.searchVisible && !state.needsAttentionOnly
            && !state.tasksVisible && listNavigation
        switch (key.keyCode, key.command, key.characters) {
        case (125, false, _) where listNavigation: state.moveSelection(by: 1, store)
        case (126, false, _) where listNavigation: state.moveSelection(by: -1, store)
        case (123, false, _) where sidebar: state.moveProject(by: -1, store)
        case (124, false, _) where sidebar: state.moveProject(by: 1, store)
        // Esc leaves the detail first, then puts the popover away. A window stays: it
        // closes as windows do, with ⌘W.
        case (53, _, _) where state.renamingID != nil: state.renamingID = nil
        case (53, _, _) where state.detailID != nil: state.detailID = nil
        case (53, _, _) where state.addingTask: state.addingTask = false
        case (53, _, _) where state.tasksVisible && state.tasksNarrow && state.taskID != nil: state.taskID = nil
        case (53, _, _) where state.tasksVisible: state.showTasks(false)
        case (53, _, _) where state.searchVisible: state.closeSearch()
        case (53, _, _) where state.needsAttentionOnly: state.showAttention(false, store)
        case (53, _, _) where presentation == .popover: hide()
        case (_, true, "f") where !inDetail && !state.tasksVisible && key.modifiers == .command:
            guard state.canBrowse(store) else { return false }
            state.showSearch()
        // With text focused (the search field, or selected words of the conversation),
        // ⌘C copies that text, not the resume command.
        case (_, true, "c") where editor == nil && key.modifiers == .command:
            (state.detailSession(store) ?? selectedSession()).map {
                copyResume($0, message: "已复制恢复命令")
            }
        case (_, true, "i") where !inDetail && !editingText && key.modifiers == .command: state.detailID = selectedSession()?.id
        case (_, true, ","):
            openSettings?()
            dismiss()
        case (_, true, "q"): NSApp.terminate(nil)
        default: return false
        }
        return true
    }

    private func selectedSession() -> Session? {
        state.selectableSessions(store).first { $0.id == state.selectedID }
    }
}

/// The popover body: rounded rect plus an arrow pointing at the status item, filled
/// with the system sidebar material and a faint wash of the content background. The
/// sidebar shows the material through; the content pane lays its own lighter fill on top.
private final class PanelShapeView: NSView {
    static let arrowHeight: CGFloat = 8
    private static let arrowWidth: CGFloat = 18
    private static let radius: CGFloat = 17

    /// Arrow tip, in this view's coordinates.
    var arrowX: CGFloat = BellLayout.width(for: .list) / 2 {
        didSet { needsLayout = true }
    }

    /// Without the arrow, the view fills a regular window, which rounds its own corners.
    private let arrow: Bool
    private let material = NSVisualEffectView()
    private let wash = WashView()
    private let mask = CAShapeLayer()
    private var hosting: NSView?

    init(arrow: Bool) {
        self.arrow = arrow
        super.init(frame: .zero)
        wantsLayer = true
        if arrow { layer?.mask = mask }
        material.material = .sidebar
        // A popover is always in front; a window dims its sidebar when inactive, as
        // system windows do.
        material.state = arrow ? .active : .followsWindowActiveState
        material.blendingMode = .behindWindow
        addSubview(material)
        // The popover's faint wash would cloud a window sidebar's translucency.
        if arrow { addSubview(wash) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func install(_ content: NSView) {
        hosting = content
        addSubview(content)
    }

    override func layout() {
        super.layout()
        material.frame = bounds
        wash.frame = bounds
        hosting?.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - (arrow ? Self.arrowHeight : 0))
        guard arrow else { return }
        mask.frame = bounds
        mask.path = path(in: bounds)
    }

    private func path(in rect: NSRect) -> CGPath {
        let body = NSRect(x: 0, y: 0, width: rect.width, height: rect.height - Self.arrowHeight)
        let path = CGMutablePath()
        path.addRoundedRect(in: body, cornerWidth: Self.radius, cornerHeight: Self.radius)
        let half = Self.arrowWidth / 2
        let tip = min(max(arrowX, Self.radius + half), rect.width - Self.radius - half)
        let base = body.maxY
        path.move(to: CGPoint(x: tip - half, y: base))
        path.addCurve(
            to: CGPoint(x: tip, y: rect.maxY),
            control1: CGPoint(x: tip - half / 2, y: base),
            control2: CGPoint(x: tip - 2, y: rect.maxY)
        )
        path.addCurve(
            to: CGPoint(x: tip + half, y: base),
            control1: CGPoint(x: tip + 2, y: rect.maxY),
            control2: CGPoint(x: tip + half / 2, y: base)
        )
        path.closeSubpath()
        return path
    }
}

/// Re-resolves its color whenever the appearance changes (light, dark, high contrast).
private final class WashView: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateLayer() {
        var color = NSColor.clear
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.controlBackgroundColor.withAlphaComponent(0.25)
        }
        layer?.backgroundColor = color.cgColor
    }
}

/// A click on the panel acts at once, even when the panel is not key yet: it is a
/// menu-like surface, not a document window that a first click should only bring forward.
final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

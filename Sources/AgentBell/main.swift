import AppKit
import BellCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = SessionStore()
    private var panel: PanelController?
    private var window: PanelController?
    private var statusItem: StatusItemController?
    private var desktop: DesktopIconController?
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let running = Self.otherCopy() {
            handOver(to: running)
            return
        }
        installMainMenu()
        let settings = SettingsWindowController(store: store)
        let panel = PanelController(store: store, presentation: .popover)
        let window = PanelController(store: store, presentation: .window)
        panel.openSettings = { settings.show() }
        window.openSettings = { settings.show() }
        // In the Dock and the app switcher while the window is open, as a regular app.
        window.onVisibilityChange = { shown in
            NSApp.setActivationPolicy(shown ? .regular : .accessory)
        }
        let statusItem = StatusItemController(store: store, panel: panel)
        statusItem.openSettings = { settings.show() }

        let desktop = DesktopIconController(store: store)
        desktop.onClick = { [weak window] in window?.toggleFromIcon() }
        desktop.openWindow = { [weak window] in window?.show() }
        desktop.openSettings = { settings.showDesktop() }
        desktop.bubbles.onOpen = { [weak window] id in window?.open(sessionID: id) }
        store.notifier.onChanges = { [weak desktop] changes in desktop?.applyNotices(changes) }
        // A notification for a session that has ended opens the panel instead; the
        // window when the menu bar icon is off.
        store.notifier.onOpen = { [weak panel, weak window] id in
            (Entry.menuBar ? panel : window)?.open(sessionID: id)
        }

        self.settings = settings
        self.panel = panel
        self.window = window
        self.statusItem = statusItem
        self.desktop = desktop
        applyEntries()
        GlobalHotKeys.shared.onPress = { [weak self] in self?.perform($0) }
        GlobalHotKeys.shared.apply()
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyEntries()
                GlobalHotKeys.shared.apply()
            }
        }
        store.start()
        Task { await store.updates.check() }
    }

    /// Another copy already running, such as `/Applications` next to `build/`. Two would
    /// compete for the hook socket and post every notification twice.
    private static func otherCopy() -> NSRunningApplication? {
        guard let id = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .first { $0 != .current && !$0.isTerminated }
    }

    /// The copy already running stays: it is reopened, which shows its window, and this
    /// one quits. `open -a` sends the reopen; `NSWorkspace.openApplication` only
    /// activates a running app, which shows nothing for a menu bar app.
    private func handOver(to running: NSRunningApplication) {
        guard let url = running.bundleURL else {
            NSApp.terminate(nil)
            return
        }
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        reopen.arguments = ["-a", url.path]
        reopen.terminationHandler = { _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        do {
            try reopen.run()
        } catch {
            NSApp.terminate(nil)
        }
    }

    /// Shows the ways in that Settings has on. Settings keeps one of them on; should both
    /// be off anyway, the menu bar icon stays.
    private func applyEntries() {
        let desktopOn = Entry.desktop
        statusItem?.setVisible(Entry.menuBar || !desktopOn)
        desktop?.applySize(Entry.desktopSize)
        desktop?.setVisible(desktopOn)
        desktop?.bubbles.enabled = Notifier.isOn(Notifier.Key.bubble)
    }

    /// The global shortcuts. The menu bar panel, or the window when the icon is off, as
    /// a notification opens.
    private func perform(_ shortcut: Shortcut) {
        guard let target = Entry.menuBar ? panel : window else { return }
        switch shortcut {
        case .openPanel:
            target.toggleUnprompted()
        case .jumpToWaiting:
            if let session = PanelLayout.nextAttention(store.liveSessions) {
                target.open(sessionID: session.id)
            } else {
                target.showUnprompted()
            }
        }
    }

    /// A click on the Dock icon, or opening the app again from Finder.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        window?.show()
        return false
    }

    /// Releases the socket, so the next launch finds no stale file, and writes the state
    /// still waiting to be saved.
    func applicationWillTerminate(_ notification: Notification) {
        store.hooks.stop()
        store.saveNow()
    }

    /// Quitting AgentBell never touches a Claude session.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Shown while the session window puts AgentBell in the Dock. The Edit menu also
    /// gives text fields their ⌘C, ⌘V and ⌘A; ⌘W and ⌘M come from the Window menu.
    private func installMainMenu() {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: "设置…", action: #selector(showSettings), keyEquivalent: ",").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "隐藏 AgentBell", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "退出 AgentBell", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: app, title: "AgentBell")

        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: "编辑")

        let windows = NSMenu(title: "窗口")
        windows.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windows.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(submenu: windows, title: "窗口")
        NSApp.windowsMenu = windows

        NSApp.mainMenu = main
    }

    @objc private func showSettings() {
        settings?.show()
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Menu bar only until the session window opens: no Dock icon even when run outside
    // the bundle.
    app.setActivationPolicy(.accessory)
    app.run()
}

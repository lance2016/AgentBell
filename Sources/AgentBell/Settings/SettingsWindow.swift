import AppKit
import BellCore
import os
import ServiceManagement
import SwiftUI

/// Settings that are not session data. Re-read every time the window comes forward,
/// since the user may have changed them in System Settings meanwhile.
@MainActor
@Observable
final class SettingsModel {
    private(set) var launchAtLogin = false
    private(set) var launchNeedsApproval = false
    private(set) var installedTerminals: Set<TerminalApp> = []
    /// Installed but too old for AgentBell's scripts, with the version found.
    private(set) var outdatedTerminals: [TerminalApp: String] = [:]
    private(set) var automation: [TerminalApp: AutomationPermission] = [:]
    private(set) var accessibilityAllowed = false

    @ObservationIgnored private let log = Logger(subsystem: "com.agentbell.AgentBell", category: "settings")

    func refresh() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        launchNeedsApproval = status == .requiresApproval
        installedTerminals = Set(TerminalApp.allCases.filter(\.isInstalled))
        outdatedTerminals = Dictionary(uniqueKeysWithValues: installedTerminals.compactMap { app in
            app.outdatedVersion.map { (app, $0) }
        })
        automation = Dictionary(uniqueKeysWithValues: installedTerminals.map { ($0, AutomationPermission.of($0)) })
        accessibilityAllowed = TerminalHighlight.isAllowed
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("launch at login change failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }
}

/// The standard macOS settings window: a toolbar of tabs, the title following the tab,
/// and the height following each page, so no page scrolls or trails empty space.
@MainActor
final class SettingsWindowController {
    private let model = SettingsModel()
    private let tabs = NSTabViewController()
    private lazy var window: NSWindow = makeWindow()
    private let store: SessionStore

    init(store: SessionStore) {
        self.store = store
    }

    func show() {
        present()
    }

    func showDesktop() {
        present(tab: .desktop)
    }

    func showReview() {
        present(tab: .review)
    }

    func showWeekly() {
        present(tab: .weekly)
    }

    private func present(tab: SettingsTab? = nil) {
        refresh()
        let window = self.window
        if let tab, let index = SettingsTab.allCases.firstIndex(of: tab) {
            tabs.selectedTabViewItemIndex = index
        }
        NSApp.activate()
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    /// The user may have changed permissions in System Settings meanwhile.
    private func refresh() {
        model.refresh()
        store.hooks.refresh()
        Task { await store.notifier.refresh() }
    }

    private func makeWindow() -> NSWindow {
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        for tab in SettingsTab.allCases {
            let page = NSHostingController(rootView: SettingsPage(tab: tab, model: model, store: store))
            page.sizingOptions = [.preferredContentSize]
            page.title = tab.title
            let item = NSTabViewItem(viewController: page)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        return window
    }
}

/// One tab's page, as tall as its content (UI_DESIGN.md §6: no page scrolls).
private struct SettingsPage: View {
    let tab: SettingsTab
    let model: SettingsModel
    let store: SessionStore

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralSettings(model: model, store: store)
            case .desktop: DesktopSettings()
            case .notifications: NotificationSettings()
            case .permissions: PermissionSettings(model: model, store: store)
            case .review: ReviewSettings(store: store)
            case .weekly: WeeklySettings()
            case .about: AboutSettings(model: model, store: store)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private enum SettingsTab: CaseIterable, Identifiable {
    case general, desktop, notifications, permissions, review, weekly, about

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "通用"
        case .desktop: "桌面"
        case .notifications: "通知"
        case .permissions: "权限"
        case .review: "审查"
        case .weekly: "周报"
        case .about: "关于"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .desktop: "desktopcomputer"
        case .notifications: "bell"
        case .permissions: "lock"
        case .review: "text.magnifyingglass"
        case .weekly: "calendar"
        case .about: "info.circle"
        }
    }
}

struct GeneralSettings: View {
    let model: SettingsModel
    let store: SessionStore

    @AppStorage(PanelStyle.key) private var style = PanelStyle.list
    @AppStorage(Entry.menuBarKey) private var menuBarIcon = true
    @AppStorage(Entry.desktopKey) private var desktopIcon = true
    @AppStorage(TerminalApp.defaultsKey) private var storedTerminal = ""

    @ViewState private var showsDiagnostics = false

    var body: some View {
        Form {
            Section("Claude Code") {
                connectionRow
                LabeledContent("连接诊断") {
                    Button("检查…") { showsDiagnostics = true }
                }
                // Notifications are what the hooks are for: say so, then let the user ask.
                if store.hooks.isReady && store.notifier.permission == .notAsked {
                    LabeledContent {
                        Button("允许通知") { Task { await store.notifier.requestPermission() } }
                    } label: {
                        Text("还没允许通知")
                        Text("等你确认、出错或长回合做完时发通知，点一下回到那个终端")
                    }
                }
                LabeledContent("claude 的位置") {
                    HStack(spacing: 12) {
                        Text(claudePath)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("更改…") { ClaudePicker.choose(store: store) }
                    }
                }
            }
            terminalSection
            Section("面板") {
                LabeledContent {
                    Picker("排列方式", selection: $style) {
                        ForEach(PanelStyle.allCases) { item in
                            Text(item.title).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                } label: {
                    Text("排列方式")
                    Text(style.caption)
                }
                Toggle(isOn: $menuBarIcon) {
                    Text("菜单栏图标")
                    Text("点一下在菜单栏下方弹出会话面板")
                }
                .disabled(menuBarIcon && !desktopIcon)
            }
            Section("快捷键") {
                ForEach(Shortcut.allCases) { shortcut in
                    ShortcutRow(shortcut: shortcut, hotKeys: .shared)
                }
            }
            Section {
                Toggle(isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) })) {
                    Text("开机时启动")
                    if model.launchNeedsApproval {
                        Text("还要在系统设置的「登录项」里允许")
                    }
                }
            }
        }
        .sheet(isPresented: $showsDiagnostics) {
            ConnectionDiagnostics(model: model, store: store)
        }
    }

    private var terminal: TerminalApp {
        TerminalApp.resolve(stored: storedTerminal.isEmpty ? nil : storedTerminal,
                            isInstalled: model.installedTerminals.contains)
    }

    /// Where new sessions open. Any terminal works for going back to a session; these
    /// three are the ones AgentBell can open a tab in and find the exact tab again.
    private var terminalSection: some View {
        Section("终端") {
            LabeledContent {
                Picker("新会话在哪里打开", selection: Binding(get: { terminal }, set: { storedTerminal = $0.rawValue })) {
                    ForEach(TerminalApp.allCases) { app in
                        Text(pickerTitle(app)).tag(app)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                Text("新会话在哪里打开")
                Text(terminal == .terminal
                     ? "回到终端时，能定位到会话所在的窗口和标签页"
                     : "回到终端时，能定位到会话所在的标签页和分屏")
            }
            if let version = model.outdatedTerminals[terminal], let page = terminal.downloadPage {
                LabeledContent {
                    Link("更新", destination: page)
                } label: {
                    Text(terminal.outdatedNote(version))
                    Text("更新前，新会话打不开，跳回时也找不到具体分屏")
                }
            } else if let app = suggestedDownload, let page = app.downloadPage {
                LabeledContent {
                    Link("下载", destination: page)
                } label: {
                    if app == terminal {
                        Text("\(app.title) 还没安装")
                        Text("安装前，新会话打不开")
                    } else {
                        Text("推荐 Ghostty")
                        Text("免费开源，跳回时能定位到具体分屏")
                    }
                }
            }
        }
    }

    private func pickerTitle(_ app: TerminalApp) -> String {
        if !model.installedTerminals.contains(app) { return "\(app.title)（未安装）" }
        return model.outdatedTerminals[app] == nil ? app.title : "\(app.title)（需更新）"
    }

    /// The picked terminal when it is missing, else Ghostty when it is.
    private var suggestedDownload: TerminalApp? {
        if !model.installedTerminals.contains(terminal) { return terminal }
        return model.installedTerminals.contains(.ghostty) ? nil : .ghostty
    }

    /// UI_DESIGN.md §6: lamp, state, and the one action that changes it. Disconnecting
    /// asks nothing: connecting again undoes it.
    private var connectionRow: some View {
        let hooks = store.hooks
        return HStack(spacing: 8) {
            LampView(kind: connectionLamp(hooks))
            VStack(alignment: .leading, spacing: 2) {
                Text(connectionText(hooks)).font(.rowTitle)
                if let problem = hooks.problem ?? hooks.listenerProblem {
                    Text(problem).font(.rowDetail).foregroundStyle(Color.bellRed).lineLimit(2)
                } else if hooks.isReady, let last = hooks.lastEventAt {
                    let elapsed = Copy.elapsed(Date().timeIntervalSince(last))
                    Text(elapsed == "刚刚" ? "刚刚收到事件" : "上次收到事件 \(elapsed)前")
                        .font(.rowDetail)
                        .foregroundStyle(.secondary)
                } else if hooks.isReady {
                    Text("在 Claude Code 里操作一次，确认能收到事件")
                        .font(.rowDetail)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            if !hooks.isReady {
                Button(hooks.connection == .notConnected ? "连接" : "重试") { hooks.connect() }
            }
            if hooks.connection != .notConnected {
                Button("断开") { hooks.disconnect() }
            }
        }
    }

    private func connectionLamp(_ hooks: HookController) -> LampKind {
        switch hooks.connection {
        // Amber means "waiting for you" everywhere else: an unproven connection stays grey.
        case .connected: !hooks.isReady ? .failed : (hooks.lastEventAt == nil ? .faint : .completed)
        case .stale: .failed
        case .notConnected: hooks.problem == nil ? .faint : .failed
        }
    }

    private func connectionText(_ hooks: HookController) -> String {
        switch hooks.connection {
        case .notConnected: "未连接"
        case .stale: "连接已失效"
        case .connected:
            if !hooks.isReady { "提醒不可用" }
            else if hooks.lastEventAt == nil { "已连接，还没收到事件" }
            else { "已连接" }
        }
    }

    private var claudePath: String {
        guard case .ready(let url) = store.claude else { return "没找到" }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
    }

}

struct NotificationSettings: View {
    @AppStorage(Notifier.Key.waiting) private var notifyWaiting = true
    @AppStorage(Notifier.Key.failed) private var notifyFailed = true
    @AppStorage(Notifier.Key.done) private var notifyDone = true
    @AppStorage(Notifier.Key.showContent) private var showContent = true
    @AppStorage(Notifier.Key.longRound) private var longRound = NoticePrefs.longRoundChoices[0]
    @AppStorage(Notifier.Key.system) private var systemNotices = true
    @AppStorage(Notifier.Key.bubble) private var bubbles = true
    @AppStorage(Entry.desktopKey) private var desktopIcon = true

    var body: some View {
        Form {
            Section("提醒方式") {
                Toggle(isOn: $systemNotices) {
                    Text("系统通知")
                    Text("不在电脑前时，提醒会留在通知中心")
                }
                Toggle(isOn: $bubbles) {
                    Text("桌面图标旁的气泡")
                    Text(desktopIcon ? "点气泡回到终端；等你确认和出错的会一直留着" : "要先在「通用」里打开桌面图标")
                }
                .disabled(!desktopIcon)
            }
            Section("什么时候提醒") {
                Toggle("等你确认时", isOn: $notifyWaiting)
                Toggle("出错时", isOn: $notifyFailed)
                Toggle(isOn: $notifyDone) {
                    Text("长回合做完时")
                    Text("短回合做完不打扰你")
                }
                Picker("超过多久算长回合", selection: $longRound) {
                    ForEach(NoticePrefs.longRoundChoices, id: \.self) { seconds in
                        Text(Copy.roundLength(seconds)).tag(seconds)
                    }
                }
                .disabled(!notifyDone)
            }
            Section {
                Toggle(isOn: $showContent) {
                    Text("提醒里显示具体内容")
                    Text("关掉后只写项目和状态，屏幕共享时用得上")
                }
            }
        }
    }
}

struct PermissionSettings: View {
    let model: SettingsModel
    let store: SessionStore

    var body: some View {
        Form {
            Section {
                LabeledContent("通知") { notificationStatus }
                if store.notifier.permission == .allowed {
                    LabeledContent {
                        previewStatus
                    } label: {
                        Text("通知预览")
                        Text("关着时横幅只显示「1 个通知」")
                    }
                }
                ForEach(TerminalApp.allCases.filter(model.installedTerminals.contains)) { app in
                    LabeledContent {
                        automationStatus(app)
                    } label: {
                        Text("控制\(app.inSentence)".trimmingCharacters(in: .whitespaces))
                        Text("跳回会话所在的标签页，在这里打开新会话")
                    }
                }
                LabeledContent {
                    accessibilityStatus
                } label: {
                    Text("辅助功能")
                    Text("跳回终端后，用一圈边框标出是哪个分屏。只读分屏的位置")
                }
            }
        }
    }

    private var allowedStatus: some View {
        HStack(spacing: 5) {
            LampView(kind: .completed)
            Text("已允许").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var accessibilityStatus: some View {
        if model.accessibilityAllowed {
            allowedStatus
        } else {
            Button("去打开") { TerminalHighlight.askPermission() }
                .buttonStyle(.link)
        }
    }

    @ViewBuilder private var notificationStatus: some View {
        switch store.notifier.permission {
        case .allowed:
            allowedStatus
        case .notAsked:
            Button("允许") { Task { await store.notifier.requestPermission() } }
                .buttonStyle(.link)
        case .denied:
            Button("去打开") { Notifier.settingsURL.map { _ = NSWorkspace.shared.open($0) } }
                .buttonStyle(.link)
        case .unknown:
            Text("正在检查…").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var previewStatus: some View {
        if store.notifier.previewsHidden {
            Button("去打开") { Notifier.settingsURL.map { _ = NSWorkspace.shared.open($0) } }
                .buttonStyle(.link)
        } else {
            allowedStatus
        }
    }

    @ViewBuilder private func automationStatus(_ app: TerminalApp) -> some View {
        switch model.automation[app] ?? .targetNotRunning {
        case .allowed:
            allowedStatus
        case .denied:
            Button("去打开") { NSWorkspace.shared.open(AutomationPermission.settingsURL) }
                .buttonStyle(.link)
        case .notAsked:
            Text("第一次跳转时会询问").foregroundStyle(.secondary)
        case .targetNotRunning:
            Text("没在运行").foregroundStyle(.secondary)
        }
    }
}

struct AboutSettings: View {
    let model: SettingsModel
    let store: SessionStore

    @AppStorage(DeveloperLogs.modeKey) private var developerMode = false
    @ViewState private var showsNotes = false
    @ViewState private var showsLogs = false

    private var updates: UpdateChecker { store.updates }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "开发版"
        return "版本 \(short)"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    BellAppIcon(size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("AgentBell").font(.panelHeader)
                        Text(version).foregroundStyle(.secondary)
                        Text("同时开着好几个 Claude Code 时，告诉你哪个在等你、哪个做完了，点一下回到那个终端")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
                LabeledContent {
                    Button("查看") { showsNotes = true }
                } label: {
                    Text("更新说明")
                    Text("这一版新增了什么")
                }
            }
            if updates.currentVersion != nil {
                Section("更新") {
                    LabeledContent("新版本") { updateStatus }
                }
            }
            Section("数据") {
                Text("会话状态和钩子事件只在本机处理。发起代码审查时，所选代码差异会交给你配置的 Claude Code 模型。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                LabeledContent("数据文件夹") {
                    Button("在访达中显示") {
                        NSWorkspace.shared.activateFileViewerSelecting([BellPaths.supportDirectory])
                    }
                    .buttonStyle(.link)
                }
            }
            Section("开发者") {
                Toggle(isOn: $developerMode) {
                    Text("开发者模式")
                    Text("查看和导出运行日志，排查问题时用")
                }
                if developerMode {
                    LabeledContent {
                        HStack(spacing: 8) {
                            Button("查看…") { showsLogs = true }
                            Button("导出…") { Task { await DeveloperLogs.export(model: model, store: store) } }
                        }
                    } label: {
                        Text("运行日志")
                        Text("本次启动以来的事件和错误，不含提问、回复和文件名")
                    }
                }
            }
        }
        .sheet(isPresented: $showsNotes) { WhatsNewView() }
        .sheet(isPresented: $showsLogs) { DeveloperLogsView(model: model, store: store) }
    }

    @ViewBuilder private var updateStatus: some View {
        HStack(spacing: 8) {
            switch updates.state {
            case .idle:
                EmptyView()
            case .checking:
                Text("正在检查…").foregroundStyle(.secondary)
            case .upToDate:
                Text("已是最新").foregroundStyle(.secondary)
            case .failed:
                Text("检查失败").foregroundStyle(.secondary)
            case .available(let release):
                if release.archive != nil {
                    Button("下载并安装 \(release.version)") { Task { await updates.install(release) } }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("下载 \(release.version)") { NSWorkspace.shared.open(release.page) }
                        .buttonStyle(.link)
                }
            case .downloading(_, let progress):
                if let progress {
                    ProgressView(value: progress).frame(width: 80)
                    Text("正在下载 \(Int(progress * 100))%").foregroundStyle(.secondary).monospacedDigit()
                } else {
                    ProgressView().controlSize(.small)
                    Text("正在下载…").foregroundStyle(.secondary)
                }
            case .ready(let release):
                Text("\(release.version) 已下载").foregroundStyle(.secondary)
                Button("重启完成更新") { updates.restart() }
                    .buttonStyle(.borderedProminent)
            case .installFailed(let release, let message):
                Text(message).foregroundStyle(.secondary)
                Button("去下载页") { NSWorkspace.shared.open(release.page) }
                    .buttonStyle(.link)
            }
            if showsCheckButton {
                Button("检查更新") { Task { await updates.check() } }
                    .disabled(updates.state == .checking)
            }
        }
    }

    private var showsCheckButton: Bool {
        switch updates.state {
        case .downloading, .ready: false
        default: true
        }
    }
}

/// Lets the user point at a `claude` executable by hand.
@MainActor
enum ClaudePicker {
    static func choose(store: SessionStore) {
        let panel = NSOpenPanel()
        panel.title = "选择 claude 可执行文件"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.useClaude(at: url.path)
    }
}

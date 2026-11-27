import AppKit
import BellCore
import SwiftUI

struct ConnectionDiagnostics: View {
    let model: SettingsModel
    let store: SessionStore

    private enum CLIStatus {
        case checking, missing, failed, incomplete, ready

        var title: String {
            switch self {
            case .checking: "正在检查…"
            case .missing: "找不到 Claude Code"
            case .failed: "无法读取会话列表"
            case .incomplete: "部分会话记录无法读取"
            case .ready: "可以读取会话列表"
            }
        }
    }

    @Environment(\.dismiss) private var dismiss
    @ViewState private var cli = CLIStatus.checking
    @ViewState private var refreshID = 0
    @ViewState private var testingNotice = false
    @ViewState private var testingJump = false
    @AppStorage(Notifier.Key.system) private var systemNotices = true
    @ViewState private var noticeResult: String?
    @ViewState private var jumpResult: String?

    var body: some View {
        VStack(spacing: 0) {
            Text("连接诊断").font(.title2.weight(.semibold)).padding(.top, 18)
            Form {
                Section("Claude Code") {
                    LabeledContent(cli.title) {
                        if cli == .missing || cli == .failed {
                            Button("选择 Claude…") { ClaudePicker.choose(store: store) }
                        }
                    }
                    LabeledContent {
                        if !store.hooks.isReady {
                            Button(store.hooks.connection == .notConnected ? "连接" : "重连") {
                                store.hooks.connect()
                            }
                        }
                    } label: {
                        Text("会话事件")
                        Text(hookStatus)
                    }
                }
                Section("macOS 通知") {
                    LabeledContent {
                        notificationAction
                    } label: {
                        Text("系统通知")
                        Text(noticeResult ?? notificationStatus)
                    }
                }
                Section("终端") {
                    LabeledContent {
                        if model.outdatedTerminals[TerminalApp.current] != nil, let page = TerminalApp.current.downloadPage {
                            Link("更新", destination: page)
                        } else if let live = store.liveSessions.max(by: { $0.stateSince < $1.stateSince }) {
                            Button("测试跳转") { testJump(live) }
                                .disabled(testingJump)
                        } else if model.automation[TerminalApp.current] == .denied {
                            Button("打开自动化设置") { NSWorkspace.shared.open(AutomationPermission.settingsURL) }
                        }
                    } label: {
                        Text("定位会话")
                        Text(jumpResult ?? terminalStatus)
                    }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("重新检查") {
                    noticeResult = nil
                    jumpResult = nil
                    store.pollNow()
                    refreshID += 1
                }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(width: 510, height: 425)
        .task(id: refreshID) { await refresh() }
        .onChange(of: store.claude) { _, _ in refreshID += 1 }
    }

    private var hookStatus: String {
        if let problem = store.hooks.problem ?? store.hooks.listenerProblem { return problem }
        guard store.hooks.isReady else {
            return store.hooks.connection == .stale ? "连接已失效，请重新连接。" : "尚未连接会话事件。"
        }
        if let time = store.hooks.lastEventAt {
            return "上次收到事件 (time.formatted(date: .abbreviated, time: .standard))"
        }
        return "已监听。请在 Claude 会话发一条消息来验证。"
    }

    private var notificationStatus: String {
        switch store.notifier.permission {
        case .allowed: systemNotices
            ? "已允许。测试只检查系统通知通道。"
            : "AgentBell 的系统通知开关已关闭，仍可单独发送测试。"
        case .notAsked: "允许后可发送测试提醒。"
        case .denied: "系统通知未开启。"
        case .unknown: "正在检查权限…"
        }
    }

    @ViewBuilder private var notificationAction: some View {
        switch store.notifier.permission {
        case .allowed:
            Button("发送测试") {
                testingNotice = true
                noticeResult = nil
                Task {
                    let sent = await store.notifier.sendTestNotification()
                    noticeResult = sent ? "已交给 macOS。没看到横幅时，可查看通知中心。" : "发送失败，请检查通知权限。"
                    testingNotice = false
                }
            }
            .disabled(testingNotice)
        case .notAsked:
            Button("允许通知") { Task { await store.notifier.requestPermission() } }
        case .denied:
            if let url = Notifier.settingsURL {
                Button("打开系统设置") { NSWorkspace.shared.open(url) }
            }
        case .unknown:
            EmptyView()
        }
    }

    private var terminalStatus: String {
        let app = TerminalApp.current
        guard model.installedTerminals.contains(app) else { return "\(app.title) 未安装，可在通用设置里切换。" }
        if let version = model.outdatedTerminals[app] { return "\(app.outdatedNote(version))，请先更新。" }
        switch model.automation[app] ?? .targetNotRunning {
        case .allowed: return "\(app.title) 已授权。打开 Claude 会话后可测试跳转。"
        case .denied: return "\(app.title) 未获授权，可在「权限」页处理。"
        case .notAsked: return "首次跳转到 \(app.title) 时，macOS 会询问权限。"
        case .targetNotRunning: return "\(app.title) 当前未运行。打开 Claude 会话后可测试。"
        }
    }

    private func refresh() async {
        cli = .checking
        model.refresh()
        store.hooks.refresh()
        await store.notifier.refresh()
        guard !Task.isCancelled else { return }
        guard case .ready(let executable) = store.claude else {
            cli = store.claude == .notFound ? .missing : .checking
            return
        }
        do {
            let snapshot = try await ClaudeCLI.snapshot(executable: executable)
            guard !Task.isCancelled else { return }
            cli = snapshot.isComplete ? .ready : .incomplete
        } catch {
            if !Task.isCancelled { cli = .failed }
        }
    }

    private func testJump(_ session: Session) {
        testingJump = true
        jumpResult = nil
        Task {
            switch await TerminalJumper.jump(to: session, beforePrompt: {}) {
            case .focusedTerminal: jumpResult = "已定位到会话所在的标签页或分屏。"
            case .appOnly: jumpResult = "找到了终端应用，无法定位到具体会话。"
            case .notFound: jumpResult = "找不到此会话对应的终端。"
            }
            testingJump = false
            model.refresh()
        }
    }
}

import AppKit
import BellCore
import OSLog
import SwiftUI
import UniformTypeIdentifiers

/// Settings › About › 开发者: this run's log, to look at or hand over. The log holds event
/// kinds and errors, never prompts, replies or file names (DESIGN.md §5).
enum LogReader {
    /// Enough to cover a reproduced problem without the viewer crawling.
    private static let maxLines = 2000

    /// Only this process, since it started: the system keeps no earlier runs for us.
    /// Reads off the main thread, since a long run holds many entries.
    static func read() async throws -> [DiagnosticReport.Line] {
        try await Task.detached(priority: .userInitiated) {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let entries = try store.getEntries(matching: NSPredicate(format: "subsystem == %@", "com.agentbell.AgentBell"))
            let lines = entries.compactMap { $0 as? OSLogEntryLog }.map {
                DiagnosticReport.Line(date: $0.date, level: level($0.level), category: $0.category, message: $0.composedMessage)
            }
            return Array(lines.suffix(maxLines))
        }.value
    }

    private static func level(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: "debug"
        case .info: "info"
        case .notice: "notice"
        case .error: "error"
        case .fault: "fault"
        default: "undefined"
        }
    }
}

@MainActor
enum DeveloperLogs {
    static let modeKey = "developer.mode"

    /// Asks where to save the report, then shows it in Finder.
    static func export(model: SettingsModel, store: SessionStore) async {
        model.refresh()
        await store.notifier.refresh()
        let environment = environment(model: model, store: store)
        let text: String
        do {
            text = DiagnosticReport.render(environment: environment, lines: try await LogReader.read(), generatedAt: Date())
        } catch {
            text = DiagnosticReport.render(environment: environment + [("日志", "读取失败：\(error.localizedDescription)")],
                                           lines: [], generatedAt: Date())
        }

        let panel = NSSavePanel()
        panel.title = "导出日志"
        panel.nameFieldStringValue = DiagnosticReport.fileName(at: Date())
        panel.allowedContentTypes = [.plainText]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert()
            alert.messageText = "日志没能保存"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    /// What usually decides a support question: versions, the terminals and whether
    /// AgentBell may control them, and the hook connection.
    static func environment(model: SettingsModel, store: SessionStore) -> [(String, String)] {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "开发版"
        let build = info?["CFBundleVersion"] as? String ?? "-"
        let hooks = store.hooks
        let hookState = ["\(hooks.connection)", hooks.isReady ? "ready" : "not ready", hooks.problem, hooks.listenerProblem]
            .compactMap { $0 }
            .joined(separator: " · ")
        let base: [(String, String)] = [
            ("AgentBell", "\(version) (\(build))"),
            ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
            ("claude", claudeState(store.claude)),
            ("钩子", hookState),
            ("通知权限", "\(store.notifier.permission)"),
            ("辅助功能", model.accessibilityAllowed ? "已允许" : "未允许"),
            ("新会话终端", TerminalApp.current.title),
        ]
        return base + TerminalApp.allCases.map { ($0.title, terminalState($0, model: model)) }
    }

    private static func claudeState(_ state: SessionStore.ClaudeState) -> String {
        switch state {
        case .locating: return "查找中"
        case .notFound: return "没找到"
        case .ready(let url):
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
        }
    }

    private static func terminalState(_ app: TerminalApp, model: SettingsModel) -> String {
        guard model.installedTerminals.contains(app),
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleID)
        else { return "未安装" }
        let version = Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? "版本未知"
        let permission = switch model.automation[app] ?? .targetNotRunning {
        case .allowed: "已授权"
        case .denied: "已拒绝"
        case .notAsked: "还没询问"
        case .targetNotRunning: "没在运行，授权未知"
        }
        return "\(version) · \(permission)"
    }
}

/// This run's log, newest at the bottom, with the same lines the export writes.
struct DeveloperLogsView: View {
    let model: SettingsModel
    let store: SessionStore

    @Environment(\.dismiss) private var dismiss
    @ViewState private var lines: [String] = []
    @ViewState private var problem: String?
    @ViewState private var loading = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("运行日志").font(.headline)
                Text(loading ? "正在读取…" : "本次启动以来 · \(lines.count) 条")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { Task { await load() } }
                    .disabled(loading)
                Button("导出…") { Task { await DeveloperLogs.export(model: model, store: store) } }
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            content
        }
        .frame(width: 760, height: 480)
        .task { await load() }
    }

    @ViewBuilder private var content: some View {
        if let problem {
            placeholder("读取日志失败：\(problem)")
        } else if !loading && lines.isEmpty {
            placeholder("还没有日志")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .defaultScrollAnchor(.bottom)
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        do {
            lines = DiagnosticReport.format(try await LogReader.read())
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        loading = false
    }
}

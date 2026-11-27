import BellCore
import Foundation
import Observation
import os

/// Connects Claude Code's hooks to AgentBell and listens for their events (DESIGN.md §3.3, §3.8).
@MainActor
@Observable
final class HookController {
    private(set) var connection: HookConnection = .notConnected
    private(set) var isListening = false
    private(set) var listenerProblem: String?
    private(set) var lastEventAt: Date?
    /// What went wrong with the last connect or disconnect, in the user's words.
    private(set) var problem: String?

    @ObservationIgnored private var server: HookServer?
    @ObservationIgnored private var onEvent: (@MainActor (HookEvent) -> Void)?
    var isReady: Bool { connection == .connected && isListening && problem == nil }
    @ObservationIgnored private let log = Logger(subsystem: "com.agentbell.AgentBell", category: "hooks")

    private var command: String { HookSettings.command(for: BellPaths.installedHook) }

    /// The hook program inside this app bundle.
    private var bundledHook: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/agent-bell-hook")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    func start(onEvent: @escaping @MainActor (HookEvent) -> Void) {
        self.onEvent = onEvent
        startListener()
        refresh()
        // Keep the installed copy in step with the current build.
        if connection != .notConnected {
            do { try installHook() }
            catch { problem = Self.describe(error) }
        }
    }

    private func startListener() {
        guard server == nil, let onEvent else { return }
        let server = HookServer { event in
            Task { @MainActor in onEvent(event) }
        }
        do {
            try server.start()
            self.server = server
            isListening = true
            listenerProblem = nil
        } catch HookServer.StartError.inUse {
            listenerProblem = "另一个 AgentBell 正在运行，这一个收不到会话提醒。请退出其中一个。"
            log.error("hook socket is in use by another copy")
        } catch {
            listenerProblem = "无法启动事件监听，请重试。会话提醒暂不可用。"
            log.error("hook socket failed to start: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        isListening = false
    }

    func noteEvent() {
        lastEventAt = Date()
    }

    func refresh() {
        do {
            connection = try HookSettings.connection(at: BellPaths.claudeSettings, command: command)
        } catch {
            connection = .notConnected
            log.error("reading settings.json failed: \(String(describing: error), privacy: .public)")
        }
    }

    func connect() {
        problem = nil
        startListener()
        do {
            try installHook()
            try HookSettings.connect(at: BellPaths.claudeSettings, command: command)
        } catch {
            problem = Self.describe(error)
            log.error("connect failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    func disconnect() {
        problem = nil
        do {
            try HookSettings.disconnect(at: BellPaths.claudeSettings)
            lastEventAt = nil
        } catch {
            problem = Self.describe(error)
            log.error("disconnect failed: \(String(describing: error), privacy: .public)")
        }
        refresh()
    }

    /// Copies the hook program to Application Support, where settings.json points.
    private func installHook() throws {
        guard let bundledHook else { throw InstallError.notInBundle }
        let target = BellPaths.installedHook
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = target.deletingLastPathComponent().appendingPathComponent(".agent-bell-hook.tmp")
        try? fileManager.removeItem(at: temp)
        try fileManager.copyItem(at: bundledHook, to: temp)
        guard rename(temp.path, target.path) == 0 else { throw InstallError.copyFailed }
    }

    enum InstallError: Error {
        case notInBundle
        case copyFailed
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case HookSettingsError.invalidJSON: return "~/.claude/settings.json 不是有效的 JSON，先修好它再连接"
        case HookSettingsError.unexpectedHooksShape: return "settings.json 里 hooks 的格式和预想的不一样，没有改动"
        case HookSettingsError.readFailed: return "读不了 ~/.claude/settings.json"
        case HookSettingsError.writeFailed: return "写不进 ~/.claude/settings.json，没有改动"
        case InstallError.notInBundle: return "要从打包好的 AgentBell.app 里连接"
        default: return "没能装好钩子程序"
        }
    }

    static let changesExplained = """
    会在 ~/.claude/settings.json 的 hooks 里，给 9 种事件各加一条 AgentBell 的钩子。\
    钩子在后台运行，只把事件种类和一行短字发给 AgentBell，不会改变 Claude 的行为。\
    第一次改动前，原文件会备份成 settings.json.agent-bell-backup。\
    断开时只删这几条，其余内容保持原样。
    """
}

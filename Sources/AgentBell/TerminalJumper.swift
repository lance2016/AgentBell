import AppKit
import BellCore
import CoreServices
import os

/// Whether macOS lets AgentBell control a terminal (Automation).
enum AutomationPermission: Equatable {
    case allowed
    case denied
    /// Never asked yet; the first jump brings up the system prompt.
    case notAsked
    case targetNotRunning

    static func of(_ app: TerminalApp) -> AutomationPermission {
        let target = NSAppleEventDescriptor(bundleIdentifier: app.bundleID)
        guard let desc = target.aeDesc else { return .targetNotRunning }
        switch AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, false) {
        case noErr: return .allowed
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notAsked
        default: return .targetNotRunning
        }
    }

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
}

extension TerminalApp {
    /// The one Settings › 通用 picked for new sessions.
    static var current: TerminalApp {
        resolve(stored: UserDefaults.standard.string(forKey: defaultsKey), isInstalled: \.isInstalled)
    }

    var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    /// The installed copy's version, read from its Info.plist each time: `Bundle(url:)`
    /// caches, and would keep the old version after the app is updated in place.
    var installedVersion: String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
        else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    /// The installed version when it is too old for AgentBell's scripts; nil otherwise.
    var outdatedVersion: String? {
        installedVersion.flatMap { isOutdated(version: $0) ? $0 : nil }
    }

    /// "Ghostty 1.3.1 太旧，需要 1.4.0 或更新".
    func outdatedNote(_ version: String) -> String {
        "\(title) \(version) 太旧，需要 \(minimumVersion ?? "") 或更新"
    }
}

/// Brings a session's terminal to the front (DESIGN.md §3.7).
@MainActor
enum TerminalJumper {
    enum Outcome: Equatable {
        /// The session's own window, tab and split are focused.
        case focusedTerminal
        /// An app is available, but the exact window or pane is unknown.
        case appOnly(pid_t)
        /// No terminal to go back to.
        case notFound
    }

    enum LaunchError: LocalizedError {
        case missing(TerminalApp), outdated(TerminalApp, String), permissionDenied(TerminalApp), failed(TerminalApp)

        var errorDescription: String? {
            switch self {
            case .missing(let app):
                let download = app.downloadPage?.host().map { "，或去 \($0) 下载" } ?? ""
                return "\(app.title) 还没安装。可以在「设置 › 通用」换一个终端\(download)。"
            case .outdated(let app, let version):
                let download = app.downloadPage?.host().map { "（\($0)）" } ?? ""
                return "\(app.outdatedNote(version))。请先更新\(download)，或在「设置 › 通用」换一个终端。"
            case .permissionDenied(let app):
                return "请在「系统设置 › 隐私与安全性 › 自动化」允许 AgentBell 控制\(app.inSentence)。"
                    .replacingOccurrences(of: " 。", with: "。")
            case .failed(.ghostty):
                return "无法创建 Ghostty 标签页。请确认 Ghostty 为 1.4 或更新版本，并已启用 AppleScript。"
            case .failed(let app):
                return "无法在\(app.inSentence)里打开新会话。"
            }
        }
    }

    private static let log = Logger(subsystem: "com.agentbell.AgentBell", category: "jump")
    private static var resuming: Set<String> = []

    static func launchClaude(in app: TerminalApp, executable: URL, directory: String,
                             resumeSessionID: String? = nil, beforePrompt: () -> Void) async throws {
        if let resumeSessionID, !resuming.insert(resumeSessionID).inserted { return }
        defer { if let resumeSessionID { resuming.remove(resumeSessionID) } }
        guard app.isInstalled else { throw LaunchError.missing(app) }
        if let version = app.outdatedVersion { throw LaunchError.outdated(app, version) }

        let permission = AutomationPermission.of(app)
        if permission == .denied { throw LaunchError.permissionDenied(app) }
        if permission != .allowed { beforePrompt() }

        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", app.launchScript, directory, executable.path] + (resumeSessionID.map { [$0] } ?? []),
                timeout: 60
            )
        } catch {
            log.error("\(app.rawValue, privacy: .public) launch could not run: \(String(describing: error), privacy: .private)")
            throw LaunchError.failed(app)
        }
        guard output.exitCode == 0,
              String(decoding: output.standardOutput, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "launched"
        else {
            if AutomationPermission.of(app) == .denied || output.standardError.contains("(-1743)") {
                throw LaunchError.permissionDenied(app)
            }
            log.error("\(app.rawValue, privacy: .public) launch failed: \(output.standardError, privacy: .private)")
            throw LaunchError.failed(app)
        }
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first {
            NSApp.yieldActivation(to: running)
            running.activate()
            let pid = running.processIdentifier
            Task { await TerminalFill.apply(pid: pid) }
        }
    }

    /// - Parameter beforePrompt: called when macOS is about to ask for permission to
    ///   control the terminal, so the panel can get out of the prompt's way.
    static func jump(to session: Session, beforePrompt: () -> Void) async -> Outcome {
        guard !session.isEnded,
              let hostPID = TerminalLocator.hostApp(of: session.pid, parent: ProcessInspector.parent(of:), isApp: isRegularApp),
              let app = NSRunningApplication(processIdentifier: hostPID)
        else { return .notFound }

        let host = app.bundleIdentifier ?? "unknown"
        if let terminal = TerminalApp(bundleID: host), let tty = ProcessInspector.ttyPath(of: session.pid) {
            let permission = AutomationPermission.of(terminal)
            if permission == .notAsked { beforePrompt() }
            let outcome = await focus(terminal, tty: tty)
            log.notice("jump \(terminal.rawValue, privacy: .public) permission=\(String(describing: permission), privacy: .public) outcome=\(String(describing: outcome), privacy: .public)")
            if outcome == .focused {
                bringForward(app)
                return .focusedTerminal
            }
        }
        log.notice("jump has only app \(host, privacy: .public)")
        return .appOnly(hostPID)
    }

    /// Sessions the user is looking at right now: in front, the terminal they run in has
    /// focus, and the user touched the keyboard or pointer lately. Only terminals AgentBell
    /// may already script count; it never asks for permission here.
    static func watched(_ sessions: [Session]) async -> Set<String> {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard idle < watchingWithin,
              let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let terminal = TerminalApp(bundleID: front),
              AutomationPermission.of(terminal) == .allowed,
              let output = try? await ProcessRunner.run(
                  URL(fileURLWithPath: "/usr/bin/osascript"), arguments: ["-e", terminal.focusedTTYScript], timeout: 2
              ),
              output.exitCode == 0
        else { return [] }
        let tty = String(decoding: output.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard TerminalLocator.isTTYPath(tty) else { return [] }
        return Set(sessions.filter { ProcessInspector.ttyPath(of: $0.pid) == tty }.map(\.id))
    }

    /// Longer without input than this, and the user may have walked away from the screen.
    private static let watchingWithin: TimeInterval = 30

    static func openTerminalApp(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        NSApp.yieldActivation(to: app)
        return app.activate()
    }

    /// macOS 14 only honours activating another app when the active app yields to it.
    /// Fills the screen with the window when Settings asks, then rings the terminal where
    /// it ends up, so the eye finds it among the splits.
    private static func bringForward(_ app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        app.activate()
        let pid = app.processIdentifier
        Task {
            await TerminalFill.apply(pid: pid)
            TerminalHighlight.flash(pid: pid)
        }
    }

    nonisolated private static func isRegularApp(_ pid: Int32) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.activationPolicy == .regular
    }

    /// Runs the script in `osascript` with the device as an argument. The timeout is long
    /// because the first run waits on the user answering the permission prompt.
    private static func focus(_ terminal: TerminalApp, tty: String) async -> GhosttyScript.Outcome {
        do {
            let output = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", terminal.focusScript, tty],
                timeout: 60
            )
            let outcome = GhosttyScript.outcome(
                exitCode: output.exitCode,
                output: String(decoding: output.standardOutput, as: UTF8.self)
            )
            if outcome == .failed {
                log.error("\(terminal.rawValue, privacy: .public) focus failed: \(output.standardError, privacy: .public)")
            }
            return outcome
        } catch {
            log.error("\(terminal.rawValue, privacy: .public) focus could not run: \(String(describing: error), privacy: .public)")
            return .failed
        }
    }
}

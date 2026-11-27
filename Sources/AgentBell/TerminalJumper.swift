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
        case missing(TerminalApp), permissionDenied(TerminalApp), failed(TerminalApp)

        var errorDescription: String? {
            switch self {
            case .missing(let app):
                let download = app.downloadPage?.host().map { "，或去 \($0) 下载" } ?? ""
                return "\(app.title) 还没安装。可以在「设置 › 通用」换一个终端\(download)。"
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

    static func launchClaude(in app: TerminalApp, executable: URL, directory: String,
                             beforePrompt: () -> Void) async throws {
        guard app.isInstalled else { throw LaunchError.missing(app) }

        let permission = AutomationPermission.of(app)
        if permission == .denied { throw LaunchError.permissionDenied(app) }
        if permission != .allowed { beforePrompt() }

        let output: ProcessOutput
        do {
            output = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/osascript"),
                arguments: ["-e", app.launchScript, directory, executable.path],
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

    static func openTerminalApp(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return false }
        NSApp.yieldActivation(to: app)
        return app.activate()
    }

    /// macOS 14 only honours activating another app when the active app yields to it.
    /// Rings the terminal once it is in front, so the eye finds it among the splits.
    private static func bringForward(_ app: NSRunningApplication) {
        NSApp.yieldActivation(to: app)
        app.activate()
        TerminalHighlight.flash(pid: app.processIdentifier)
    }

    private static func isRegularApp(_ pid: Int32) -> Bool {
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

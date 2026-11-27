import Foundation

/// Where AgentBell keeps its own files.
public enum BellPaths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentBell")
    }

    public static var socket: URL { supportDirectory.appendingPathComponent("hooks.sock") }

    /// The hook program's stable copy. Claude Code's settings point here, so moving or
    /// rebuilding the app never breaks the hooks.
    public static var installedHook: URL { supportDirectory.appendingPathComponent("bin/agent-bell-hook") }

    public static var claudeSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }
}

public enum HookConnection: Equatable, Sendable {
    case notConnected
    case connected
    /// Ours are there but not exactly the current command on every event: reconnect.
    case stale
}

public enum HookSettingsError: Error, Equatable, Sendable {
    case invalidJSON
    case unexpectedHooksShape
    case readFailed
    case writeFailed
}

/// Adds and removes AgentBell's hooks in `~/.claude/settings.json` (DESIGN.md §3.8).
/// Ours are the hooks whose command mentions `agent-bell-hook`; nothing else is touched,
/// so AI Pet's or AgentDock's hooks next to ours stay as they are.
public enum HookSettings {
    static let marker = "agent-bell-hook"
    /// The events forwarded; must match what `HookEvent` understands.
    public static let events = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "PostToolUse",
        "Notification", "Stop", "StopFailure", "SessionEnd",
    ]
    /// Only the notifications that mean Claude is stuck until the user answers.
    static let notificationMatcher = "permission_prompt|elicitation_dialog"
    static let backupSuffix = ".agent-bell-backup"
    static let timeoutSeconds = "5"

    /// Quiet and successful even after the program is removed.
    public static func command(for hook: URL) -> String {
        let quoted = "'" + hook.path.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
        return "[ -x \(quoted) ] && \(quoted) || true"
    }

    // MARK: - Pure transformations

    public static func connection(in settings: OrderedJSON, command: String) throws -> HookConnection {
        guard case .object = settings else { throw HookSettingsError.invalidJSON }
        guard let hooks = settings["hooks"] else { return .notConnected }
        guard let members = hooks.objectValue else { throw HookSettingsError.unexpectedHooksShape }
        let ours: (String) -> [OrderedJSON] = { event in
            let groups = members.last { $0.key == event }?.value.arrayValue ?? []
            return groups.flatMap { $0["hooks"]?.arrayValue ?? [] }.filter(isOurs)
        }
        guard events.contains(where: { !ours($0).isEmpty }) else { return .notConnected }
        let current = events.allSatisfy { event in
            let found = ours(event)
            return found.count == 1 && found[0]["command"]?.stringValue == command
        }
        return current ? .connected : .stale
    }

    /// The settings without our hooks. Groups and events emptied by that go too, and so
    /// does `hooks` when nothing else was in it.
    public static func removingOurs(from settings: OrderedJSON) throws -> OrderedJSON {
        guard case .object(var top) = settings else { throw HookSettingsError.invalidJSON }
        guard let index = top.lastIndex(where: { $0.key == "hooks" }) else { return settings }
        guard let members = top[index].value.objectValue else { throw HookSettingsError.unexpectedHooksShape }
        var cleaned: [(key: String, value: OrderedJSON)] = []
        for (event, value) in members {
            guard let groups = value.arrayValue else { throw HookSettingsError.unexpectedHooksShape }
            let kept = groups.compactMap(withoutOurs(group:))
            if kept.isEmpty && !groups.isEmpty { continue }
            cleaned.append((event, .array(kept)))
        }
        if cleaned.isEmpty && !members.isEmpty {
            top.remove(at: index)
        } else {
            top[index].value = .object(cleaned)
        }
        return .object(top)
    }

    /// The settings with exactly one hook of ours on each event, after the user's own.
    public static func addingOurs(to settings: OrderedJSON, command: String) throws -> OrderedJSON {
        guard case .object(var top) = try removingOurs(from: settings) else { throw HookSettingsError.invalidJSON }
        var hooks: [(key: String, value: OrderedJSON)] = []
        if let index = top.lastIndex(where: { $0.key == "hooks" }) {
            guard let members = top[index].value.objectValue else { throw HookSettingsError.unexpectedHooksShape }
            hooks = members
        }
        for event in events {
            let hook = OrderedJSON.object([
                ("type", .string("command")),
                ("command", .string(command)),
                ("async", .bool(true)),
                ("timeout", .number(timeoutSeconds)),
            ])
            var group: [(key: String, value: OrderedJSON)] = []
            if event == "Notification" { group.append(("matcher", .string(notificationMatcher))) }
            group.append(("hooks", .array([hook])))
            if let index = hooks.lastIndex(where: { $0.key == event }) {
                guard var groups = hooks[index].value.arrayValue else { throw HookSettingsError.unexpectedHooksShape }
                groups.append(.object(group))
                hooks[index].value = .array(groups)
            } else {
                hooks.append((event, .array([.object(group)])))
            }
        }
        if let index = top.lastIndex(where: { $0.key == "hooks" }) {
            top[index].value = .object(hooks)
        } else {
            top.append(("hooks", .object(hooks)))
        }
        return .object(top)
    }

    private static func isOurs(_ hook: OrderedJSON) -> Bool {
        hook["command"]?.stringValue?.contains(marker) == true
    }

    private static func withoutOurs(group: OrderedJSON) -> OrderedJSON? {
        guard case .object(var members) = group,
              let index = members.lastIndex(where: { $0.key == "hooks" }),
              let list = members[index].value.arrayValue
        else { return group }
        let others = list.filter { !isOurs($0) }
        if others.count == list.count { return group }
        if others.isEmpty { return nil }
        members[index].value = .array(others)
        return .object(members)
    }

    // MARK: - File

    public static func read(_ url: URL) throws -> (settings: OrderedJSON, trailingNewline: Bool) {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return (.object([]), true)
        } catch {
            throw HookSettingsError.readFailed
        }
        guard let settings = try? OrderedJSON.parse(text) else { throw HookSettingsError.invalidJSON }
        return (settings, text.hasSuffix("\n"))
    }

    public static func connection(at url: URL, command: String) throws -> HookConnection {
        try connection(in: read(url).settings, command: command)
    }

    public static func connect(at url: URL, command: String) throws {
        let (settings, newline) = try read(url)
        try write(addingOurs(to: settings, command: command), newline: newline, to: url)
    }

    public static func disconnect(at url: URL) throws {
        let (settings, newline) = try read(url)
        guard try connection(in: settings, command: "") != .notConnected else { return }
        try write(removingOurs(from: settings), newline: newline, to: url)
    }

    /// Backs up the user's file once, then replaces it in one step. A linked settings
    /// file is written where the link points; the new file keeps the old one's
    /// permissions (it may hold API keys), or is private when new.
    static func write(_ settings: OrderedJSON, newline: Bool, to url: URL) throws {
        let fileManager = FileManager.default
        let target = url.resolvingSymlinksInPath()
        var permissions: NSNumber = 0o600
        if fileManager.fileExists(atPath: target.path) {
            let backup = URL(fileURLWithPath: target.path + backupSuffix)
            if !fileManager.fileExists(atPath: backup.path) {
                guard (try? fileManager.copyItem(at: target, to: backup)) != nil else { throw HookSettingsError.writeFailed }
            }
            if let mode = (try? fileManager.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber {
                permissions = mode
            }
        } else {
            try? fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        let temp = target.deletingLastPathComponent().appendingPathComponent(".settings.json.agent-bell-tmp")
        let text = settings.printed() + (newline ? "\n" : "")
        guard fileManager.createFile(atPath: temp.path, contents: Data(text.utf8), attributes: [.posixPermissions: permissions]) else {
            throw HookSettingsError.writeFailed
        }
        guard rename(temp.path, target.path) == 0 else {
            try? fileManager.removeItem(at: temp)
            throw HookSettingsError.writeFailed
        }
    }
}

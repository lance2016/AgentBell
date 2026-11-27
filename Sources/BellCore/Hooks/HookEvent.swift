import Foundation

/// One line on the socket: what the hook program keeps of a Claude Code hook event.
/// Short lines only. Commands, code, tool output and full paths are never forwarded.
public struct HookEvent: Codable, Sendable, Equatable {
    public var event: String
    public var session: String
    /// When the hook ran, in milliseconds since 1970. Hooks run in the background and
    /// can arrive out of order, so events are placed by this, not by arrival.
    public var at: Double
    public var tool: String?
    /// The file a tool works on, or its step as Claude described it.
    public var detail: String?
    /// The first line of what the user asked (UserPromptSubmit).
    public var prompt: String?
    /// Claude Code woke the session because background work ended; not the user asking.
    public var woke: Bool?
    /// The first line of Claude's reply (Stop).
    public var reply: String?
    /// The turn ended with work still running in the background (Stop).
    public var background: Bool?
    public var error: String?
    public var notification: String?
    /// Sent by a subagent of the session.
    public var subagent: Bool?

    public init(
        event: String, session: String, at: Double, tool: String? = nil, detail: String? = nil,
        prompt: String? = nil, woke: Bool? = nil, reply: String? = nil, background: Bool? = nil,
        error: String? = nil, notification: String? = nil, subagent: Bool? = nil
    ) {
        self.event = event
        self.session = session
        self.at = at
        self.tool = tool
        self.detail = detail
        self.prompt = prompt
        self.woke = woke
        self.reply = reply
        self.background = background
        self.error = error
        self.notification = notification
        self.subagent = subagent
    }

    public var date: Date { Date(timeIntervalSince1970: at / 1000) }

    static let maxLine = 8192
    static let maxNameChars = 64
    static let fileTools: Set = ["Edit", "Write", "Read", "MultiEdit", "NotebookEdit"]
    static let describedTools: Set = ["Bash", "Agent", "Task"]
    static let taskNotification = "<task-notification>"

    /// Builds the line from the JSON Claude Code passes a hook on stdin. Nil for an
    /// event AgentBell does not follow or input it cannot read.
    public static func from(hookInput data: Data, now: Date) -> HookEvent? {
        guard let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = input["hook_event_name"] as? String,
              HookSettings.events.contains(name),
              let session = input["session_id"] as? String,
              isSafeID(session)
        else { return nil }

        var event = HookEvent(event: name, session: session, at: (now.timeIntervalSince1970 * 1000).rounded())
        let tool = input["tool_name"] as? String
        event.tool = tool.map { cut($0, maxNameChars) }
        if name == "PreToolUse" || name == "PermissionRequest", let tool,
           let toolInput = input["tool_input"] as? [String: Any] {
            event.detail = detail(tool: tool, input: toolInput)
        }
        if name == "UserPromptSubmit", let prompt = input["prompt"] as? String {
            let woke = prompt.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(taskNotification)
            event.woke = woke ? true : nil
            event.prompt = woke ? nil : Transcript.firstLine(prompt, limit: Transcript.maxTitleChars)
        }
        if name == "Stop" {
            event.reply = (input["last_assistant_message"] as? String)
                .flatMap(Transcript.replyLine)
            event.background = ((input["background_tasks"] as? [Any])?.isEmpty == false) ? true : nil
        }
        if let error = input["error"] as? String {
            event.error = cut(error, maxNameChars)
        } else if let error = input["error"] as? [String: Any], let kind = error["type"] as? String {
            event.error = cut(kind, maxNameChars)
        }
        event.notification = (input["notification_type"] as? String).map { cut($0, maxNameChars) }
        event.subagent = input["agent_id"] != nil ? true : nil
        return event
    }

    /// One encoded line, or nil when it would be too long to be one of ours.
    public func line() -> Data? {
        guard var data = try? JSONEncoder().encode(self), data.count < Self.maxLine else { return nil }
        data.append(0x0A)
        return data
    }

    /// Reads a line from the socket. Anything malformed or oversized is dropped.
    public static func decode(line: Data) -> HookEvent? {
        guard line.count < maxLine,
              let event = try? JSONDecoder().decode(HookEvent.self, from: line),
              HookSettings.events.contains(event.event),
              isSafeID(event.session),
              event.at > 0
        else { return nil }
        return event
    }

    /// The file name a tool works on, or its step in Claude's words. Never the command.
    static func detail(tool: String, input: [String: Any]) -> String? {
        if fileTools.contains(tool) {
            guard let path = (input["file_path"] ?? input["notebook_path"]) as? String else { return nil }
            let name = (path as NSString).lastPathComponent
            return name.isEmpty ? nil : cut(name, maxNameChars)
        }
        if describedTools.contains(tool), let description = input["description"] as? String {
            return Transcript.firstLine(description, limit: maxNameChars)
        }
        return nil
    }

    static func isSafeID(_ id: String) -> Bool {
        (1...64).contains(id.count) && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }

    static func cut(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) : text
    }
}

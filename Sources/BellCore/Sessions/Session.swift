import Foundation

/// Where the current round stands. Only `working` and `idle` come from polling; the
/// others are filled in by hook events.
public enum RoundState: String, Sendable, Equatable, Codable {
    case working, waiting, completed, background, failed, interrupted, idle
}

public struct Session: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public var pid: Int32
    public var cwd: String
    public var project: ProjectInfo
    public var name: String?
    /// A name given in AgentBell; it is AgentBell's alone and never reaches Claude Code.
    public var alias: String?
    public var startedAt: Date
    public var state: RoundState
    /// When `state` last changed; the row's elapsed time counts from here.
    public var stateSince: Date
    /// Second line of the row: what it is doing, waiting for, or answered.
    public var detail: String?
    /// When the current round began, if a hook said so.
    public var roundStartedAt: Date?
    /// The rounds hooks told of, oldest first; empty without hooks.
    public var heardTurns: [TranscriptTurn] = []
    /// Set once the session has dropped out of `claude agents`.
    public var endedAt: Date?
    /// Title, last prompt and last reply from the end of the transcript.
    public var transcript: TranscriptSummary?
    /// What polling alone says (busy or idle) and since when; shown until a hook says more.
    var polledState: RoundState
    var polledSince: Date

    public init(
        id: String,
        pid: Int32,
        cwd: String,
        project: ProjectInfo,
        name: String? = nil,
        startedAt: Date,
        state: RoundState,
        stateSince: Date,
        detail: String? = nil,
        endedAt: Date? = nil,
        transcript: TranscriptSummary? = nil
    ) {
        self.id = id
        self.pid = pid
        self.cwd = cwd
        self.project = project
        self.name = name
        self.startedAt = startedAt
        self.state = state
        self.stateSince = stateSince
        self.detail = detail
        self.endedAt = endedAt
        self.transcript = transcript
        self.polledState = state
        self.polledSince = stateSince
    }

    public var isEnded: Bool { endedAt != nil }

    /// A name given in AgentBell, else one given with /rename (from `claude agents` while
    /// open, from the transcript once closed), else Claude's own title, else the last
    /// prompt, from the transcript or, before the transcript has it, from the hooks.
    public var title: String {
        if let alias { return alias }
        if let name, !name.isEmpty, !Self.isGeneratedName(name, cwd: cwd) { return name }
        if let title = transcript?.customTitle ?? transcript?.title { return title }
        return (transcript?.lastPrompt ?? heardTurns.last?.prompt).map(Self.promptTitle) ?? "新会话"
    }

    /// A prompt standing in for a title, without a leading slash command: the command
    /// names a tool, the words after it name the work.
    static func promptTitle(_ prompt: String) -> String {
        guard prompt.hasPrefix("/"), let space = prompt.firstIndex(of: " ") else { return prompt }
        let rest = prompt[space...].trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? prompt : rest
    }

    /// `claude agents` names an unnamed session after its folder plus a short hex
    /// suffix, like "ai-pet-7f". That says nothing the group name doesn't.
    static func isGeneratedName(_ name: String, cwd: String) -> Bool {
        let folder = (cwd as NSString).lastPathComponent
        guard name.hasPrefix(folder + "-") else { return false }
        let suffix = name.dropFirst(folder.count + 1)
        return (2...8).contains(suffix.count) && suffix.allSatisfy(\.isHexDigit)
    }

    public var resumeCommand: String { Self.resumeCommand(id: id) }

    public var resumeInDirectoryCommand: String {
        Self.resumeInDirectoryCommand(id: id, cwd: cwd)
    }

    private static func resumeCommand(id: String) -> String {
        "claude --resume \(HookEvent.isSafeID(id) ? id : shellArgument(id))"
    }

    /// Also for a task's workspace, whose session may be long gone from the list.
    public static func resumeInDirectoryCommand(id: String, cwd: String) -> String {
        "cd \(shellArgument(cwd)) && \(resumeCommand(id: id))"
    }

    private static func shellArgument(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// The last few rounds for the detail: from hooks when they were listening, else
    /// from the transcript's tail, else just its last prompt and reply.
    public var recentTurns: [TranscriptTurn] {
        if !heardTurns.isEmpty { return heardTurns }
        if let turns = transcript?.turns, !turns.isEmpty { return turns }
        guard let transcript, transcript.lastPrompt != nil || transcript.lastReply != nil else { return [] }
        return [TranscriptTurn(prompt: transcript.lastPrompt, reply: transcript.lastReply)]
    }
}

import Foundation

/// User-facing Chinese copy, kept out of the views so it can be tested.
public enum Copy {
    /// Panel header: only the counts that need your attention.
    public static func header(_ sessions: [Session]) -> String? {
        let waiting = sessions.count { $0.state == .waiting }
        let failed = sessions.count { $0.state == .failed }
        let working = sessions.count { $0.state == .working || $0.state == .background }
        var parts: [String] = []
        if waiting > 0 { parts.append("\(waiting) 个待确认") }
        if failed > 0 { parts.append("\(failed) 个出错") }
        if working > 0 { parts.append("\(working) 个在工作") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "刚刚", "3 分", "1 小时 5 分".
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(seconds, 0) / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分"
    }

    /// How long a round took, for the "done" notification: "40 秒", "4 分钟", "1 小时 5 分钟".
    public static func roundLength(_ seconds: TimeInterval) -> String {
        let total = Int(max(seconds, 0))
        if total < 60 { return "\(total) 秒" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) 分钟" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "\(hours) 小时" : "\(hours) 小时 \(rest) 分钟"
    }

    /// The row's second line. Hook events (M2) fill `detail`; until then a working
    /// session shows what it was asked, and the others the start of the last reply.
    /// The previous reply is never shown for a working session: it is stale.
    public static func secondLine(_ session: Session) -> String? {
        if let detail = session.detail { return detail }
        let summary = session.transcript
        let prompt = summary?.lastPrompt.map(Session.promptTitle) == session.title ? nil : summary?.lastPrompt
        if session.state == .working && !session.isEnded { return prompt }
        return summary?.lastReply ?? prompt
    }

    /// The row's "你：" line: what was asked last, unless the title already is that or
    /// AgentBell asked it to start a review or a weekly report.
    public static func asked(_ session: Session) -> String? {
        guard let prompt = lastPrompt(session), session.project.review?.isRequest(prompt) != true,
              session.project.weekly?.isRequest(prompt) != true else { return nil }
        return Session.promptTitle(prompt) == session.title ? nil : prompt
    }

    /// Under it: what the session is doing or waiting for, or how its last round came
    /// out. Just the state's word when there is nothing more to say.
    public static func standing(_ session: Session) -> String {
        let word = statusWord(session)
        guard let line = secondLine(session), line != lastPrompt(session) else { return word }
        return session.state == .completed && !session.isEnded ? "\(word)：\(line)" : line
    }

    public struct Summary: Sendable, Equatable {
        public let text: String
        /// The text is what was asked, so the row puts "你：" in front.
        public let asked: Bool
    }

    /// The row's one line under the title: how the latest round stands. When that is only
    /// the state's word and nothing needs you, what was asked says more.
    public static func summary(_ session: Session) -> Summary {
        let line = standing(session)
        let needsYou = session.state == .waiting || session.state == .failed
        if line == statusWord(session), !needsYou, let asked = asked(session) {
            return Summary(text: asked, asked: true)
        }
        return Summary(text: line, asked: false)
    }

    /// With room for two lines: what was asked, then where it stands. One line when the
    /// other would add nothing, as `summary` decides.
    public static func summaryLines(_ session: Session) -> [Summary] {
        let line = summary(session)
        guard !line.asked, let asked = asked(session) else { return [line] }
        return [Summary(text: asked, asked: true), line]
    }

    private static func lastPrompt(_ session: Session) -> String? {
        session.heardTurns.last?.prompt ?? session.transcript?.turns.last?.prompt ?? session.transcript?.lastPrompt
    }

    /// Where the row's elapsed time counts from. An idle session counts from its last
    /// write, which survives an app restart; a working one from when the work was seen.
    public static func since(_ session: Session) -> Date {
        if let ended = session.endedAt { return ended }
        if session.state == .idle, let modified = session.transcript?.modifiedAt {
            return min(modified, session.stateSince)
        }
        return session.stateSince
    }

    public static func statusWord(_ session: Session) -> String {
        if session.isEnded { return "已结束" }
        switch session.state {
        case .waiting: return "等你"
        case .working: return "在工作"
        case .background: return "后台在跑"
        case .completed: return "做完"
        case .failed: return "出错了"
        case .interrupted: return "已打断"
        case .idle: return "空闲"
        }
    }

    /// VoiceOver: "ai-pet，修复提醒按钮挤在一起，等你，想改 PetSpeech.tsx，3 分".
    public static func accessibilityLabel(_ session: Session, now: Date) -> String {
        [session.project.name, session.title, statusWord(session), secondLine(session), elapsed(now.timeIntervalSince(since(session)))]
            .compactMap { $0 }
            .joined(separator: "，")
    }

    // MARK: - Hook lines (ported from AI Pet)

    static let changing: Set = ["Edit", "Write", "MultiEdit", "NotebookEdit"]
    /// Bookkeeping tools: what it was on before still says more.
    static let unremarkable: Set = ["TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "ToolSearch"]

    /// What a tool about to run is doing; nil when it says nothing new.
    public static func describeTool(_ tool: String, detail: String?) -> String? {
        if unremarkable.contains(tool) { return nil }
        if changing.contains(tool) { return detail.map { "修改 \($0)" } ?? "修改文件" }
        switch tool {
        case "Read": return detail.map { "阅读 \($0)" } ?? "阅读文件"
        case "Bash": return detail ?? "运行命令"
        case "Grep", "Glob": return "搜索代码"
        case "WebFetch", "WebSearch": return "查资料"
        case "Agent", "Task": return detail.map { "子任务：\($0)" } ?? "分派子任务"
        default: return "使用 \(shortToolName(tool))"
        }
    }

    /// What it wants from the user (UI_DESIGN.md §4.4).
    public static func describeAsk(tool: String?, detail: String?) -> String {
        guard let tool else { return "在等你确认" }
        if tool == "AskUserQuestion" { return "有话问你" }
        if tool == "ExitPlanMode" { return "写好计划了，等你过目" }
        if changing.contains(tool), let detail { return "想改 \(detail)，等你点头" }
        if tool == "Read", let detail { return "想读 \(detail)，等你点头" }
        if let detail { return "想用 \(shortToolName(tool))（\(detail)），等你点头" }
        return "想用 \(shortToolName(tool))，等你点头"
    }

    /// Why a round failed, in the user's words.
    public static func failureReason(_ kind: String?) -> String {
        switch kind {
        case "rate_limit": return "额度用完了"
        case "authentication_failed": return "登录失效了，去终端重新登录"
        case "billing_error": return "账户付费出了问题"
        case "server_error": return "Claude 的服务出错了"
        case "max_output_tokens": return "回复太长，被截断了"
        default: return "出错了"
        }
    }

    /// "mcp__server__tool" reads as "tool".
    static func shortToolName(_ tool: String) -> String {
        guard tool.hasPrefix("mcp__"), let range = tool.range(of: "__", options: .backwards) else { return tool }
        let name = String(tool[range.upperBound...])
        return name.isEmpty ? tool : name
    }

    public static func statusItemLabel(_ status: OverallStatus) -> String {
        switch status {
        case .idle: return "AgentBell"
        case .working: return "AgentBell，有会话在工作"
        case .waiting(let count): return "AgentBell，\(count) 个会话等你"
        case .failed: return "AgentBell，有会话出错"
        }
    }
}

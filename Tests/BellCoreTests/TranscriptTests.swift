import Foundation
import Testing
@testable import BellCore

struct TranscriptTests {
    let tail = """
    {"type":"user","message":{"content":"partial line cut by the seek
    {"type":"ai-title","aiTitle":"旧标题","sessionId":"s"}
    {"type":"user","message":{"content":"说到 ai-title 这个词"}}
    {"type":"assistant","message":{"content":[{"type":"text","text":"## 已把 **PID 参数**改成可配置\\n测试全部通过"}]}}
    {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}
    {"type":"ai-title","aiTitle":"重写电机驱动","sessionId":"s"}
    {"type":"last-prompt","lastPrompt":"<pasted_content id=\\"1\\">\\n\\n把 `PID` 参数改成可配置\\n第二行","sessionId":"s"}
    """

    @Test func takesTheLastOfEach() {
        let summary = Transcript.summarize(tail: tail, cutAtStart: true)
        #expect(summary.title == "重写电机驱动")
        #expect(summary.lastPrompt == "把 PID 参数改成可配置")
        #expect(summary.lastReply == "已把 PID 参数改成可配置")
    }

    @Test func recentTurnsPairEachPromptWithItsLastReply() {
        let tail = """
        {"type":"user","timestamp":"2026-11-26T06:39:28.481Z","message":{"content":"好的继续m2的内容"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"先看钩子"}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"M2 做完了。"}]}}
        {"type":"user","isCompactSummary":true,"message":{"content":"This session is being continued"}}
        {"type":"user","timestamp":"2026-11-26T07:56:00.773Z","message":{"content":[{"type":"text","text":"颜色呢[Image #4]"},{"type":"image"}]}}
        {"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"[Image: source: /tmp/x.png]"}]}}
        {"type":"user","message":{"content":"<task-notification>\n<task-id>b1</task-id>"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"颜色正常"}]}}
        {"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}
        """
        let turns = Transcript.summarize(tail: tail, cutAtStart: false).turns
        #expect(turns.map(\.prompt) == ["好的继续m2的内容", "颜色呢"])
        #expect(turns.map(\.reply) == ["M2 做完了", "颜色正常"])
        #expect(turns.first?.at == ISO8601DateFormatter.withFraction.date(from: "2026-11-26T06:39:28.481Z"))
    }

    @Test func keepsOnlyTheLastFewTurns() {
        let tail = (1...8).map { #"{"type":"user","message":{"content":"第 \#($0) 轮"}}"# }.joined(separator: "\n")
        let turns = Transcript.summarize(tail: tail, cutAtStart: false).turns
        #expect(turns.map(\.prompt) == ["第 4 轮", "第 5 轮", "第 6 轮", "第 7 轮", "第 8 轮"])
    }

    @Test func emptyTail() {
        let summary = Transcript.summarize(tail: "", cutAtStart: false)
        #expect(summary.title == nil && summary.lastPrompt == nil && summary.lastReply == nil)
    }

    @Test func firstLineIsCut() {
        let long = String(repeating: "字", count: 100)
        #expect(Transcript.firstLine(long, limit: 80)?.count == 80)
        #expect(Transcript.firstLine(long, limit: 80)?.hasSuffix("…") == true)
        #expect(Transcript.firstLine("  \n<tag>\n- 列表项", limit: 80) == "列表项")
        #expect(Transcript.firstLine("   ", limit: 80) == nil)
        #expect(Transcript.replyLine("## 结论\n\n方案已经写完了。") == "方案已经写完了")
        #expect(Transcript.replyLine("## 结论") == "结论")
        #expect(Transcript.replyLine("## 已把参数改成可配置\n测试通过") == "已把参数改成可配置")
        #expect(Transcript.firstLine("看这个 [Image #2] 列表", limit: 80) == "看这个 列表")
        #expect(Transcript.firstLine("[Pasted text #1 +12 lines]", limit: 80) == nil)
        #expect(Transcript.firstLine("已经提交并发布：v2.0.0-rc-2。", limit: 80) == "已经提交并发布：v2.0.0-rc-2")
    }

    @Test func slugMatchesClaudeCode() {
        #expect(Transcript.slug("/Users/me/ai-workspace/ai-pet") == "-Users-me-ai-workspace-ai-pet")
        #expect(Transcript.slug("/private/tmp/claude-501/-Users-x") == "-private-tmp-claude-501--Users-x")
    }

    @Test func conversationWindowPaginatesAndReadsAppendedLinesOnce() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bell-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: file) }
        let old = #"{"type":"user","message":{"content":"First question"}}"# + "\n"
        let recent = #"{"type":"user","message":{"content":"Second question"}}"# + "\n"
        let partial = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Second reply"}]}}"#
        try (old + recent).write(to: file, atomically: true, encoding: .utf8)
        let latest = try #require(Transcript.conversationWindow(file, initialBytes: UInt64(recent.utf8.count)))
        #expect(latest.hasEarlier)
        #expect(latest.turns.map(\.prompt) == ["Second question"])

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(partial.utf8))
        let incomplete = try #require(Transcript.conversationWindow(file, previous: latest))
        #expect(incomplete.turns.last?.reply == "")
        try handle.write(contentsOf: Data("\n".utf8))
        let appended = try #require(Transcript.conversationWindow(file, previous: incomplete))
        #expect(appended.turns.map(\.reply) == ["Second reply"])
        #expect(appended.turns.last?.sourceOffset == latest.turns.last?.sourceOffset)

        let expanded = try #require(Transcript.conversationWindow(file, previous: appended, loadEarlier: true))
        #expect(!expanded.hasEarlier)
        #expect(expanded.turns.map(\.prompt) == ["First question", "Second question"])
        #expect(expanded.turns.last == appended.turns.last)
    }

    @Test func locatesAndReadsFile() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent("bell-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: projects) }
        // Not in the folder the cwd implies: found by searching.
        let folder = projects.appendingPathComponent("-somewhere-else")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("abc.jsonl")
        try "{\"type\":\"ai-title\",\"aiTitle\":\"标题\"}\n".write(to: file, atomically: true, encoding: .utf8)

        let found = Transcript.locate(sessionID: "abc", cwd: "/p", in: projects)
        #expect(found?.lastPathComponent == "abc.jsonl")
        #expect(Transcript.read(file)?.title == "标题")
        #expect(Transcript.locate(sessionID: "../abc", cwd: "/p", in: projects) == nil)
        #expect(Transcript.locate(sessionID: "missing", cwd: "/p", in: projects) == nil)
    }
}

struct SessionTitleTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func session(name: String?, cwd: String = "/w/ai-pet", state: RoundState = .idle, summary: TranscriptSummary?) -> Session {
        Session(id: "x", pid: 1, cwd: cwd, project: ProjectInfo(root: cwd, branch: nil), name: name,
                startedAt: t0, state: state, stateSince: t0 + 100, transcript: summary)
    }

    @Test func generatedNameIsSkipped() {
        #expect(Session.isGeneratedName("ai-pet-7f", cwd: "/w/ai-pet"))
        #expect(!Session.isGeneratedName("修复提醒", cwd: "/w/ai-pet"))
        #expect(!Session.isGeneratedName("ai-pet-refactor", cwd: "/w/ai-pet"))
    }

    /// Claude Code names a session after the folder it started in. Moved into one of the
    /// project's worktrees, the name no longer starts with the cwd's folder, only the project's.
    @Test func generatedNameSurvivesAMoveIntoAWorktree() {
        let cwd = "/w/agent-bell/.claude/worktrees/weekly-report"
        let moved = Session(id: "x", pid: 1, cwd: cwd, project: ProjectInfo(root: "/w/agent-bell", branch: nil),
                            name: "agent-bell-93", startedAt: t0, state: .idle, stateSince: t0,
                            transcript: TranscriptSummary(title: "周报功能", modifiedAt: t0))
        #expect(moved.title == "周报功能")
    }

    @Test func titleOrder() {
        let summary = TranscriptSummary(title: "重写电机驱动", lastPrompt: "把参数改成可配置", modifiedAt: t0)
        #expect(session(name: "我的名字", summary: summary).title == "我的名字")
        #expect(session(name: "ai-pet-7f", summary: summary).title == "重写电机驱动")
        #expect(session(name: "ai-pet-7f", summary: TranscriptSummary(lastPrompt: "把参数改成可配置", modifiedAt: t0)).title == "把参数改成可配置")
        #expect(session(name: "ai-pet-7f", summary: nil).title == "新会话")
        // A brand-new session has written nothing yet, but the hook heard its prompt.
        var fresh = session(name: "ai-pet-7f", summary: nil)
        fresh.heardTurns = [TranscriptTurn(prompt: "修复提醒按钮")]
        #expect(fresh.title == "修复提醒按钮")
        // A slash command names a tool, not the work: the words after it do.
        fresh.heardTurns = [TranscriptTurn(prompt: "/unslop:unslop 分析一下标题")]
        #expect(fresh.title == "分析一下标题")
        #expect(Copy.asked(fresh) == nil)
        fresh.heardTurns = [TranscriptTurn(prompt: "/review")]
        #expect(fresh.title == "/review")
    }

    @Test func namesTheUserGaveOutrankClaudes() {
        let tail = """
        {"type":"custom-title","customTitle":"玩法优化","sessionId":"s"}
        {"type":"ai-title","aiTitle":"重写电机驱动","sessionId":"s"}
        """
        let summary = Transcript.summarize(tail: tail, cutAtStart: false)
        #expect(summary.customTitle == "玩法优化")
        #expect(summary.title == "重写电机驱动")
        // A /rename survives the session closing, when `claude agents` no longer names it.
        var renamed = session(name: nil, summary: summary)
        #expect(renamed.title == "玩法优化")
        // A name given in AgentBell comes before every other.
        renamed.alias = "支付重构"
        #expect(session(name: "我的名字", summary: summary).title == "我的名字")
        #expect(renamed.title == "支付重构")
    }

    /// A review runs with AgentBell's prompt and gets no title of Claude's: what it
    /// reviews names it, below any name the user gave.
    @Test func reviewIsNamedAfterWhatItReviews() {
        let request = "用简体中文审查以下改动。优先检查业务逻辑。"
        let review = ReviewCheckout(sourceBranch: "feat/x", targetBranch: "main", prompt: request)
        let summary = TranscriptSummary(lastPrompt: request + " 源分支：feat/x", lastReply: "没有发现问题", modifiedAt: t0)
        var reviewing = session(name: nil, summary: summary)
        reviewing.project.review = review
        #expect(reviewing.title == "审查 feat/x")
        // AgentBell's own prompt is not the user's question.
        #expect(Copy.asked(reviewing) == nil)
        reviewing.transcript?.lastPrompt = "第二条再解释一下"
        #expect(Copy.asked(reviewing) == "第二条再解释一下")
        // Claude's title says less than the range; the user's names say more.
        reviewing.transcript?.title = "Review retry changes"
        #expect(reviewing.title == "审查 feat/x")
        reviewing.transcript?.customTitle = "重试审查"
        #expect(reviewing.title == "重试审查")
        // A checkout from before review.json cannot say what it reviews.
        var older = session(name: nil, summary: summary)
        older.project.review = ReviewCheckout()
        #expect(older.title == "代码审查")
    }

    @Test func secondLineFollowsState() {
        let summary = TranscriptSummary(title: "重写电机驱动", lastPrompt: "跑一下测试", lastReply: "测试全部通过", modifiedAt: t0)
        #expect(Copy.secondLine(session(name: nil, state: .working, summary: summary)) == "跑一下测试")
        #expect(Copy.secondLine(session(name: nil, state: .idle, summary: summary)) == "测试全部通过")
        // The prompt is already the title: don't say it twice.
        let untitled = TranscriptSummary(lastPrompt: "跑一下测试", modifiedAt: t0)
        #expect(Copy.secondLine(session(name: nil, state: .working, summary: untitled)) == nil)
    }

    @Test func rowSaysTheQuestionThenWhereItStands() {
        let summary = TranscriptSummary(title: "重写电机驱动", lastPrompt: "跑一下测试", lastReply: "测试全部通过", modifiedAt: t0)
        #expect(Copy.asked(session(name: nil, summary: summary)) == "跑一下测试")
        #expect(Copy.standing(session(name: nil, state: .idle, summary: summary)) == "测试全部通过")
        #expect(Copy.standing(session(name: nil, state: .completed, summary: summary)) == "做完：测试全部通过")
        // A working session's own line is the question again: the state's word says more.
        #expect(Copy.standing(session(name: nil, state: .working, summary: summary)) == "在工作")
        var waiting = session(name: nil, state: .waiting, summary: summary)
        waiting.detail = "想改 a.swift，等你点头"
        #expect(Copy.standing(waiting) == "想改 a.swift，等你点头")
        // The question is already the title: the row does not repeat it.
        let untitled = TranscriptSummary(lastPrompt: "跑一下测试", modifiedAt: t0)
        #expect(Copy.asked(session(name: nil, summary: untitled)) == nil)
        #expect(Copy.standing(session(name: nil, summary: nil)) == "空闲")
    }

    @Test func rowSummaryIsOneLine() {
        let summary = TranscriptSummary(title: "重写电机驱动", lastPrompt: "跑一下测试", lastReply: "测试全部通过", modifiedAt: t0)
        #expect(Copy.summary(session(name: nil, state: .completed, summary: summary)) == .init(text: "做完：测试全部通过", asked: false))
        // The state's word alone says less than the question it is working on.
        #expect(Copy.summary(session(name: nil, state: .working, summary: summary)) == .init(text: "跑一下测试", asked: true))
        // Waiting keeps its own words, even when they are only the state's word.
        let unanswered = TranscriptSummary(title: "重写电机驱动", lastPrompt: "跑一下测试", modifiedAt: t0)
        #expect(Copy.summary(session(name: nil, state: .waiting, summary: unanswered)) == .init(text: "等你", asked: false))
        // Nothing asked beyond the title: the state's word is all there is.
        let untitled = TranscriptSummary(lastPrompt: "跑一下测试", modifiedAt: t0)
        #expect(Copy.summary(session(name: nil, state: .working, summary: untitled)) == .init(text: "在工作", asked: false))
    }

    @Test func wideRowSaysTheQuestionAndWhereItStands() {
        let summary = TranscriptSummary(title: "重写电机驱动", lastPrompt: "跑一下测试", lastReply: "测试全部通过", modifiedAt: t0)
        #expect(Copy.summaryLines(session(name: nil, state: .completed, summary: summary))
            == [.init(text: "跑一下测试", asked: true), .init(text: "做完：测试全部通过", asked: false)])
        var waiting = session(name: nil, state: .waiting, summary: summary)
        waiting.detail = "想改 a.swift，等你点头"
        #expect(Copy.summaryLines(waiting)
            == [.init(text: "跑一下测试", asked: true), .init(text: "想改 a.swift，等你点头", asked: false)])
        // The state's word alone adds nothing to the lamp: the question is the one line.
        #expect(Copy.summaryLines(session(name: nil, state: .working, summary: summary))
            == [.init(text: "跑一下测试", asked: true)])
        // Nothing asked beyond the title: where it stands is the one line.
        let untitled = TranscriptSummary(lastPrompt: "跑一下测试", lastReply: "测试全部通过", modifiedAt: t0)
        #expect(Copy.summaryLines(session(name: nil, state: .idle, summary: untitled))
            == [.init(text: "测试全部通过", asked: false)])
    }

    @Test func idleCountsFromLastWrite() {
        let summary = TranscriptSummary(modifiedAt: t0 + 10)
        #expect(Copy.since(session(name: nil, summary: summary)) == t0 + 10)
        #expect(Copy.since(session(name: nil, state: .working, summary: summary)) == t0 + 100)
    }
}

struct RecentTurnsTests {
    func session(heard: [TranscriptTurn] = [], transcript: TranscriptSummary? = nil) -> Session {
        var session = Session(
            id: "s", pid: 1, cwd: "/p", project: ProjectInfo(root: "/p", branch: nil),
            startedAt: .distantPast, state: .idle, stateSince: .distantPast, transcript: transcript
        )
        session.heardTurns = heard
        return session
    }

    @Test func hooksFirstThenTheTailThenTheLastPrompt() {
        var tail = TranscriptSummary(lastPrompt: "最后一问", lastReply: "最后一答", modifiedAt: .distantPast)
        #expect(session(transcript: tail).recentTurns == [TranscriptTurn(prompt: "最后一问", reply: "最后一答")])
        tail.turns = [TranscriptTurn(prompt: "末尾里的")]
        #expect(session(transcript: tail).recentTurns.map(\.prompt) == ["末尾里的"])
        #expect(session(heard: [TranscriptTurn(prompt: "钩子听到的")], transcript: tail).recentTurns.map(\.prompt) == ["钩子听到的"])
        #expect(session().recentTurns.isEmpty)
    }
}

struct ConversationTests {
    @Test func pairsEachFullPromptWithTheLastReplyOfItsRound() {
        let text = """
        {"type":"assistant","message":{"content":[{"type":"text","text":"reply before any prompt"}]}}
        {"type":"user","timestamp":"2026-11-26T06:39:28.481Z","message":{"content":"第一行问题\\n第二行补充[Image #2]"}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"先看代码。"},{"type":"tool_use","name":"Read"}]}}
        {"type":"user","message":{"content":[{"type":"tool_result","content":"ok"}]}}
        {"type":"assistant","message":{"content":[{"type":"text","text":"## 结论\\n能做。"}]}}
        {"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"[Image: source: /tmp/x.png]"}]}}
        {"type":"user","message":{"content":"<command-name>/model</command-name>"}}
        {"type":"user","message":{"content":"<task-notification>\\n<task-id>b1</task-id>"}}
        {"type":"user","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}
        {"type":"user","isSidechain":true,"message":{"content":"子任务收到的提示"}}
        {"type":"user","message":{"content":[{"type":"text","text":"继续"},{"type":"image"}]}}
        """
        let turns = Transcript.conversation(Data(text.utf8))
        #expect(turns.map(\.prompt) == ["第一行问题\n第二行补充", "继续"])
        #expect(turns.map(\.reply) == ["## 结论\n能做。", ""])
        #expect(turns.first?.at == ISO8601DateFormatter.withFraction.date(from: "2026-11-26T06:39:28.481Z"))
    }

    @Test func keepsEveryRoundHoweverMuchToolOutputLiesBetween() {
        let output = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"\#(String(repeating: "x", count: 4096))"}]}}"#
        let rounds = (1...30).flatMap { [#"{"type":"user","message":{"content":"第 \#($0) 轮"}}"#] + Array(repeating: output, count: 20) }
        let turns = Transcript.conversation(Data(rounds.joined(separator: "\n").utf8))
        #expect(turns.count == 30)
        #expect(turns.first?.prompt == "第 1 轮" && turns.last?.prompt == "第 30 轮")
    }

    @Test func emptyFile() {
        #expect(Transcript.conversation(Data()).isEmpty)
    }
}

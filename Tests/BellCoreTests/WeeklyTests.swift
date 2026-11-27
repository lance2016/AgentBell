import Foundation
import Testing
@testable import BellCore

struct WeeklyTests {
    let shanghai = TimeZone(identifier: "Asia/Shanghai")!
    /// Friday 27 November 2026, noon in Shanghai.
    let friday = ISO8601DateFormatter().date(from: "2026-11-27T04:00:00Z")!

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("weekly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Period

    @Test func weeksRunMondayToSunday() {
        let this = WeeklyPeriod.thisWeek.interval(now: friday, timeZone: shanghai)
        #expect(this.start == date("2026-11-22T16:00:00Z"))
        #expect(this.end == date("2026-11-29T16:00:00Z"))
        #expect(WeeklyPeriod.days(this, timeZone: shanghai) == "11月23日 – 11月29日")

        let last = WeeklyPeriod.lastWeek.interval(now: friday, timeZone: shanghai)
        #expect(last.start == date("2026-11-15T16:00:00Z"))
        #expect(last.end == this.start)
        #expect(WeeklyPeriod.days(last, timeZone: shanghai) == "11月16日 – 11月22日")
    }

    /// Sunday night is still this week; Monday morning starts the next.
    @Test func sundayBelongsToItsOwnWeek() {
        let sunday = date("2026-11-29T15:30:00Z")
        #expect(WeeklyPeriod.thisWeek.interval(now: sunday, timeZone: shanghai).start == date("2026-11-22T16:00:00Z"))
        let monday = date("2026-11-29T16:30:00Z")
        #expect(WeeklyPeriod.lastWeek.interval(now: monday, timeZone: shanghai).start == date("2026-11-22T16:00:00Z"))
    }

    // MARK: - Sessions

    @Test func reportSessionsListUnderOneProject() throws {
        let root = try folder()
        let reports = root.appendingPathComponent("周报")
        let workspace = reports.appendingPathComponent("W1")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try WeeklyCheckout(days: "11月23日 – 11月29日", prompt: "写一份周报").write(in: workspace)

        let info = ProjectInfo.lookup(cwd: workspace.path, reports: reports.path)
        #expect(info.name == "周报")
        #expect(info.weekly?.title == "周报 11月23日 – 11月29日")
        #expect(info.weekly?.isRequest("写一份周报 以下是会话记录") == true)
        #expect(info.weekly?.isRequest("把第二条写详细点") == false)
        #expect(ProjectInfo.lookup(cwd: root.path, reports: reports.path).weekly == nil)
    }

    // MARK: - Material

    private func transcript(_ lines: [String], named name: String, in projects: URL, modified: Date? = nil) throws {
        let folder = projects.appendingPathComponent("-p-\(name)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("\(name).jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }
    }

    private func prompt(_ text: String, at: String, cwd: String, entrypoint: String = "cli") -> String {
        #"{"type":"user","cwd":"\#(cwd)","gitBranch":"feat/close","entrypoint":"\#(entrypoint)","timestamp":"\#(at)","message":{"role":"user","content":"\#(text)"}}"#
    }

    private func reply(_ text: String, at: String) -> String {
        #"{"type":"assistant","timestamp":"\#(at)","message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
    }

    @Test func materialIsTheWeeksOwnRounds() throws {
        let projects = try folder()
        let week = WeeklyPeriod.thisWeek.interval(now: friday, timeZone: shanghai)
        try transcript([
            prompt("旧问题", at: "2026-11-20T02:00:00.000Z", cwd: "/work/agent-bell"),
            reply("旧回答", at: "2026-11-20T02:01:00.000Z"),
            prompt("关闭会话关不了", at: "2026-11-24T02:00:00.000Z", cwd: "/work/agent-bell"),
            reply("已修复：原生安装的进程名是版本号。", at: "2026-11-24T02:05:00.000Z"),
            #"{"type":"ai-title","aiTitle":"修复关闭会话","sessionId":"a"}"#,
        ], named: "a", in: projects)
        // A `-p` run, such as a review AgentBell started.
        try transcript([prompt("审查", at: "2026-11-24T03:00:00.000Z", cwd: "/work/agent-bell", entrypoint: "sdk-cli")],
                       named: "b", in: projects)
        // A session AgentBell's own folders host.
        try transcript([prompt("把第二条写详细点", at: "2026-11-24T04:00:00.000Z", cwd: "/bell/周报/W1")],
                       named: "c", in: projects)
        // Untouched since before the week.
        try transcript([prompt("更早", at: "2026-11-24T05:00:00.000Z", cwd: "/work/other")],
                       named: "d", in: projects, modified: date("2026-11-10T00:00:00Z"))

        let material = WeeklyMaterial.collect(in: week, projects: projects, excluding: ["/bell"])
        #expect(material.sessionCount == 1)
        #expect(material.turnCount == 1)
        let item = try #require(material.items.first)
        #expect(item.project == "agent-bell")
        #expect(item.branch == "feat/close")
        #expect(item.title == "修复关闭会话")

        let text = material.rendered(timeZone: shanghai)
        #expect(text.contains("## 项目：agent-bell"))
        #expect(text.contains("### 会话：修复关闭会话（分支 feat/close）"))
        #expect(text.contains("11月24日 周二 10:00 问：关闭会话关不了"))
        #expect(text.contains("答：已修复：原生安装的进程名是版本号。"))
        #expect(!text.contains("旧问题"))
    }

    @Test func renderingKeepsToItsBudget() {
        let turns = (0..<50).map {
            ConversationTurn(prompt: String(repeating: "问", count: 500), reply: String(repeating: "答", count: 500),
                             at: date("2026-11-24T02:00:\(String(format: "%02d", $0))Z"))
        }
        let material = WeeklyMaterial(items: [.init(root: "/w/p", project: "p", branch: nil, title: nil, turns: turns)])
        let roomy = material.rendered(budget: 1_000_000)
        #expect(roomy.contains(String(repeating: "问", count: 399) + "…"))
        let tight = material.rendered(budget: 20_000)
        #expect(tight.count < 20_100)
        #expect(tight.contains(String(repeating: "问", count: 159) + "…"))
        #expect(material.rendered(budget: 2_000).hasSuffix("（素材太多，后面的已省略）"))
    }

    /// Two projects of one name stay apart; leaving one out keeps the other.
    @Test func projectsCanBeLeftOut() {
        let turn = ConversationTurn(prompt: "问", reply: "答", at: friday)
        let material = WeeklyMaterial(items: [
            .init(root: "/work/app", project: "app", branch: nil, title: "a", turns: [turn, turn]),
            .init(root: "/home/app", project: "app", branch: nil, title: "b", turns: [turn]),
            .init(root: "/work/app", project: "app", branch: nil, title: "c", turns: [turn]),
        ])
        #expect(material.projects.map(\.root) == ["/work/app", "/home/app"])
        #expect(material.projects.map(\.sessionCount) == [2, 1])
        #expect(material.projects.map(\.turnCount) == [3, 1])

        let kept = material.excluding(["/home/app"])
        #expect(kept.sessionCount == 2)
        #expect(kept.projectCount == 1)
        #expect(!kept.rendered().contains("会话：b"))
    }

    // MARK: - Prompt, run and archive

    @Test func templateFillsInTheWeek() {
        let prompt = WeeklyRunner.prompt(template: "{{period}}周报 {{days}}，{{next_period}}计划",
                                         period: .lastWeek, days: "11月16日 – 11月22日")
        #expect(prompt == "上周周报 11月16日 – 11月22日，本周计划")
        let fallback = WeeklyRunner.prompt(template: "  ", period: .thisWeek, days: "d")
        #expect(fallback.contains("本周工作周报（d）"))
        #expect(fallback.contains("1. 本周工作进展："))
        #expect(fallback.contains("3. 下周工作计划："))
    }

    @Test func runsClaudeWithoutToolsAndKeepsTheSession() async throws {
        let root = try folder()
        let claude = root.appendingPathComponent("claude")
        try Data("""
        #!/bin/sh
        case " $* " in *" --tools  --disallowedTools "*) ;; *) exit 11 ;; esac
        input=$(cat)
        printf '%s' "$input" | grep -q '^写周报$' || exit 12
        printf '%s' "$input" | grep -q '关闭会话关不了' || exit 13
        [ -f weekly.json ] || exit 14
        printf '%s' '{"is_error":false,"result":"## 本周完成\\n- 修好关闭会话","session_id":"weekly-session"}'
        """.utf8).write(to: claude)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: claude.path)

        let outcome = try await WeeklyRunner.run(
            material: "- 问：关闭会话关不了", prompt: "写周报", days: "11月23日 – 11月29日",
            claude: claude, model: .recommended, root: root.appendingPathComponent("周报")
        )
        #expect(outcome.report == "## 本周完成\n- 修好关闭会话")
        #expect(outcome.sessionID == "weekly-session")
        #expect(WeeklyCheckout.read(folder: outcome.workspace.path).days == "11月23日 – 11月29日")
        #expect(!FileManager.default.fileExists(atPath: outcome.workspace.appendingPathComponent("weekly-input.txt").path))
    }

    @Test func archiveKeepsEdits() throws {
        let archive = WeeklyArchive(root: try folder())
        let outcome = WeeklyOutcome(report: "初稿", sessionID: "s", workspace: URL(fileURLWithPath: "/tmp/w"))
        let record = WeeklyRecord(
            id: "r1", period: .thisWeek, interval: WeeklyPeriod.thisWeek.interval(now: friday, timeZone: shanghai),
            model: .opus, material: WeeklyMaterial(items: []), outcome: outcome, startedAt: friday
        )
        let saved = try archive.save(record, report: outcome.report)
        try archive.write("改过的", to: saved)

        let loaded = try #require(archive.load().first)
        #expect(loaded.id == "r1")
        #expect(loaded.period == .thisWeek)
        #expect(loaded.sessionID == "s")
        #expect(archive.report(loaded) == "改过的")
        try archive.delete(loaded)
        #expect(archive.load().isEmpty)
    }
}

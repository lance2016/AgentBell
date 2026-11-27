import Foundation

/// What a weekly report is written from: the rounds of the user's own Claude Code
/// sessions in that week, each its question and Claude's closing answer.
public struct WeeklyMaterial: Sendable {
    public struct Item: Sendable {
        /// The project's folder, which tells apart two projects of the same name.
        public let root: String
        public let project: String
        public let branch: String?
        public let title: String?
        public let turns: [ConversationTurn]
    }

    /// A project the week's sessions ran in, for picking which go into the report.
    public struct Project: Sendable, Identifiable {
        public let root: String
        public let name: String
        public let sessionCount: Int
        public let turnCount: Int
        public var id: String { root }
    }

    public let items: [Item]

    public var sessionCount: Int { items.count }
    public var turnCount: Int { items.reduce(0) { $0 + $1.turns.count } }
    public var projectCount: Int { Set(items.map(\.root)).count }

    /// In the order the week first touched them.
    public var projects: [Project] {
        var roots: [String] = []
        for item in items where !roots.contains(item.root) { roots.append(item.root) }
        return roots.map { root in
            let sessions = items.filter { $0.root == root }
            return Project(root: root, name: sessions[0].project, sessionCount: sessions.count,
                           turnCount: sessions.reduce(0) { $0 + $1.turns.count })
        }
    }

    /// Without the sessions of these projects.
    public func excluding(_ roots: Set<String>) -> WeeklyMaterial {
        WeeklyMaterial(items: items.filter { !roots.contains($0.root) })
    }

    /// The first line holding `cwd` is this far into the file at most.
    static let headBytes = 1024 * 1024

    /// Reads every transcript touched since the week began. Sessions AgentBell ran
    /// (reviews, reports, any `-p` run) and those under `excluding` are left out.
    public static func collect(
        in interval: DateInterval,
        projects: URL = Transcript.projectsDirectory,
        excluding: [String] = [BellPaths.supportDirectory.path]
    ) -> WeeklyMaterial {
        let excluded = excluding.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath().path + "/" }
        let fileManager = FileManager.default
        let folders = (try? fileManager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        var items: [(start: Date, item: Item)] = []
        for folder in folders {
            let files = (try? fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            )) ?? []
            for file in files where file.pathExtension == "jsonl" {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                guard let modified, modified >= interval.start, let origin = origin(of: file),
                      !origin.entrypoint.hasPrefix("sdk"),
                      !excluded.contains(where: { (origin.cwd + "/").hasPrefix($0) })
                else { continue }
                let turns = Transcript.conversation(file).filter { $0.at.map(interval.contains) ?? false }
                guard let first = turns.first?.at else { continue }
                let summary = Transcript.read(file)
                let project = ProjectInfo.lookup(cwd: origin.cwd)
                items.append((first, Item(root: project.root, project: project.name, branch: origin.branch,
                                          title: summary?.customTitle ?? summary?.title, turns: turns)))
            }
        }
        return WeeklyMaterial(items: items.sorted { $0.start < $1.start }.map(\.item))
    }

    /// Where the session ran and how it was started, from its first line that says so.
    static func origin(of file: URL) -> (cwd: String, branch: String?, entrypoint: String)? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        for line in head.split(separator: 0x0A) where line.range(of: Data(#""cwd""#.utf8)) != nil {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let cwd = object["cwd"] as? String else { continue }
            let branch = (object["gitBranch"] as? String).flatMap { $0.isEmpty || $0 == "HEAD" ? nil : $0 }
            return (cwd, branch, object["entrypoint"] as? String ?? "cli")
        }
        return nil
    }

    // MARK: - Rendering

    /// Each project's sessions under its name, each round a dated question and answer.
    /// Past `budget` characters the rounds are cut shorter, then the rest dropped.
    public func rendered(budget: Int = 120_000, timeZone: TimeZone = .current) -> String {
        for limits in [(prompt: 400, reply: 300), (prompt: 160, reply: 100)] {
            let text = render(promptLimit: limits.prompt, replyLimit: limits.reply, timeZone: timeZone)
            if text.count <= budget { return text }
        }
        let text = render(promptLimit: 160, replyLimit: 100, timeZone: timeZone)
        return String(text.prefix(budget)) + "\n\n（素材太多，后面的已省略）"
    }

    private func render(promptLimit: Int, replyLimit: Int, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 EEE HH:mm"
        return projects.map { project in
            let sessions = items.filter { $0.root == project.root }.map { item in
                var heading = "### 会话：\(item.title ?? "未命名")"
                if let branch = item.branch { heading += "（分支 \(branch)）" }
                let rounds = item.turns.map { turn in
                    let at = turn.at.map { formatter.string(from: $0) + " " } ?? ""
                    var round = "- \(at)问：\(Self.clip(turn.prompt, promptLimit))"
                    if !turn.reply.isEmpty { round += "\n  答：\(Self.clip(turn.reply, replyLimit))" }
                    return round
                }
                return ([heading] + rounds).joined(separator: "\n")
            }
            return (["## 项目：\(project.name)"] + sessions).joined(separator: "\n\n")
        }
        .joined(separator: "\n\n")
    }

    /// One line, at most `limit` characters.
    static func clip(_ text: String, _ limit: Int) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
    }
}

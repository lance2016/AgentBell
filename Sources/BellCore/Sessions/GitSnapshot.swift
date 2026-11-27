import Foundation

/// What a session's working copy looks like right now, for the session detail. Read on
/// demand with `git`, unlike `ProjectInfo`, which reads `.git` directly on every poll.
public struct GitSnapshot: Sendable, Equatable {
    public struct FileChange: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            case modified, added, deleted, renamed, conflicted, untracked
        }

        public let path: String
        public let kind: Kind
        /// Line counts against HEAD; nil for untracked and binary files.
        public var added: Int?
        public var deleted: Int?

        public init(path: String, kind: Kind, added: Int? = nil, deleted: Int? = nil) {
            self.path = path
            self.kind = kind
            self.added = added
            self.deleted = deleted
        }
    }

    public struct Commit: Sendable, Equatable {
        public let subject: String
        public let date: Date

        public init(subject: String, date: Date) {
            self.subject = subject
            self.date = date
        }
    }

    /// Nil on a detached HEAD.
    public var branch: String?
    public var upstream: String?
    public var ahead = 0
    public var behind = 0
    public var changes: [FileChange] = []
    public var lastCommit: Commit?

    /// Where `git` is, without touching `/usr/bin/git`: on a Mac without developer tools
    /// that stub asks to install them.
    static let gitCandidates = [
        "/opt/homebrew/bin/git",
        "/usr/local/bin/git",
        "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    ]

    /// Nil when `cwd` is not in a repository or git cannot be found.
    public static func load(cwd: String) async -> GitSnapshot? {
        guard let git = gitCandidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let url = URL(fileURLWithPath: git)
        // No optional locks: a status taken while Claude runs git must not block it.
        let base = ["-C", cwd, "--no-optional-locks", "-c", "core.quotepath=off"]
        async let status = output(url, base + ["status", "--porcelain=v2", "--branch"])
        async let numstat = output(url, base + ["diff", "HEAD", "--numstat", "--no-renames"])
        async let log = output(url, base + ["log", "-1", "--format=%s%x1f%ct"])
        guard let status = await status else { return nil }
        return parse(status: status, numstat: await numstat ?? "", log: await log ?? "")
    }

    private static func output(_ git: URL, _ arguments: [String]) async -> String? {
        guard let result = try? await ProcessRunner.run(git, arguments: arguments, timeout: 5),
              result.exitCode == 0 else { return nil }
        return String(decoding: result.standardOutput, as: UTF8.self)
    }

    /// - Parameters:
    ///   - status: `git status --porcelain=v2 --branch`
    ///   - numstat: `git diff HEAD --numstat --no-renames`
    ///   - log: `git log -1 --format=%s%x1f%ct`
    static func parse(status: String, numstat: String, log: String) -> GitSnapshot? {
        var snapshot = GitSnapshot()
        var sawHead = false
        for line in status.split(separator: "\n") {
            if line.hasPrefix("# ") {
                let parts = line.dropFirst(2).split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                switch parts[0] {
                case "branch.head":
                    sawHead = true
                    snapshot.branch = parts[1] == "(detached)" ? nil : parts[1]
                case "branch.upstream":
                    snapshot.upstream = parts[1]
                case "branch.ab":
                    let counts = parts[1].split(separator: " ").compactMap { Int($0.dropFirst()) }
                    if counts.count == 2 { (snapshot.ahead, snapshot.behind) = (counts[0], counts[1]) }
                default:
                    break
                }
            } else if let change = fileChange(line) {
                snapshot.changes.append(change)
            }
        }
        guard sawHead else { return nil }

        let counts = lineCounts(numstat)
        snapshot.changes = snapshot.changes.map { change in
            var change = change
            if let (added, deleted) = counts[change.path] {
                change.added = added
                change.deleted = deleted
            }
            return change
        }
        let commit = log.trimmingCharacters(in: .newlines).split(separator: "\u{1F}", omittingEmptySubsequences: false)
        if commit.count == 2, let seconds = TimeInterval(commit[1]) {
            snapshot.lastCommit = Commit(subject: String(commit[0]), date: Date(timeIntervalSince1970: seconds))
        }
        return snapshot
    }

    /// One porcelain v2 entry: the path follows a fixed number of fields per entry type.
    private static func fileChange(_ line: Substring) -> FileChange? {
        let fieldsBeforePath: Int
        switch line.first {
        case "1": fieldsBeforePath = 8
        case "2": fieldsBeforePath = 9
        case "u": fieldsBeforePath = 10
        case "?": return FileChange(path: String(line.dropFirst(2)), kind: .untracked)
        default: return nil
        }
        let fields = line.split(separator: " ", maxSplits: fieldsBeforePath, omittingEmptySubsequences: false)
        guard fields.count == fieldsBeforePath + 1 else { return nil }
        // A rename's path is "new<TAB>old".
        let path = String(fields[fieldsBeforePath].split(separator: "\t").first ?? "")
        let xy = Array(fields[1])
        let code = xy.first == "." ? xy.last : xy.first
        let kind: FileChange.Kind
        switch (line.first, code) {
        case ("u", _): kind = .conflicted
        case (_, "A"), (_, "C"): kind = .added
        case (_, "D"): kind = .deleted
        case (_, "R"): kind = .renamed
        default: kind = .modified
        }
        return FileChange(path: path, kind: kind)
    }

    /// "added<TAB>deleted<TAB>path"; binary files read "-" and get no counts.
    private static func lineCounts(_ numstat: String) -> [String: (Int, Int)] {
        var counts: [String: (Int, Int)] = [:]
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3, let added = Int(parts[0]), let deleted = Int(parts[1]) else { continue }
            counts[String(parts[2])] = (added, deleted)
        }
        return counts
    }
}

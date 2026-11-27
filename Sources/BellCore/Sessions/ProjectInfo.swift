import Foundation

/// The project folder a session belongs to, and the branch checked out there.
public struct ProjectInfo: Sendable, Equatable, Codable {
    /// Repository root, or the session's cwd when it is not inside a repository.
    /// For a linked worktree this is the main repository, so worktrees of one project
    /// group together.
    public let root: String
    public let branch: String?

    public init(root: String, branch: String?) {
        self.root = root
        self.branch = branch
    }

    public var name: String { (root as NSString).lastPathComponent }

    /// Reads `.git` directly instead of running `git`: a couple of small file reads per
    /// poll, no child process.
    ///
    /// The search stops below `home`: a repository in the home folder is a dotfiles repo,
    /// and treating it as the project would lump every non-repo folder into one group.
    public static func lookup(cwd: String, home: String = NSHomeDirectory()) -> ProjectInfo {
        var directory = (cwd as NSString).standardizingPath
        let home = (home as NSString).standardizingPath
        while directory != home {
            let dotGit = (directory as NSString).appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    return ProjectInfo(root: directory, branch: branch(gitDir: dotGit))
                }
                if let gitDir = linkedGitDir(dotGitFile: dotGit, in: directory) {
                    return ProjectInfo(root: mainRoot(gitDir: gitDir) ?? directory, branch: branch(gitDir: gitDir))
                }
            }
            let parent = (directory as NSString).deletingLastPathComponent
            if parent == directory || parent.isEmpty { break }
            directory = parent
        }
        return ProjectInfo(root: cwd, branch: nil)
    }

    /// `.git` as a file holds `gitdir: <path>` (worktrees and submodules).
    private static func linkedGitDir(dotGitFile: String, in directory: String) -> String? {
        guard let text = try? String(contentsOfFile: dotGitFile, encoding: .utf8) else { return nil }
        let prefix = "gitdir:"
        guard let line = text.split(separator: "\n").first, line.hasPrefix(prefix) else { return nil }
        let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        let absolute = path.hasPrefix("/") ? path : (directory as NSString).appendingPathComponent(path)
        return (absolute as NSString).standardizingPath
    }

    /// `<main>/.git/worktrees/<name>` belongs to `<main>`. Submodules keep their own folder.
    private static func mainRoot(gitDir: String) -> String? {
        guard let range = gitDir.range(of: "/.git/worktrees/") else { return nil }
        return String(gitDir[..<range.lowerBound])
    }

    static func branch(gitDir: String) -> String? {
        let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
        guard let head = try? String(contentsOfFile: headPath, encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        let refPrefix = "ref: refs/heads/"
        if trimmed.hasPrefix(refPrefix) { return String(trimmed.dropFirst(refPrefix.count)) }
        // Detached HEAD: a commit hash.
        return trimmed.isEmpty ? nil : String(trimmed.prefix(7))
    }
}

/// An existing checkout that can be used to start a session.
public struct ProjectCheckout: Sendable, Equatable, Identifiable {
    public let path: String
    public let branch: String?
    public var id: String { path }

    public static func list(root: String) async -> [Self] {
        let fallback = Self(path: root, branch: ProjectInfo.lookup(cwd: root).branch)
        if let git = GitSnapshot.gitCandidates.first(where: FileManager.default.isExecutableFile(atPath:)),
           let result = try? await ProcessRunner.run(
               URL(fileURLWithPath: git),
               arguments: ["-C", root, "worktree", "list", "--porcelain", "-z"],
               timeout: 5
           ), result.exitCode == 0 {
            let checkouts = parse(result.standardOutput).filter { isDirectory($0.path) }
            if !checkouts.isEmpty { return checkouts }
        }
        return isDirectory(root) ? [fallback] : []
    }

    static func parse(_ output: Data) -> [Self] {
        String(decoding: output, as: UTF8.self).components(separatedBy: "\0\0").compactMap { record in
            let fields = record.split(separator: "\0")
            guard let first = fields.first, first.hasPrefix("worktree "),
                  !fields.contains("bare"), !fields.contains(where: { $0.hasPrefix("prunable") })
            else { return nil }
            let branchPrefix = "branch refs/heads/"
            let branch = fields.first { $0.hasPrefix(branchPrefix) }?.dropFirst(branchPrefix.count)
            let commit = fields.first { $0.hasPrefix("HEAD ") }?.dropFirst(5).prefix(7)
            return Self(path: String(first.dropFirst(9)), branch: (branch ?? commit).map(String.init))
        }
    }

    private static func isDirectory(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}

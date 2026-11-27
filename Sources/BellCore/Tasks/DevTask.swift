import Foundation

/// A piece of development work, kept so it can be picked up again: what it is, what to
/// do next, and the workspaces (directory, branch, session) it is spread over.
public struct DevTask: Sendable, Equatable, Codable, Identifiable {
    public enum Status: String, Sendable, Codable, CaseIterable {
        case todo, inProgress, done
    }

    public let id: UUID
    public var title: String
    public var note: String
    public var nextStep: String
    public var status: Status
    /// In the order they were linked.
    public private(set) var workspaces: [TaskWorkspace]
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        title: String,
        note: String = "",
        nextStep: String = "",
        status: Status = .todo,
        workspaces: [TaskWorkspace] = [],
        createdAt: Date
    ) {
        self.id = id
        self.title = title
        self.note = note
        self.nextStep = nextStep
        self.status = status
        self.workspaces = workspaces
        self.createdAt = createdAt
    }

    /// One directory is one workspace: a later session in the same directory takes the
    /// place of the earlier one, so resuming always picks up the latest.
    public func linking(_ workspace: TaskWorkspace) -> DevTask {
        var copy = self
        if let index = copy.workspaces.firstIndex(where: { $0.cwd == workspace.cwd }) {
            copy.workspaces[index] = workspace
        } else {
            copy.workspaces.append(workspace)
        }
        return copy
    }

    public func unlinking(workspace cwd: String) -> DevTask {
        var copy = self
        copy.workspaces.removeAll { $0.cwd == cwd }
        return copy
    }

    public func contains(sessionID: String) -> Bool {
        workspaces.contains { $0.sessionID == sessionID }
    }

    /// By task name, project name or branch, as the session search matches.
    public func matches(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return true }
        let fields = [title] + workspaces.flatMap { [$0.projectName, $0.branch].compactMap { $0 } }
        return fields.contains { $0.localizedStandardContains(term) }
    }

    /// Work in progress first, then to do, then done; newest first within each. Editing
    /// never moves a task, so the list stays put while you type.
    public static func listOrder(_ tasks: [DevTask]) -> [DevTask] {
        tasks.sorted {
            let (left, right) = (rank($0.status), rank($1.status))
            return left != right ? left < right : $0.createdAt > $1.createdAt
        }
    }

    private static func rank(_ status: Status) -> Int {
        switch status {
        case .inProgress: 0
        case .todo: 1
        case .done: 2
        }
    }
}

/// Where part of a task lives, as it stood when a session was linked. Kept on its own,
/// so it outlives the session list, which forgets closed sessions after a day.
public struct TaskWorkspace: Sendable, Equatable, Codable, Identifiable {
    public var id: String { cwd }
    /// The repository root; for a linked worktree, the main repository.
    public let projectRoot: String
    public let cwd: String
    public let branch: String?
    public let sessionID: String
    public let linkedAt: Date

    public init(session: Session, at date: Date) {
        projectRoot = session.project.root
        cwd = session.cwd
        branch = session.project.branch
        sessionID = session.id
        linkedAt = date
    }

    public var projectName: String { (projectRoot as NSString).lastPathComponent }

    /// Works from any terminal: it goes to the directory first.
    public var resumeCommand: String { Session.resumeInDirectoryCommand(id: sessionID, cwd: cwd) }
}

/// The tasks on disk. Unlike the session state, they are the user's own writing, so a
/// file that cannot be read is kept aside rather than replaced.
public enum TaskFile {
    public static var url: URL { BellPaths.supportDirectory.appendingPathComponent("tasks.json") }

    /// No file means no tasks yet; a file that does not decode throws.
    public static func load(from file: URL = url) throws -> [DevTask] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([DevTask].self, from: Data(contentsOf: file))
    }

    /// Renames the file to `tasks.json.unreadable-<time>` beside it and returns where it went.
    public static func setAside(_ file: URL, at date: Date) throws -> URL {
        let stamp = Int(date.timeIntervalSince1970)
        let target = file.deletingLastPathComponent()
            .appendingPathComponent("\(file.lastPathComponent).unreadable-\(stamp)")
        try FileManager.default.moveItem(at: file, to: target)
        return target
    }
}

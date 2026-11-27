import Foundation

public struct SessionGroup: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// Shown next to the group name when every session is on the same branch.
    public let branch: String?
    /// True when sessions sit on different branches; each row then shows its own.
    public let branchPerRow: Bool
    public let sessions: [Session]
}

/// A project as the sidebar lists it: its open sessions, and the ones closed lately.
public struct ProjectEntry: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let branch: String?
    public let branchPerRow: Bool
    public let live: [Session]
    /// Most recently ended first.
    public let closed: [Session]
}

/// What the menu bar icon shows.
public enum OverallStatus: Sendable, Equatable {
    case idle
    case working
    case waiting(count: Int)
    case failed
}

public enum PanelLayout {
    /// Groups live sessions by project. Waiting comes first, followed by failures,
    /// working sessions, and the rest. Waiting rows are oldest first. Other rows and
    /// projects use recent activity, so tool calls never move busy rows under the cursor.
    public static func groups(_ sessions: [Session], pinned: [String] = []) -> [SessionGroup] {
        let byRoot = Dictionary(grouping: sessions, by: \.project.root)
        let groups = byRoot.map { root, members -> SessionGroup in
            let sorted = members.sorted(by: rowOrder)
            let branches = Set(sorted.map(\.project.branch))
            let shared = branches.count == 1 ? branches.first ?? nil : nil
            return SessionGroup(
                id: root,
                name: sorted[0].project.name,
                branch: shared,
                branchPerRow: branches.count > 1,
                sessions: sorted
            )
        }
        return pinnedFirst(groups.sorted(by: groupOrder), pinned: pinned)
    }

    /// Every project with an open session, in `groups` order, then those with only
    /// closed sessions, the most recently closed first.
    public static func projects(live: [Session], recent: [Session], pinned: [String] = []) -> [ProjectEntry] {
        let closedByRoot = Dictionary(grouping: recent, by: \.project.root)
        let open = groups(live).map { group in
            ProjectEntry(
                id: group.id, name: group.name, branch: group.branch, branchPerRow: group.branchPerRow,
                live: group.sessions, closed: closedByRoot[group.id] ?? []
            )
        }
        let openRoots = Set(open.map(\.id))
        var closedOnly: [ProjectEntry] = []
        for session in recent where !openRoots.contains(session.project.root) {
            guard !closedOnly.contains(where: { $0.id == session.project.root }) else { continue }
            let closed = closedByRoot[session.project.root] ?? []
            closedOnly.append(ProjectEntry(
                id: session.project.root, name: session.project.name, branch: session.project.branch,
                branchPerRow: false, live: [], closed: closed
            ))
        }
        return pinnedFirst(open + closedOnly, pinned: pinned)
    }

    private static func pinnedFirst<Project: Identifiable>(
        _ projects: [Project], pinned: [String]
    ) -> [Project] where Project.ID == String {
        guard !pinned.isEmpty else { return projects }
        var byID = Dictionary(uniqueKeysWithValues: projects.map { ($0.id, $0) })
        let first = pinned.compactMap { byID.removeValue(forKey: $0) }
        return first + projects.filter { byID[$0.id] != nil }
    }

    public static func attentionOrder(_ sessions: [Session]) -> [Session] {
        sessions.sorted(by: rowOrder)
    }

    /// Where the jump shortcut goes: the session waiting longest, else the latest failure.
    public static func nextAttention(_ sessions: [Session]) -> Session? {
        attentionOrder(sessions.filter { !$0.isEnded && ($0.state == .waiting || $0.state == .failed) }).first
    }

    public static func overallStatus(_ sessions: [Session]) -> OverallStatus {
        let waiting = sessions.filter { $0.state == .waiting }.count
        if waiting > 0 { return .waiting(count: waiting) }
        if sessions.contains(where: { $0.state == .failed }) { return .failed }
        if sessions.contains(where: { $0.state == .working || $0.state == .background }) { return .working }
        return .idle
    }

    private static func groupRank(_ group: SessionGroup) -> Int {
        let states = Set(group.sessions.map(\.state))
        if states.contains(.waiting) { return 0 }
        if states.contains(.failed) { return 1 }
        if states.contains(.working) || states.contains(.background) { return 2 }
        return 3
    }

    private static func groupOrder(_ lhs: SessionGroup, _ rhs: SessionGroup) -> Bool {
        let (lr, rr) = (groupRank(lhs), groupRank(rhs))
        if lr != rr { return lr < rr }
        let (la, ra) = (latestActivity(lhs), latestActivity(rhs))
        if la != ra { return la > ra }
        return lhs.id < rhs.id
    }

    private static func latestActivity(_ group: SessionGroup) -> Date {
        group.sessions.map(Copy.since).max() ?? .distantPast
    }

    private static func rowRank(_ session: Session) -> Int {
        switch session.state {
        case .waiting: return 0
        case .failed: return 1
        case .working, .background: return 2
        default: return 3
        }
    }

    private static func rowOrder(_ lhs: Session, _ rhs: Session) -> Bool {
        let (lr, rr) = (rowRank(lhs), rowRank(rhs))
        if lr != rr { return lr < rr }
        let (ls, rs) = (Copy.since(lhs), Copy.since(rhs))
        if ls != rs { return lr == 0 ? ls < rs : ls > rs }
        return lhs.id < rhs.id
    }
}

import Foundation

/// Which notifications the user wants (DESIGN.md §3.5, UI_DESIGN.md §5).
public struct NoticePrefs: Sendable, Equatable {
    public var waiting: Bool
    public var failed: Bool
    public var done: Bool
    /// Off: the title only, no prompt or reply. For screen sharing.
    public var showContent: Bool
    /// A finished round announces itself only when it ran longer than this.
    public var longRound: TimeInterval

    /// The lengths Settings offers; the first is the default.
    public static let longRoundChoices: [TimeInterval] = [30, 60, 3 * 60, 5 * 60]

    public init(waiting: Bool = true, failed: Bool = true, done: Bool = true, showContent: Bool = true,
                longRound: TimeInterval = longRoundChoices[0]) {
        self.waiting = waiting
        self.failed = failed
        self.done = done
        self.showContent = showContent
        self.longRound = longRound
    }
}

public struct Notice: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case waiting, failed, done
    }

    public let session: String
    public let kind: Kind
    public let title: String
    public let subtitle: String?
    public let body: String?

    public init(session: String, kind: Kind, title: String, subtitle: String? = nil, body: String? = nil) {
        self.session = session
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    /// One notification per session and kind: a newer one replaces the older.
    public var id: String { Self.id(session, kind) }
    /// A finished round is good news, not a call to act.
    public var silent: Bool { kind == .done }

    public static func id(_ session: String, _ kind: Kind) -> String { "\(session).\(kind.rawValue)" }
}

/// Decides what to post and what to take back when sessions change.
public enum Notices {
    /// Shorter rounds you most likely watched finish.

    public struct Changes: Equatable, Sendable {
        public var post: [Notice] = []
        /// Ids of notifications no longer true, such as a question already answered.
        public var withdraw: [String] = []

        public init(post: [Notice] = [], withdraw: [String] = []) {
            self.post = post
            self.withdraw = withdraw
        }
    }

    public static func changes(from old: [String: Session], to new: [String: Session], prefs: NoticePrefs) -> Changes {
        var changes = Changes()
        // A question answered, or a failure the session has moved on from, is no longer true.
        for (id, before) in old {
            let kind: Notice.Kind
            switch before.state {
            case .waiting: kind = .waiting
            case .failed: kind = .failed
            default: continue
            }
            if new[id]?.state != before.state { changes.withdraw.append(Notice.id(id, kind)) }
        }
        for (id, session) in new {
            let before = old[id]
            // A new question while still waiting replaces the old one.
            let changed = before?.state != session.state || (session.state == .waiting && before?.detail != session.detail)
            if changed, let notice = notice(for: session, prefs: prefs) {
                changes.post.append(notice)
            }
        }
        changes.post.sort { $0.id < $1.id }
        changes.withdraw.sort()
        return changes
    }

    static func notice(for session: Session, prefs: NoticePrefs) -> Notice? {
        let kind: Notice.Kind
        let headline: String
        switch session.state {
        case .waiting where prefs.waiting:
            kind = .waiting
            headline = "等你确认"
        case .failed where prefs.failed:
            kind = .failed
            headline = "出错了"
        case .completed where prefs.done:
            guard let start = session.roundStartedAt else { return nil }
            let length = session.stateSince.timeIntervalSince(start)
            guard length > prefs.longRound else { return nil }
            kind = .done
            headline = "这一轮做完了 · \(Copy.roundLength(length))"
        default:
            return nil
        }
        let title = "\(session.project.name) \(headline)"
        guard prefs.showContent else {
            return Notice(session: session.id, kind: kind, title: title, subtitle: nil, body: nil)
        }
        return Notice(session: session.id, kind: kind, title: title, subtitle: session.title, body: session.detail)
    }
}

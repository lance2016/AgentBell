import Foundation

/// Pure state machine over polling results and hook events (DESIGN.md §3.4).
///
/// Two things are kept apart for each session. Whether it is open comes only from
/// `claude agents`: present with a pid means open, gone means ended. How its round
/// stands comes from hooks (`rounds`), with polling filling in what hooks cannot say:
/// a round interrupted with Esc, or a round started before the hooks were connected.
/// Time is always passed in, so tests never touch a real clock.
public struct SessionTracker: Sendable, Equatable {
    public static let recentRetention: TimeInterval = 24 * 3600
    /// Hook state for a session `claude agents` has not listed yet is kept this long.
    static let unlistedRetention: TimeInterval = 60
    /// A saved round is stale when its transcript was written this long after its last hook.
    static let missedEventsSlack: TimeInterval = 5

    /// Open sessions, keyed by session id.
    public private(set) var live: [String: Session] = [:]
    /// Ended sessions, most recently ended first.
    public private(set) var recent: [Session] = []
    /// What hooks say about each session's round.
    public private(set) var rounds: [String: HookState] = [:]
    /// Rounds saved by an earlier run, not yet checked against their transcripts.
    private var unverified: Set<String> = []

    /// A complete poll must miss an open session twice before it is closed.
    private var firstMissingAt: [String: Date] = [:]
    private static let closureGrace: TimeInterval = 2

    public func isPendingClosure(_ id: String) -> Bool { firstMissingAt[id] != nil }

    public init() {}

    /// Takes back what an earlier run saved. Each round is checked on the first poll that
    /// lists its session: if the transcript moved on while nobody listened, it is dropped.
    /// Saved sessions all start out in `recent`; the first poll takes back the ones still
    /// open. One that closed meanwhile counts as closed when its transcript last changed.
    public mutating func restore(_ saved: [String: HookState], sessions: [Session] = []) {
        rounds = saved
        unverified = Set(saved.keys)
        recent = sessions
            .map { session -> Session in
                var copy = session
                if copy.endedAt == nil { copy.endedAt = copy.transcript?.modifiedAt ?? copy.stateSince }
                return copy
            }
            .sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
    }

    /// Open and lately closed sessions, for `restore` after a restart.
    public var savedSessions: [Session] {
        live.values.sorted { $0.id < $1.id } + recent
    }

    /// Polling saw a session go idle mid-round; poll again after the grace period to
    /// tell an interruption from a Stop that is still on its way.
    public var needsRecheck: Bool {
        !firstMissingAt.isEmpty || rounds.values.contains { $0.idleSeenAt != nil }
    }

    public mutating func applyHook(_ event: HookEvent) {
        guard let next = RoundMachine.apply(event, to: rounds[event.session]) else { return }
        rounds[event.session] = next
        if event.event != "SessionEnd" { firstMissingAt.removeValue(forKey: event.session) }
        if var session = live[event.session] {
            show(&session)
            live[event.session] = session
        }
    }

    public mutating func applyPoll(
        _ records: [AgentRecord],
        at now: Date,
        isComplete: Bool = true,
        project: (String) -> ProjectInfo,
        transcript: (String) -> TranscriptSummary? = { _ in nil }
    ) {
        var next: [String: Session] = [:]
        for record in records {
            guard let pid = record.pid, next[record.sessionId] == nil else { continue }
            var session = updated(live[record.sessionId], from: record, pid: pid, at: now, project: project)
            if let summary = transcript(record.sessionId) { session.transcript = summary }
            if unverified.remove(record.sessionId) != nil, let round = rounds[record.sessionId],
               let modified = session.transcript?.modifiedAt,
               modified.timeIntervalSince(round.lastEventAt) > Self.missedEventsSlack {
                rounds[record.sessionId] = nil
            }
            if let round = rounds[record.sessionId] {
                let observed = record.isBusy
                    ? RoundMachine.observeBusy(round, at: now)
                    : RoundMachine.observeIdle(round, at: now)
                rounds[record.sessionId] = RoundMachine.fade(observed, at: now)
            }
            show(&session)
            next[record.sessionId] = session
        }

        let missing = Set(live.keys).subtracting(next.keys)
        var pending: [String: Date] = [:]
        var confirmed: Set<String> = []
        for id in missing {
            if isComplete, let first = firstMissingAt[id], now.timeIntervalSince(first) >= Self.closureGrace {
                confirmed.insert(id)
            } else {
                next[id] = live[id]
                if isComplete { pending[id] = firstMissingAt[id] ?? now }
            }
        }
        firstMissingAt = pending
        let ended = live.values
            .filter { confirmed.contains($0.id) }
            .sorted { $0.startedAt > $1.startedAt }
            .map { session -> Session in
                var copy = session
                copy.endedAt = now
                return copy
            }

        live = next
        recent = (ended + recent)
            .filter { next[$0.id] == nil }
            .filter { now.timeIntervalSince($0.endedAt ?? now) < Self.recentRetention }
        let endedIDs = Set(ended.map(\.id))
        rounds = rounds.filter { id, round in
            next[id] != nil
                || (!endedIDs.contains(id) && now.timeIntervalSince(round.lastEventAt) < Self.unlistedRetention)
        }
        unverified.formIntersection(rounds.keys)
    }

    public mutating func invalidatePendingClosures() {
        firstMissingAt.removeAll()
    }

    /// What the row shows: the hooks' account when there is one, else polling's.
    private func show(_ session: inout Session) {
        if let round = rounds[session.id] {
            session.state = round.turn
            session.stateSince = round.shownSince
            session.detail = round.line
            session.roundStartedAt = round.startedAt
            session.heardTurns = round.turns
        } else {
            session.state = session.polledState
            session.stateSince = session.polledSince
            session.detail = nil
            session.roundStartedAt = nil
            session.heardTurns = []
        }
    }

    private func updated(
        _ existing: Session?,
        from record: AgentRecord,
        pid: Int32,
        at now: Date,
        project: (String) -> ProjectInfo
    ) -> Session {
        let polled: RoundState = record.isBusy ? .working : .idle
        guard var session = existing else {
            return Session(
                id: record.sessionId,
                pid: pid,
                cwd: record.cwd,
                project: project(record.cwd),
                name: record.name,
                startedAt: record.startedAtDate ?? now,
                state: polled,
                stateSince: now
            )
        }
        session.pid = pid
        session.cwd = record.cwd
        session.project = project(record.cwd)
        session.name = record.name
        if session.polledState != polled {
            session.polledState = polled
            session.polledSince = now
        }
        return session
    }
}

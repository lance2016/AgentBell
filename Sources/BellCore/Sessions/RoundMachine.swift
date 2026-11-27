import Foundation

/// What hooks say about a session's current round, kept apart from whether the
/// session is open (that comes only from `claude agents`).
public struct HookState: Sendable, Equatable, Codable {
    public var turn: RoundState
    /// When `turn` last changed.
    public var since: Date
    public var startedAt: Date?
    public var endedAt: Date?
    /// When background work woke the round up again.
    public var resumedAt: Date?
    public var lastEventAt: Date
    public var prompt: String?
    /// What it is on while working, e.g. "修改 App.tsx".
    public var activity: String?
    /// What it waits for, e.g. "想改 App.tsx，等你点头".
    public var asking: String?
    /// The tool it asked about; only that tool finishing ends the wait.
    public var waitingFor: String?
    /// How the round came out: the reply's first line, or why it failed.
    public var result: String?
    /// When polling first saw the session idle while this said working.
    public var idleSeenAt: Date?
    /// Only polling saw this round start; no hook has spoken for it.
    public var polled = false
    /// Rounds before this one, oldest first. Hooks are the only source that reaches back:
    /// a transcript's tail can be all tool output and images.
    public var earlier: [TranscriptTurn] = []

    init(turn: RoundState, at: Date) {
        self.turn = turn
        self.since = at
        self.lastEventAt = at
    }

    public var isLive: Bool { turn == .working || turn == .waiting }

    /// The row's second line.
    public var line: String? {
        switch turn {
        case .waiting: return asking
        case .working: return activity ?? prompt
        case .completed, .background, .failed: return result
        case .interrupted, .idle: return nil
        }
    }

    /// Earlier rounds and this one, oldest first, for the session's detail.
    public var turns: [TranscriptTurn] {
        guard let current else { return earlier }
        return earlier + [current]
    }

    private var current: TranscriptTurn? {
        guard prompt != nil || result != nil else { return nil }
        return TranscriptTurn(prompt: prompt, reply: isLive ? nil : result, at: startedAt)
    }

    /// Files this round among the earlier ones, before a new one takes its place.
    mutating func putAway() {
        guard let current else { return }
        earlier = Array((earlier + [current]).suffix(RoundMachine.maxTurns - 1))
    }

    /// Where the row's time counts from: a working round from its start.
    public var shownSince: Date {
        turn == .working ? (startedAt ?? since) : since
    }

    mutating func set(_ next: RoundState, at: Date) {
        if turn != next { since = at }
        turn = next
    }

    /// Without what belonged to the step in progress.
    mutating func settle() {
        activity = nil
        asking = nil
        waitingFor = nil
    }
}

/// Hook events in, round state out (DESIGN.md §3.4). Ported from AI Pet's
/// `ClaudeSessions`, whose cases are the tests here.
public enum RoundMachine {
    /// How far a round's prompt may trail its first tool and still name that round.
    static let latePrompt: TimeInterval = 10
    static let asking: Set = ["permission_prompt", "elicitation_dialog"]
    /// How many rounds the detail lists, this one included.
    static let maxTurns = 5
    /// How long a finished round stands out before it reads as idle.
    static let fadeAfter: TimeInterval = 5 * 60

    /// The state after `event`, or nil when the event is a straggler to drop.
    public static func apply(_ event: HookEvent, to known: HookState?) -> HookState? {
        let at = event.date

        // The prompt that started this round, overtaken by the round's first tool.
        if var known, event.event == "UserPromptSubmit", event.woke != true, known.turn == .working,
           let began = known.resumedAt ?? known.startedAt, at < began, began.timeIntervalSince(at) <= latePrompt {
            if known.resumedAt != nil {
                // That tool was taken for background work waking the last round; it was this prompt's.
                known.resumedAt = nil
            }
            known.startedAt = at
            known.prompt = event.prompt ?? known.prompt
            known.polled = false
            return known
        }
        // It ran before this round began, ended or woke up: says nothing new.
        if let known {
            let latest = [known.startedAt, known.endedAt, known.resumedAt].compactMap { $0 }.max()
            if let latest, at < latest { return nil }
        }

        var state = known ?? HookState(turn: .idle, at: at)
        state.lastEventAt = max(state.lastEventAt, at)
        state.idleSeenAt = nil
        state.polled = false
        let subagent = event.subagent == true

        switch event.event {
        case "SessionStart", "SessionEnd":
            // SessionStart also comes mid-round after a compaction; polling decides about the end.
            return state
        case "UserPromptSubmit":
            if event.woke == true {
                return state.isLive ? state : resume(state, at: at)
            }
            return work(state, event: event, at: at, prompted: true)
        case "PreToolUse":
            if subagent || state.turn == .waiting { return state }
            var next = work(state, event: event, at: at, prompted: false)
            if let activity = event.tool.flatMap({ Copy.describeTool($0, detail: event.detail) }) {
                next.activity = activity
            }
            return next
        case "PostToolUse":
            // A subagent's tool, or another one running alongside, leaves the question open.
            if subagent || state.turn == .working { return state }
            if state.turn == .waiting, let waitingFor = state.waitingFor, waitingFor != event.tool { return state }
            return work(state, event: event, at: at, prompted: false)
        case "PermissionRequest":
            return ask(state, event: event, at: at, tool: event.tool)
        case "Notification":
            guard asking.contains(event.notification ?? ""), state.turn != .waiting else { return state }
            return ask(state, event: event, at: at, tool: nil)
        case "Stop":
            // Background work went on and ended, and the wake-up was missed.
            if state.turn == .background, at > (state.endedAt ?? .distantPast) {
                return finish(resume(state, at: at), at: at, reply: event.reply, background: event.background == true)
            }
            // A second Stop for a round already over changes nothing; an Esc guess yields to a real Stop.
            if !state.isLive && state.turn != .interrupted && known != nil { return state }
            return finish(state, at: at, reply: event.reply, background: event.background == true)
        case "StopFailure":
            return over(state, .failed, at: at, result: Copy.failureReason(event.error))
        default:
            return state
        }
    }

    /// Polling saw the session idle while hooks still say it works. After `grace` with
    /// no Stop, the round was interrupted (Esc): Claude Code sends no hook for that.
    /// A round no hook spoke for is not known to be cut short, so it just goes idle.
    public static func observeIdle(_ state: HookState, at now: Date, grace: TimeInterval = 3) -> HookState {
        guard state.turn == .working else { return state }
        var next = state
        guard let seen = state.idleSeenAt else {
            next.idleSeenAt = now
            return next
        }
        guard now.timeIntervalSince(seen) >= grace else { return state }
        next.idleSeenAt = nil
        next.settle()
        next.set(state.polled ? .idle : .interrupted, at: seen)
        return next
    }

    /// Polling saw the session busy while hooks say the round is over: a round the
    /// hooks have not reported yet (or never will). A recent hook wins over a poll.
    public static func observeBusy(_ state: HookState, at now: Date, grace: TimeInterval = 3) -> HookState {
        var next = state
        next.idleSeenAt = nil
        guard !state.isLive, state.turn != .background, now.timeIntervalSince(state.lastEventAt) > grace else { return next }
        next.putAway()
        next.settle()
        next.result = nil
        next.prompt = nil
        // Not known when it began; the last round's end still screens out its stragglers.
        next.startedAt = nil
        next.resumedAt = nil
        next.polled = true
        next.set(.working, at: now)
        return next
    }

    /// A round that finished or was interrupted a while ago reads as idle. A failure
    /// stays until the next round: it may need doing something about.
    public static func fade(_ state: HookState, at now: Date) -> HookState {
        guard state.turn == .completed || state.turn == .interrupted,
              now.timeIntervalSince(state.since) >= fadeAfter else { return state }
        var next = state
        next.set(.idle, at: now)
        return next
    }

    private static func work(_ state: HookState, event: HookEvent, at: Date, prompted: Bool) -> HookState {
        // At it again without the user asking: the background work woke it.
        if !prompted && (event.woke == true || state.turn == .background) {
            return resume(state, at: at)
        }
        var next = state
        let starting = (prompted && state.startedAt != at) || !state.isLive
        if starting {
            next.putAway()
            next.settle()
            next.result = nil
            next.endedAt = nil
            next.resumedAt = nil
            next.startedAt = at
            next.prompt = event.prompt
        } else {
            next.asking = nil
            next.waitingFor = nil
        }
        next.set(.working, at: at)
        return next
    }

    private static func resume(_ state: HookState, at: Date) -> HookState {
        var next = state
        next.settle()
        next.result = nil
        next.endedAt = nil
        next.startedAt = state.startedAt ?? at
        next.resumedAt = at
        next.set(.working, at: at)
        return next
    }

    private static func ask(_ state: HookState, event: HookEvent, at: Date, tool: String?) -> HookState {
        var next = state
        if !state.isLive {
            // Asked with no round known: count one from here.
            next.putAway()
            next.settle()
            next.result = nil
            next.prompt = nil
            next.endedAt = nil
            next.startedAt = at
        }
        next.asking = Copy.describeAsk(tool: tool, detail: event.detail)
        next.waitingFor = tool
        next.set(.waiting, at: at)
        return next
    }

    private static func finish(_ state: HookState, at: Date, reply: String?, background: Bool) -> HookState {
        over(state, background ? .background : .completed, at: at, result: reply)
    }

    private static func over(_ state: HookState, _ turn: RoundState, at: Date, result: String?) -> HookState {
        var next = state
        next.settle()
        next.resumedAt = nil
        next.endedAt = at
        next.result = result
        next.set(turn, at: at)
        return next
    }
}

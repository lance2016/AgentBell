import Foundation
import Testing
@testable import BellCore

struct SessionTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    let project: (String) -> ProjectInfo = { ProjectInfo(root: $0, branch: "main") }

    func record(_ id: String, busy: Bool = false, pid: Int32? = 100, cwd: String = "/p") -> AgentRecord {
        AgentRecord(sessionId: id, pid: pid, cwd: cwd, name: id, startedAt: 0, status: busy ? "busy" : "idle")
    }

    @Test func listsSessionsWithPid() {
        var tracker = SessionTracker()
        tracker.applyPoll([record("a", busy: true), record("b"), record("c", pid: nil)], at: t0, project: project)
        #expect(Set(tracker.live.keys) == ["a", "b"])
        #expect(tracker.live["a"]?.state == .working)
        #expect(tracker.live["b"]?.state == .idle)
    }

    @Test func keepsStateSinceUntilStateChanges() {
        var tracker = SessionTracker()
        tracker.applyPoll([record("a", busy: true)], at: t0, project: project)
        tracker.applyPoll([record("a", busy: true)], at: t0 + 60, project: project)
        #expect(tracker.live["a"]?.stateSince == t0)
        tracker.applyPoll([record("a", busy: false)], at: t0 + 120, project: project)
        #expect(tracker.live["a"]?.state == .idle)
        #expect(tracker.live["a"]?.stateSince == t0 + 120)
    }

    @Test func aNameGivenInAgentBellFollowsTheSession() {
        var tracker = SessionTracker()
        tracker.applyPoll([record("a")], at: t0, project: project)
        tracker.rename("a", to: "  支付重构 ")
        #expect(tracker.live["a"]?.title == "支付重构")
        #expect(tracker.titles == ["a": "支付重构"])
        // Polling rebuilds the row, not the name.
        tracker.applyPoll([record("a")], at: t0 + 10, project: project)
        #expect(tracker.live["a"]?.alias == "支付重构")
        // Closed, and resumed later with `claude --resume`.
        tracker.applyPoll([], at: t0 + 20, project: project)
        tracker.applyPoll([], at: t0 + 22, project: project)
        #expect(tracker.recent.first?.alias == "支付重构")
        tracker.rename("a", to: "支付重构 v2")
        #expect(tracker.recent.first?.title == "支付重构 v2")
        tracker.applyPoll([record("a")], at: t0 + 30, project: project)
        #expect(tracker.live["a"]?.alias == "支付重构 v2")
        // An empty name gives the session back its own.
        tracker.rename("a", to: " ")
        #expect(tracker.live["a"]?.alias == nil)
        #expect(tracker.live["a"]?.title == "a")
        #expect(tracker.titles.isEmpty)
    }

    @Test func namingASessionBackToItsOwnTitleDropsTheName() {
        var tracker = SessionTracker()
        tracker.applyPoll([record("a")], at: t0, project: project)
        tracker.rename("a", to: "支付重构")
        tracker.rename("a", to: " a ")
        #expect(tracker.titles.isEmpty)
        #expect(tracker.live["a"]?.alias == nil)
    }

    @Test func savedNamesComeBackWithTheirSessions() {
        var tracker = SessionTracker()
        let saved = Session(id: "a", pid: 1, cwd: "/p", project: project("/p"), startedAt: t0,
                            state: .idle, stateSince: t0, endedAt: t0)
        tracker.restore([:], sessions: [saved], titles: ["a": "支付重构"])
        #expect(tracker.recent.first?.title == "支付重构")
    }

    @Test func vanishedSessionMovesToRecent() {
        var tracker = SessionTracker()
        tracker.applyPoll([record("a"), record("b")], at: t0, project: project)
        tracker.applyPoll([record("b")], at: t0 + 10, project: project)
        #expect(tracker.isPendingClosure("a"))
        #expect(tracker.recent.isEmpty)
        tracker.applyPoll([record("b")], at: t0 + 11, project: project)
        #expect(tracker.live["a"] != nil)
        tracker.applyPoll([record("b")], at: t0 + 12, project: project)
        #expect(Array(tracker.live.keys) == ["b"])
        #expect(tracker.recent.map(\.id) == ["a"])
        #expect(tracker.recent.first?.endedAt == t0 + 12)
    }

    @Test func newestEndedComesFirst() {
        var tracker = SessionTracker()
        tracker.applyPoll([record("a"), record("b")], at: t0, project: project)
        tracker.applyPoll([record("b")], at: t0 + 10, project: project)
        tracker.applyPoll([record("b")], at: t0 + 12, project: project)
        tracker.applyPoll([], at: t0 + 20, project: project)
        tracker.applyPoll([], at: t0 + 22, project: project)
        #expect(tracker.recent.map(\.id) == ["b", "a"])
    }

    @Test func recentExpiresAfter24Hours() {
        var tracker = SessionTracker()
        tracker.applyPoll([record("a")], at: t0 - 2, project: project)
        tracker.applyPoll([], at: t0 - 1, project: project)
        tracker.applyPoll([], at: t0 + 1, project: project)
        tracker.applyPoll([], at: t0 + SessionTracker.recentRetention, project: project)
        #expect(tracker.recent.map(\.id) == ["a"])
        tracker.applyPoll([], at: t0 + 1 + SessionTracker.recentRetention, project: project)
        #expect(tracker.recent.isEmpty)
    }

    @Test func reappearingSessionLeavesRecent() {
        var tracker = SessionTracker()
        tracker.applyPoll([record("a")], at: t0, project: project)
        tracker.applyPoll([], at: t0 + 1, project: project)
        tracker.applyPoll([], at: t0 + 3, project: project)
        #expect(tracker.recent.map(\.id) == ["a"])
        tracker.applyPoll([record("a")], at: t0 + 4, project: project)
        #expect(tracker.recent.isEmpty)
        #expect(tracker.live["a"]?.endedAt == nil)
    }

    @Test func incompletePollDoesNotConfirmAClosure() {
        var tracker = SessionTracker()
        tracker.applyPoll([record("a"), record("b")], at: t0, project: project)
        tracker.applyPoll([record("b")], at: t0 + 2, project: project)
        tracker.applyPoll([record("b", busy: true)], at: t0 + 5, isComplete: false, project: project)
        #expect(tracker.live["a"] != nil)
        #expect(tracker.live["b"]?.state == .working)
        tracker.applyPoll([record("b")], at: t0 + 10, project: project)
        #expect(tracker.isPendingClosure("a"))
        tracker.applyPoll([record("a"), record("b")], at: t0 + 11, project: project)
        #expect(!tracker.isPendingClosure("a"))
        #expect(tracker.recent.isEmpty)
    }

    @Test func duplicateIdsKeepFirst() {
        var tracker = SessionTracker()
        tracker.applyPoll([record("a", pid: 1), record("a", pid: 2)], at: t0, project: project)
        #expect(tracker.live["a"]?.pid == 1)
    }
}

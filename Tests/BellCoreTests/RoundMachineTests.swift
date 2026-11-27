import Foundation
import Testing
@testable import BellCore

/// DESIGN.md §3.4, rule by rule. Cases follow AI Pet's ClaudeSessions tests.
struct RoundMachineTests {
    let t0: Double = 1_000_000_000

    func event(_ name: String, at seconds: Double, tool: String? = nil, detail: String? = nil, prompt: String? = nil,
               woke: Bool? = nil, reply: String? = nil, background: Bool? = nil, error: String? = nil,
               notification: String? = nil, subagent: Bool? = nil) -> HookEvent {
        HookEvent(event: name, session: "s", at: (t0 + seconds) * 1000, tool: tool, detail: detail, prompt: prompt,
                  woke: woke, reply: reply, background: background, error: error, notification: notification,
                  subagent: subagent)
    }

    func run(_ events: [HookEvent]) -> HookState? {
        events.reduce(nil as HookState?) { state, event in RoundMachine.apply(event, to: state) ?? state }
    }

    func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: t0 + seconds) }

    // Rule 1: waiting ends only with that tool's PostToolUse, a new prompt, Stop, or the session going.

    @Test func permissionRequestWaitsNamingTheTool() {
        let state = run([event("UserPromptSubmit", at: 0, prompt: "修复按钮"),
                         event("PermissionRequest", at: 5, tool: "Edit", detail: "PetSpeech.tsx")])
        #expect(state?.turn == .waiting)
        #expect(state?.line == "想改 PetSpeech.tsx，等你点头")
        #expect(state?.startedAt == date(0))
    }

    @Test func askLines() {
        #expect(Copy.describeAsk(tool: "AskUserQuestion", detail: nil) == "有话问你")
        #expect(Copy.describeAsk(tool: "ExitPlanMode", detail: nil) == "写好计划了，等你过目")
        #expect(Copy.describeAsk(tool: "mcp__github__create_pr", detail: nil) == "想用 create_pr，等你点头")
        #expect(Copy.describeAsk(tool: nil, detail: nil) == "在等你确认")
    }

    @Test func thatToolFinishingEndsTheWaitKeepingTheStart() {
        let state = run([event("UserPromptSubmit", at: 0, prompt: "修复按钮"),
                         event("PermissionRequest", at: 5, tool: "Edit"),
                         event("PostToolUse", at: 9, tool: "Edit")])
        #expect(state?.turn == .working)
        #expect(state?.startedAt == date(0))
        #expect(state?.asking == nil)
    }

    @Test func anotherToolAlongsideDoesNotEndTheWait() {
        let state = run([event("UserPromptSubmit", at: 0),
                         event("PermissionRequest", at: 5, tool: "Bash"),
                         event("PreToolUse", at: 6, tool: "Read"),
                         event("PostToolUse", at: 7, tool: "Read")])
        #expect(state?.turn == .waiting)
    }

    @Test func subagentToolsNeverChangeTheRound() {
        let waiting = run([event("UserPromptSubmit", at: 0),
                           event("PermissionRequest", at: 5, tool: "Bash"),
                           event("PostToolUse", at: 6, tool: "Bash", subagent: true)])
        #expect(waiting?.turn == .waiting)
    }

    @Test func notificationAsksOnlyWhenNoRequestCameFirst() {
        let fromNotification = run([event("UserPromptSubmit", at: 0),
                                    event("Notification", at: 5, notification: "elicitation_dialog")])
        #expect(fromNotification?.turn == .waiting)
        #expect(fromNotification?.line == "在等你确认")

        let afterRequest = run([event("UserPromptSubmit", at: 0),
                                event("PermissionRequest", at: 5, tool: "Edit", detail: "a.ts"),
                                event("Notification", at: 6, notification: "permission_prompt")])
        #expect(afterRequest?.line == "想改 a.ts，等你点头")

        let idleNotice = run([event("UserPromptSubmit", at: 0), event("Notification", at: 5, notification: "idle_prompt")])
        #expect(idleNotice?.turn == .working)
    }

    @Test func newPromptEndsTheWait() {
        let state = run([event("UserPromptSubmit", at: 0),
                         event("PermissionRequest", at: 5, tool: "Edit"),
                         event("UserPromptSubmit", at: 20, prompt: "算了，换个做法")])
        #expect(state?.turn == .working)
        #expect(state?.startedAt == date(20))
        #expect(state?.prompt == "算了，换个做法")
    }

    // Working lines.

    @Test func workingShowsWhatItIsOn() {
        let state = run([event("UserPromptSubmit", at: 0, prompt: "加统计页"),
                         event("PreToolUse", at: 1, tool: "Bash", detail: "运行测试"),
                         event("PreToolUse", at: 2, tool: "TodoWrite")])
        #expect(state?.line == "运行测试")
        let editing = run([event("UserPromptSubmit", at: 0), event("PreToolUse", at: 1, tool: "Edit", detail: "App.tsx")])
        #expect(editing?.line == "修改 App.tsx")
        let justAsked = run([event("UserPromptSubmit", at: 0, prompt: "加统计页")])
        #expect(justAsked?.line == "加统计页")
    }

    // Rule 2: done is a Stop; with background work it is not done yet.

    @Test func stopCompletesWithTheReply() {
        let state = run([event("UserPromptSubmit", at: 0), event("Stop", at: 240, reply: "已把 PID 参数改成可配置")])
        #expect(state?.turn == .completed)
        #expect(state?.line == "已把 PID 参数改成可配置")
        #expect(state?.endedAt == date(240))
    }

    @Test func backgroundWorkIsNotDone() {
        let state = run([event("UserPromptSubmit", at: 0), event("Stop", at: 10, background: true)])
        #expect(state?.turn == .background)
    }

    @Test func wakeUpGoesOnWithTheSameRoundAndEndsIt() {
        let state = run([event("UserPromptSubmit", at: 0, prompt: "跑基准"),
                         event("Stop", at: 10, background: true),
                         event("UserPromptSubmit", at: 100, woke: true),
                         event("PreToolUse", at: 101, tool: "Read", detail: "result.txt")])
        #expect(state?.turn == .working)
        #expect(state?.startedAt == date(0))
        #expect(state?.resumedAt == date(100))
        let done = RoundMachine.apply(event("Stop", at: 130, reply: "基准跑完了"), to: state!)
        #expect(done?.turn == .completed)
        #expect(done?.startedAt == date(0))
    }

    @Test func missedWakeUpStillEndsTheRound() {
        let state = run([event("UserPromptSubmit", at: 0),
                         event("Stop", at: 10, background: true),
                         event("Stop", at: 100, reply: "完成")])
        #expect(state?.turn == .completed)
        #expect(state?.line == "完成")
    }

    @Test func userPromptDuringBackgroundStartsANewRound() {
        let state = run([event("UserPromptSubmit", at: 0),
                         event("Stop", at: 10, background: true),
                         event("UserPromptSubmit", at: 50, prompt: "顺便改个文案")])
        #expect(state?.turn == .working)
        #expect(state?.startedAt == date(50))
    }

    // Rule 4: out of order and duplicates.

    @Test func stragglerFromBeforeTheEndIsDropped() {
        let state = run([event("UserPromptSubmit", at: 0),
                         event("Stop", at: 30, reply: "好了"),
                         event("PreToolUse", at: 20, tool: "Edit", detail: "a.ts")])
        #expect(state?.turn == .completed)
        #expect(state?.line == "好了")
    }

    @Test func promptOvertakenByItsFirstToolStillNamesTheRound() {
        let state = run([event("Stop", at: 0),
                         event("PreToolUse", at: 101, tool: "Read"),
                         event("UserPromptSubmit", at: 100, prompt: "看看日志")])
        #expect(state?.turn == .working)
        #expect(state?.startedAt == date(100))
        #expect(state?.prompt == "看看日志")
    }

    @Test func samePromptDeliveredTwiceIsOneRound() {
        let state = run([event("UserPromptSubmit", at: 0, prompt: "A"),
                         event("PreToolUse", at: 1, tool: "Bash", detail: "构建"),
                         event("UserPromptSubmit", at: 0, prompt: "A")])
        #expect(state?.startedAt == date(0))
        #expect(state?.line == "构建")
    }

    @Test func secondStopChangesNothing() {
        let state = run([event("UserPromptSubmit", at: 0),
                         event("Stop", at: 10, reply: "第一次"),
                         event("Stop", at: 11, reply: "第二次")])
        #expect(state?.line == "第一次")
    }

    // Rule 5: failures in plain words.

    @Test func failureSaysWhy() {
        let state = run([event("UserPromptSubmit", at: 0), event("StopFailure", at: 5, error: "rate_limit")])
        #expect(state?.turn == .failed)
        #expect(state?.line == "额度用完了")
        #expect(Copy.failureReason("something_new") == "出错了")
    }

    // Rule 3: Esc, seen by polling.

    @Test func idleWithoutStopForThreeSecondsIsInterrupted() {
        let working = run([event("UserPromptSubmit", at: 0)])!
        let seen = RoundMachine.observeIdle(working, at: date(10))
        #expect(seen.turn == .working)
        #expect(RoundMachine.observeIdle(seen, at: date(12)).turn == .working)
        let interrupted = RoundMachine.observeIdle(seen, at: date(13))
        #expect(interrupted.turn == .interrupted)
    }

    @Test func lateStopWinsOverTheInterruptionGuess() {
        let working = run([event("UserPromptSubmit", at: 0)])!
        let guessed = RoundMachine.observeIdle(RoundMachine.observeIdle(working, at: date(10)), at: date(14))
        #expect(guessed.turn == .interrupted)
        let stopped = RoundMachine.apply(event("Stop", at: 9.5, reply: "做完了"), to: guessed)
        #expect(stopped?.turn == .completed)
    }

    @Test func eventMeanwhileCancelsTheIdleWatch() {
        let working = run([event("UserPromptSubmit", at: 0)])!
        let seen = RoundMachine.observeIdle(working, at: date(10))
        let busyAgain = RoundMachine.apply(event("PreToolUse", at: 11, tool: "Read"), to: seen)!
        #expect(busyAgain.idleSeenAt == nil)
        #expect(RoundMachine.observeIdle(busyAgain, at: date(14)).turn == .working)
    }

    @Test func waitingIsNotCalledInterruptedByPolling() {
        let waiting = run([event("UserPromptSubmit", at: 0), event("PermissionRequest", at: 1, tool: "Bash")])!
        let polled = RoundMachine.observeIdle(RoundMachine.observeIdle(waiting, at: date(10)), at: date(20))
        #expect(polled.turn == .waiting)
    }

    @Test func busyPollStartsARoundHooksMissedButNotRightAfterAStop() {
        let done = run([event("UserPromptSubmit", at: 0), event("Stop", at: 10)])!
        #expect(RoundMachine.observeBusy(done, at: date(11)).turn == .completed)
        #expect(RoundMachine.observeBusy(done, at: date(30)).turn == .working)
        let background = run([event("UserPromptSubmit", at: 0), event("Stop", at: 10, background: true)])!
        #expect(RoundMachine.observeBusy(background, at: date(60)).turn == .background)
    }

    @Test func aRoundOnlyPollingSawEndsIdleNotInterrupted() {
        let done = run([event("UserPromptSubmit", at: 0), event("Stop", at: 10)])!
        let revived = RoundMachine.observeBusy(done, at: date(30))
        #expect(revived.turn == .working)
        #expect(revived.shownSince == date(30))
        let ended = RoundMachine.observeIdle(RoundMachine.observeIdle(revived, at: date(40)), at: date(44))
        #expect(ended.turn == .idle)
    }

    @Test func aHookMakesAPolledRoundAHookedOne() {
        let done = run([event("UserPromptSubmit", at: 0), event("Stop", at: 10)])!
        let revived = RoundMachine.observeBusy(done, at: date(30))
        let hooked = RoundMachine.apply(event("PreToolUse", at: 31, tool: "Read"), to: revived)!
        let ended = RoundMachine.observeIdle(RoundMachine.observeIdle(hooked, at: date(40)), at: date(44))
        #expect(ended.turn == .interrupted)
    }

    // Earlier rounds, for the detail.

    @Test func aNewRoundPutsTheLastOneAway() {
        let state = run([
            event("UserPromptSubmit", at: 0, prompt: "修复按钮"),
            event("Stop", at: 10, reply: "按钮修好了"),
            event("UserPromptSubmit", at: 20, prompt: "再跑一遍测试"),
        ])!
        #expect(state.earlier == [TranscriptTurn(prompt: "修复按钮", reply: "按钮修好了", at: date(0))])
        #expect(state.turns.map(\.prompt) == ["修复按钮", "再跑一遍测试"])
        #expect(state.turns.last?.reply == nil)
    }

    @Test func wakingUpIsTheSameRoundAndHistoryIsCapped() {
        var events: [HookEvent] = []
        for round in 0..<7 {
            let start = Double(round * 100)
            events.append(event("UserPromptSubmit", at: start, prompt: "第 \(round) 轮"))
            events.append(event("Stop", at: start + 10, reply: "好了", background: round == 6))
        }
        events.append(event("UserPromptSubmit", at: 620, woke: true))
        let state = run(events)!
        #expect(state.turns.count == RoundMachine.maxTurns)
        #expect(state.turns.map(\.prompt).last == "第 6 轮")
        #expect(state.turns.map(\.prompt).first == "第 2 轮")
    }

    // A finished round stops standing out after a while.

    @Test func aFinishedRoundFadesToIdleAfterFiveMinutes() {
        let done = run([event("UserPromptSubmit", at: 0), event("Stop", at: 10, reply: "做完了")])!
        #expect(RoundMachine.fade(done, at: date(309)).turn == .completed)
        #expect(RoundMachine.fade(done, at: date(310)).turn == .idle)
        let working = run([event("UserPromptSubmit", at: 0)])!
        let interrupted = RoundMachine.observeIdle(RoundMachine.observeIdle(working, at: date(10)), at: date(13))
        #expect(RoundMachine.fade(interrupted, at: date(400)).turn == .idle)
        let failed = run([event("UserPromptSubmit", at: 0), event("StopFailure", at: 5, error: "rate_limit")])!
        #expect(RoundMachine.fade(failed, at: date(1000)).turn == .failed)
    }
}

struct TrackerHookTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000_000)

    func record(_ busy: Bool) -> AgentRecord {
        AgentRecord(sessionId: "s", pid: 7, cwd: "/p", name: "p-1a", startedAt: 0, status: busy ? "busy" : "idle")
    }

    func hook(_ name: String, at seconds: Double, tool: String? = nil, detail: String? = nil) -> HookEvent {
        HookEvent(event: name, session: "s", at: (t0.timeIntervalSince1970 + seconds) * 1000, tool: tool, detail: detail)
    }

    let project: (String) -> ProjectInfo = { ProjectInfo(root: $0, branch: nil) }

    @Test func hooksDriveTheRowOnceTheSessionIsListed() {
        var tracker = SessionTracker()
        // The hook can arrive before polling lists the session.
        tracker.applyHook(hook("UserPromptSubmit", at: 0))
        tracker.applyHook(hook("PermissionRequest", at: 1, tool: "Edit", detail: "a.ts"))
        #expect(tracker.live.isEmpty)
        tracker.applyPoll([record(true)], at: t0 + 2, project: project)
        #expect(tracker.live["s"]?.state == .waiting)
        #expect(tracker.live["s"]?.detail == "想改 a.ts，等你点头")
        #expect(PanelLayout.overallStatus(Array(tracker.live.values)) == .waiting(count: 1))
    }

    @Test func withoutHooksPollingAloneDecides() {
        var tracker = SessionTracker()
        tracker.applyPoll([record(true)], at: t0, project: project)
        #expect(tracker.live["s"]?.state == .working)
        tracker.applyPoll([record(false)], at: t0 + 5, project: project)
        #expect(tracker.live["s"]?.state == .idle)
        #expect(tracker.needsRecheck == false)
    }

    @Test func escIsSeenAcrossTwoPolls() {
        var tracker = SessionTracker()
        tracker.applyPoll([record(true)], at: t0, project: project)
        tracker.applyHook(hook("UserPromptSubmit", at: 1))
        tracker.applyPoll([record(false)], at: t0 + 10, project: project)
        #expect(tracker.needsRecheck)
        #expect(tracker.live["s"]?.state == .working)
        tracker.applyPoll([record(false)], at: t0 + 13, project: project)
        #expect(tracker.live["s"]?.state == .interrupted)
    }

    @Test func hookStateOfAVanishedSessionGoesAway() {
        var tracker = SessionTracker()
        tracker.applyPoll([record(true)], at: t0, project: project)
        tracker.applyHook(hook("UserPromptSubmit", at: 1))
        tracker.applyPoll([], at: t0 + 10, project: project)
        #expect(tracker.rounds["s"] != nil)
        tracker.applyPoll([], at: t0 + 12, project: project)
        #expect(tracker.recent.first?.id == "s")
        #expect(tracker.rounds.isEmpty)
    }

    @Test func finishedRowFadesOnALaterPoll() {
        var tracker = SessionTracker()
        tracker.applyHook(hook("UserPromptSubmit", at: 0))
        tracker.applyHook(hook("Stop", at: 10))
        tracker.applyPoll([record(false)], at: t0 + 20, project: project)
        #expect(tracker.live["s"]?.state == .completed)
        tracker.applyPoll([record(false)], at: t0 + 320, project: project)
        #expect(tracker.live["s"]?.state == .idle)
    }

    @Test func savedRoundsSurviveARestartWhenNothingHappenedMeanwhile() {
        var tracker = SessionTracker()
        tracker.applyHook(hook("UserPromptSubmit", at: 0))
        tracker.applyHook(hook("PermissionRequest", at: 1, tool: "Edit", detail: "a.ts"))
        var restarted = SessionTracker()
        restarted.restore(tracker.rounds)
        restarted.applyPoll([record(false)], at: t0 + 60, project: project) { _ in
            TranscriptSummary(modifiedAt: self.t0 + 1)
        }
        #expect(restarted.live["s"]?.state == .waiting)
    }

    @Test func savedRoundsGoWhenTheTranscriptMovedOnWithoutUs() {
        var tracker = SessionTracker()
        tracker.applyHook(hook("UserPromptSubmit", at: 0))
        tracker.applyHook(hook("PermissionRequest", at: 1, tool: "Edit", detail: "a.ts"))
        var restarted = SessionTracker()
        restarted.restore(tracker.rounds)
        restarted.applyPoll([record(false)], at: t0 + 60, project: project) { _ in
            TranscriptSummary(modifiedAt: self.t0 + 30)
        }
        #expect(restarted.live["s"]?.state == .idle)
        #expect(restarted.rounds.isEmpty)
    }
}

struct SavedStateTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000_000)
    let project: (String) -> ProjectInfo = { ProjectInfo(root: $0, branch: nil) }

    func record(_ id: String) -> AgentRecord {
        AgentRecord(sessionId: id, pid: 7, cwd: "/p", name: "p-1a", startedAt: 0, status: "idle")
    }

    @Test func roundsAndSessionsRoundTripThroughFiles() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("state.json")
        var tracker = SessionTracker()
        tracker.applyHook(HookEvent(event: "PermissionRequest", session: "a", at: 1_000_000, tool: "Edit", detail: "a.ts"))
        tracker.applyPoll([record("a")], at: t0, project: project) { _ in
            TranscriptSummary(title: "修按钮", modifiedAt: self.t0)
        }
        try SavedState.save(tracker.rounds, to: file)
        #expect(SavedState.load([String: HookState].self, from: file) == tracker.rounds)
        try SavedState.save(tracker.savedSessions, to: file)
        #expect(SavedState.load([Session].self, from: file) == tracker.savedSessions)
        #expect(SavedState.load([Session].self, from: folder.appendingPathComponent("missing.json")) == nil)
    }

    @Test func sessionsClosedWhileTheAppWasOffLandInRecent() {
        var tracker = SessionTracker()
        tracker.applyPoll([record("kept"), record("closed")], at: t0, project: project) { _ in
            TranscriptSummary(modifiedAt: self.t0 - 600)
        }
        var restarted = SessionTracker()
        restarted.restore([:], sessions: tracker.savedSessions)
        restarted.applyPoll([record("kept")], at: t0 + 3600, project: project)
        #expect(restarted.live.keys.sorted() == ["kept"])
        #expect(restarted.recent.map(\.id) == ["closed"])
        // Closed when it last wrote, not when the app noticed.
        #expect(restarted.recent.first?.endedAt == t0 - 600)
    }
}

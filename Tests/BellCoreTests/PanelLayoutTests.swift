import Foundation
import Testing
@testable import BellCore

struct PanelLayoutTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func session(
        _ id: String,
        root: String,
        branch: String? = "main",
        state: RoundState = .idle,
        started: TimeInterval = 0,
        since: TimeInterval = 0
    ) -> Session {
        Session(
            id: id, pid: 1, cwd: root, project: ProjectInfo(root: root, branch: branch),
            name: id, startedAt: t0 + started, state: state, stateSince: t0 + since
        )
    }

    @Test func sidebarListsLiveProjectsThenOnesWithOnlyClosedSessions() {
        var closedA = session("closedA", root: "/a")
        closedA.endedAt = t0 + 50
        var closedD = session("closedD", root: "/d")
        closedD.endedAt = t0 + 60
        let projects = PanelLayout.projects(
            live: [session("idle", root: "/a"), session("wait", root: "/c", state: .waiting)],
            recent: [closedD, closedA]
        )
        #expect(projects.map(\.name) == ["c", "a", "d"])
        #expect(projects[1].live.map(\.id) == ["idle"])
        #expect(projects[1].closed.map(\.id) == ["closedA"])
        #expect(projects[2].live.isEmpty)
        #expect(projects[2].closed.map(\.id) == ["closedD"])
    }

    @Test func waitingProjectFirstThenWorking() {
        let groups = PanelLayout.groups([
            session("idle", root: "/a", started: 0),
            session("work", root: "/b", state: .working, started: 10),
            session("wait", root: "/c", state: .waiting, started: 20),
        ])
        #expect(groups.map(\.name) == ["c", "b", "a"])
    }

    @Test func pinsStayAboveOtherProjectsInBothLayouts() {
        let live = [
            session("wait", root: "/a", state: .waiting),
            session("work", root: "/b", state: .working),
            session("idle", root: "/c"),
        ]
        var closed = session("closed", root: "/d")
        closed.endedAt = t0
        let pinned = ["/c", "/d", "/missing", "/c"]
        #expect(PanelLayout.groups(live, pinned: pinned).map(\.id) == ["/c", "/a", "/b"])
        #expect(PanelLayout.projects(live: live, recent: [closed], pinned: pinned).map(\.id) == ["/c", "/d", "/a", "/b"])
    }

    @Test func insideGroupWaitingThenWorkingThenMostRecentlyActive() {
        let groups = PanelLayout.groups([
            session("quietLong", root: "/a", started: 0, since: 10),
            session("quietLately", root: "/a", started: 30, since: 80),
            session("work", root: "/a", state: .working, started: 0, since: 20),
            session("waitNew", root: "/a", state: .waiting, started: 5, since: 100),
            session("waitOld", root: "/a", state: .waiting, started: 40, since: 50),
        ])
        #expect(groups[0].sessions.map(\.id) == ["waitOld", "waitNew", "work", "quietLately", "quietLong"])
    }

    @Test func workingRoundsStartedLatelyComeFirst() {
        let groups = PanelLayout.groups([
            session("early", root: "/a", state: .working, since: 10),
            session("late", root: "/a", state: .background, since: 90),
        ])
        #expect(groups[0].sessions.map(\.id) == ["late", "early"])
    }

    @Test func quietProjectsByMostRecentActivity() {
        let groups = PanelLayout.groups([
            session("stale", root: "/a", started: 0, since: 10),
            session("fresh", root: "/b", started: 50, since: 90),
        ])
        #expect(groups.map(\.name) == ["b", "a"])
    }

    @Test func sharedBranchGoesOnGroup() {
        let groups = PanelLayout.groups([session("a", root: "/p"), session("b", root: "/p")])
        #expect(groups[0].branch == "main")
        #expect(groups[0].branchPerRow == false)
    }

    @Test func differentBranchesGoOnRows() {
        let groups = PanelLayout.groups([session("a", root: "/p"), session("b", root: "/p", branch: "feat")])
        #expect(groups[0].branch == nil)
        #expect(groups[0].branchPerRow == true)
    }

    @Test func overallStatus() {
        #expect(PanelLayout.overallStatus([]) == .idle)
        #expect(PanelLayout.overallStatus([session("a", root: "/p")]) == .idle)
        #expect(PanelLayout.overallStatus([session("a", root: "/p", state: .working)]) == .working)
        #expect(PanelLayout.overallStatus([
            session("a", root: "/p", state: .waiting),
            session("b", root: "/p", state: .waiting),
            session("c", root: "/p", state: .failed),
        ]) == .waiting(count: 2))
        #expect(PanelLayout.overallStatus([session("a", root: "/p", state: .failed)]) == .failed)
    }
}

struct CopyTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func session(_ state: RoundState) -> Session {
        Session(id: "x", pid: 1, cwd: "/p", project: ProjectInfo(root: "/p", branch: nil),
                startedAt: t0, state: state, stateSince: t0)
    }

    @Test func header() {
        #expect(Copy.header([]) == nil)
        #expect(Copy.header([session(.idle), session(.completed)]) == nil)
        #expect(Copy.header([session(.waiting), session(.failed), session(.background)]) == "1 个待确认 · 1 个出错 · 1 个在工作")
        #expect(Copy.header([session(.working), session(.working)]) == "2 个在工作")
    }

    @Test func elapsed() {
        #expect(Copy.elapsed(0) == "刚刚")
        #expect(Copy.elapsed(59) == "刚刚")
        #expect(Copy.elapsed(180) == "3 分")
        #expect(Copy.elapsed(3600) == "1 小时")
        #expect(Copy.elapsed(3900) == "1 小时 5 分")
        #expect(Copy.elapsed(-5) == "刚刚")
    }

    @Test func endedOverridesState() {
        var ended = session(.working)
        ended.endedAt = t0
        #expect(Copy.statusWord(ended) == "已结束")
        #expect(Copy.statusWord(session(.failed)) == "出错了")
    }
}

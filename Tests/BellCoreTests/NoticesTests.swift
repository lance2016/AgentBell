import Foundation
import Testing
@testable import BellCore

struct NoticesTests {
    let t0 = Date(timeIntervalSince1970: 1_000_000_000)

    func session(_ state: RoundState, detail: String? = nil, round: TimeInterval? = nil, since: TimeInterval = 0) -> Session {
        var session = Session(
            id: "s", pid: 7, cwd: "/code/ai-pet", project: ProjectInfo(root: "/code/ai-pet", branch: nil),
            startedAt: t0, state: state, stateSince: t0 + since, detail: detail,
            transcript: TranscriptSummary(title: "修复提醒按钮挤在一起", modifiedAt: t0)
        )
        session.roundStartedAt = round.map { t0 + since - $0 }
        return session
    }

    @Test func askingPostsAndAnsweringWithdraws() {
        let asked = Notices.changes(
            from: ["s": session(.working)], to: ["s": session(.waiting, detail: "想改 PetSpeech.tsx，等你点头")], prefs: NoticePrefs()
        )
        #expect(asked.post == [Notice(
            session: "s", kind: .waiting, title: "ai-pet 等你确认",
            subtitle: "修复提醒按钮挤在一起", body: "想改 PetSpeech.tsx，等你点头"
        )])
        #expect(asked.post.first?.silent == false)
        let answered = Notices.changes(from: ["s": session(.waiting)], to: ["s": session(.working)], prefs: NoticePrefs())
        #expect(answered.post.isEmpty)
        #expect(answered.withdraw == ["s.waiting"])
        let gone = Notices.changes(from: ["s": session(.waiting)], to: [:], prefs: NoticePrefs())
        #expect(gone.withdraw == ["s.waiting"])
    }

    @Test func aFailureIsWithdrawnOnceTheSessionMovesOn() {
        let retried = Notices.changes(from: ["s": session(.failed)], to: ["s": session(.working)], prefs: NoticePrefs())
        #expect(retried.withdraw == ["s.failed"])
        let gone = Notices.changes(from: ["s": session(.failed)], to: [:], prefs: NoticePrefs())
        #expect(gone.withdraw == ["s.failed"])
        let still = Notices.changes(from: ["s": session(.failed)], to: ["s": session(.failed)], prefs: NoticePrefs())
        #expect(still.withdraw.isEmpty)
    }

    @Test func sameStateSaysNothingAgain() {
        let waiting = session(.waiting, detail: "有话问你")
        #expect(Notices.changes(from: ["s": waiting], to: ["s": waiting], prefs: NoticePrefs()) == Notices.Changes())
        let next = Notices.changes(from: ["s": waiting], to: ["s": session(.waiting, detail: "写好计划了，等你过目")], prefs: NoticePrefs())
        #expect(next.post.map(\.body) == ["写好计划了，等你过目"])
    }

    @Test func onlyLongRoundsAnnounceTheyAreDone() {
        let long = Notices.changes(
            from: ["s": session(.working)], to: ["s": session(.completed, detail: "测试全部通过", round: 4 * 60 + 5)], prefs: NoticePrefs()
        )
        #expect(long.post.first?.title == "ai-pet 这一轮做完了 · 4 分钟")
        #expect(long.post.first?.silent == true)
        let short = Notices.changes(from: ["s": session(.working)], to: ["s": session(.completed, round: 20)], prefs: NoticePrefs())
        #expect(short.post.isEmpty)
        let unknown = Notices.changes(from: ["s": session(.working)], to: ["s": session(.completed)], prefs: NoticePrefs())
        #expect(unknown.post.isEmpty)
    }

    @Test func theUserSetsHowLongALongRoundIs() {
        let patient = NoticePrefs(longRound: 3 * 60)
        let twoMinutes = Notices.changes(from: ["s": session(.working)], to: ["s": session(.completed, round: 2 * 60)], prefs: patient)
        #expect(twoMinutes.post.isEmpty)
        let fourMinutes = Notices.changes(from: ["s": session(.working)], to: ["s": session(.completed, round: 4 * 60)], prefs: patient)
        #expect(fourMinutes.post.count == 1)
    }

    @Test func quietStatesNeverNotify() {
        for state in [RoundState.working, .background, .interrupted, .idle] {
            #expect(Notices.changes(from: ["s": session(.waiting)], to: ["s": session(state)], prefs: NoticePrefs()).post.isEmpty)
        }
    }

    @Test func prefsTurnKindsAndContentOff() {
        let failed = ["s": session(.failed, detail: "额度用完了")]
        #expect(Notices.changes(from: [:], to: failed, prefs: NoticePrefs(failed: false)).post.isEmpty)
        let plain = Notices.changes(from: [:], to: failed, prefs: NoticePrefs(showContent: false)).post.first
        #expect(plain?.title == "ai-pet 出错了")
        #expect(plain?.subtitle == nil)
        #expect(plain?.body == nil)
    }

    @Test func roundLength() {
        #expect(Copy.roundLength(40) == "40 秒")
        #expect(Copy.roundLength(245) == "4 分钟")
        #expect(Copy.roundLength(3900) == "1 小时 5 分钟")
    }
}

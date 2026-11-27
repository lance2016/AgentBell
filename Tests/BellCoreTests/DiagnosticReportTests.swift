import Foundation
import Testing
@testable import BellCore

struct DiagnosticReportTests {
    private let utc = TimeZone(identifier: "UTC")!
    // 2026-11-18 11:06:40.250 UTC
    private let moment = Date(timeIntervalSince1970: 1_795_000_000.25)

    @Test func formatsEachLineWithTimeLevelAndCategory() {
        let line = DiagnosticReport.Line(date: moment, level: "error", category: "jump", message: "ghostty focus failed")
        #expect(DiagnosticReport.format([line], timeZone: utc) == [
            "2026-11-18 11:06:40.250 [error] jump: ghostty focus failed",
        ])
    }

    @Test func rendersEnvironmentBeforeTheLog() {
        let lines = [
            DiagnosticReport.Line(date: moment, level: "notice", category: "jump", message: "jump has only app"),
            DiagnosticReport.Line(date: moment.addingTimeInterval(1), level: "error", category: "jump", message: "focus failed"),
        ]
        let text = DiagnosticReport.render(
            environment: [("AgentBell", "1.3.1 (42)"), ("Ghostty", "1.2.3 · 已授权")],
            lines: lines,
            generatedAt: moment,
            timeZone: utc
        )
        #expect(text == """
        AgentBell 诊断报告
        导出时间：2026-11-18 11:06:40

        == 环境 ==
        AgentBell：1.3.1 (42)
        Ghostty：1.2.3 · 已授权

        == 日志（本次启动以来，2 条）==
        2026-11-18 11:06:40.250 [notice] jump: jump has only app
        2026-11-18 11:06:41.250 [error] jump: focus failed

        """)
    }

    @Test func saysSoWhenThereIsNoLog() {
        let text = DiagnosticReport.render(environment: [], lines: [], generatedAt: moment, timeZone: utc)
        #expect(text.hasSuffix("== 日志（本次启动以来，0 条）==\n（没有日志）\n"))
    }

    @Test func namesTheFileByExportTime() {
        #expect(DiagnosticReport.fileName(at: moment, timeZone: utc) == "AgentBell-log-20261118-110640.txt")
    }
}

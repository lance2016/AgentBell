import Foundation

/// The text a user hands over when something goes wrong: AgentBell's view of the machine
/// (versions, terminals, permissions), then this run's log. The log viewer shows the same
/// lines, so what the user sees is what they send.
public enum DiagnosticReport {
    public struct Line: Equatable, Sendable {
        public let date: Date
        public let level: String
        public let category: String
        public let message: String

        public init(date: Date, level: String, category: String, message: String) {
            self.date = date
            self.level = level
            self.category = category
            self.message = message
        }
    }

    public static func format(_ lines: [Line], timeZone: TimeZone = .current) -> [String] {
        let formatter = dateFormatter("yyyy-MM-dd HH:mm:ss.SSS", timeZone: timeZone)
        return lines.map { "\(formatter.string(from: $0.date)) [\($0.level)] \($0.category): \($0.message)" }
    }

    /// - Parameter environment: label and value pairs, in the order shown.
    public static func render(
        environment: [(String, String)],
        lines: [Line],
        generatedAt: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let header = [
            "AgentBell 诊断报告",
            "导出时间：\(dateFormatter("yyyy-MM-dd HH:mm:ss", timeZone: timeZone).string(from: generatedAt))",
            "",
            "== 环境 ==",
        ]
        let facts = environment.map { "\($0.0)：\($0.1)" }
        let logHeader = ["", "== 日志（本次启动以来，\(lines.count) 条）=="]
        let log = lines.isEmpty ? ["（没有日志）"] : format(lines, timeZone: timeZone)
        return (header + facts + logHeader + log).joined(separator: "\n") + "\n"
    }

    public static func fileName(at date: Date, timeZone: TimeZone = .current) -> String {
        "AgentBell-log-\(dateFormatter("yyyyMMdd-HHmmss", timeZone: timeZone).string(from: date)).txt"
    }

    private static func dateFormatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}

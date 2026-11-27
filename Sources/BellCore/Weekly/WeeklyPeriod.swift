import Foundation

/// The week a report covers. Weeks run Monday to Sunday, as weekly reports at work do,
/// whatever the first weekday in the user's region settings.
public enum WeeklyPeriod: String, CaseIterable, Sendable, Codable {
    case thisWeek
    case lastWeek

    public var title: String {
        switch self {
        case .thisWeek: "本周"
        case .lastWeek: "上周"
        }
    }

    /// The week after: what a report's plan is for.
    public var nextTitle: String {
        switch self {
        case .thisWeek: "下周"
        case .lastWeek: "本周"
        }
    }

    public func interval(now: Date = Date(), timeZone: TimeZone = .current) -> DateInterval {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone
        let week = calendar.dateInterval(of: .weekOfYear, for: now)!
        switch self {
        case .thisWeek:
            return week
        case .lastWeek:
            let start = calendar.date(byAdding: .weekOfYear, value: -1, to: week.start)!
            return DateInterval(start: start, end: week.start)
        }
    }

    /// "11月23日 – 11月29日": the first and the last day, both included.
    public static func days(_ interval: DateInterval, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日"
        let last = interval.end.addingTimeInterval(-1)
        return "\(formatter.string(from: interval.start)) – \(formatter.string(from: last))"
    }
}

/// What a report session reports on. Kept in `weekly.json` in the folder the session
/// runs in, so a session resumed there can say so.
public struct WeeklyCheckout: Sendable, Equatable, Codable {
    /// "11月23日 – 11月29日".
    public var days: String?
    /// The first line of the prompt AgentBell sent: it is not a question of the user's.
    public var prompt: String?

    static let fileName = "weekly.json"

    public init(days: String? = nil, prompt: String? = nil) {
        self.days = days
        self.prompt = prompt
    }

    /// The session's name until the user gives one: Claude titles no `-p` session.
    public var title: String { days.map { "周报 \($0)" } ?? "周报" }

    /// True when `prompt` is the one AgentBell sent. Claude Code folds its lines into one.
    public func isRequest(_ prompt: String) -> Bool {
        guard let sent = self.prompt, !sent.isEmpty else { return false }
        return prompt.hasPrefix(sent)
    }

    static func read(folder: String) -> WeeklyCheckout {
        let url = URL(fileURLWithPath: folder).appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return WeeklyCheckout() }
        return (try? JSONDecoder().decode(WeeklyCheckout.self, from: data)) ?? WeeklyCheckout()
    }

    func write(in folder: URL) throws {
        try JSONEncoder().encode(self).write(to: folder.appendingPathComponent(Self.fileName))
    }
}

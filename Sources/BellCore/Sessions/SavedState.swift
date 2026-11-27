import Foundation

/// What the app keeps on disk, so restarting it forgets neither which session waits
/// for you or just finished, nor which sessions closed lately.
public enum SavedState {
    public static var roundsFile: URL { BellPaths.supportDirectory.appendingPathComponent("rounds.json") }
    public static var sessionsFile: URL { BellPaths.supportDirectory.appendingPathComponent("sessions.json") }
    /// Names given to sessions in AgentBell, by session id.
    public static var titlesFile: URL { BellPaths.supportDirectory.appendingPathComponent("titles.json") }

    /// Nil when there is no file or it cannot be read: polling fills in.
    public static func load<Value: Decodable>(_ type: Value.Type, from file: URL) -> Value? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    public static func save<Value: Encodable>(_ value: Value, to file: URL) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic])
    }
}

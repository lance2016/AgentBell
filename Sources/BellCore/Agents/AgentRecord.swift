import Foundation

/// One element of `claude agents --json`.
///
/// Verified against Claude Code 2.1.332:
/// `{ pid, cwd, kind, startedAt, sessionId, name, status }`, where `startedAt` is epoch
/// milliseconds and `status` is `busy` or `idle`.
public struct AgentRecord: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let pid: Int32?
    public let cwd: String
    public let name: String?
    public let kind: String?
    public let startedAt: Double?
    public let status: String?

    public init(
        sessionId: String,
        pid: Int32?,
        cwd: String,
        name: String? = nil,
        kind: String? = "interactive",
        startedAt: Double? = nil,
        status: String? = nil
    ) {
        self.sessionId = sessionId
        self.pid = pid
        self.cwd = cwd
        self.name = name
        self.kind = kind
        self.startedAt = startedAt
        self.status = status
    }

    public var isBusy: Bool { status == "busy" }

    public var startedAtDate: Date? {
        startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    /// Parses the whole array. A malformed element is skipped rather than failing the
    /// list, so one odd session never hides all the others.
    public static func parseList(_ data: Data) throws -> [AgentRecord] {
        try parseSnapshot(data).records
    }

    public struct Snapshot: Sendable {
        public let records: [AgentRecord]
        public let isComplete: Bool
    }

    public static func parseSnapshot(_ data: Data) throws -> Snapshot {
        let elements = try JSONDecoder().decode([Lossy].self, from: data)
        let records = elements.compactMap(\.record)
        return Snapshot(records: records, isComplete: records.count == elements.count)
    }

    private struct Lossy: Decodable {
        let record: AgentRecord?

        init(from decoder: Decoder) throws {
            record = try? AgentRecord(from: decoder)
        }
    }
}

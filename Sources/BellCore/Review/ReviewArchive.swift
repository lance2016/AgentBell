import Foundation

/// The models a review can run on, as Claude Code's `/model` offers them.
public enum ReviewModel: String, CaseIterable, Sendable, Codable {
    /// Claude Code's own default: no `--model`, as "Default (recommended)" in `/model`.
    case recommended = ""
    case fable
    case opus

    public var title: String {
        switch self {
        case .recommended: "默认（推荐）"
        case .fable: "Fable"
        case .opus: "Opus"
        }
    }

    var arguments: [String] { self == .recommended ? [] : ["--model", rawValue] }
}

/// A finished review, kept as `report.md` and `record.json` in a folder of its own.
public struct ReviewRecord: Sendable, Equatable, Codable, Identifiable {
    public let id: String
    /// The local repository the review was asked for.
    public let repository: String
    public let sourceBranch: String
    public let targetBranch: String
    public let mergeRequest: String?
    public let head: String
    public let model: ReviewModel
    public let focus: String
    public let startedAt: Date
    public let finishedAt: Date
    /// Claude's session, for `claude --resume`.
    public let sessionID: String?
    /// The detached checkout the review ran in; pruned after a few days.
    public let checkout: String
    /// Where the record is kept. Not stored: the folder may be moved.
    public internal(set) var folder = URL(fileURLWithPath: "/")

    private enum CodingKeys: String, CodingKey {
        case id, repository, sourceBranch, targetBranch, mergeRequest, head, model, focus,
             startedAt, finishedAt, sessionID, checkout
    }

    public init(id: String, plan: ReviewPlan, outcome: ReviewOutcome, model: ReviewModel, focus: String,
                startedAt: Date, finishedAt: Date = Date()) {
        self.id = id
        repository = plan.directory.path
        sourceBranch = plan.sourceBranch
        targetBranch = plan.targetBranch
        mergeRequest = plan.mergeRequest
        head = plan.head
        self.model = model
        self.focus = focus
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        sessionID = outcome.sessionID
        checkout = outcome.checkout.path
    }

    public var repositoryName: String { (repository as NSString).lastPathComponent }
    public var range: String { "\(sourceBranch) → \(targetBranch)" }
    public var reportURL: URL { folder.appendingPathComponent(ReviewArchive.reportName) }
}

/// The folder finished reviews are saved in, one subfolder each.
public struct ReviewArchive: Sendable {
    public let root: URL

    public static let reportName = "report.md"
    static let recordName = "record.json"

    public static var defaultRoot: URL {
        BellPaths.supportDirectory.appendingPathComponent("Review Reports", isDirectory: true)
    }

    public init(root: URL) {
        self.root = root
    }

    /// Newest first. Folders without a readable record are not reviews and are skipped.
    public func load() -> [ReviewRecord] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        let decoder = Self.decoder
        return folders.compactMap { folder -> ReviewRecord? in
            let url = folder.appendingPathComponent(Self.recordName)
            guard let data = try? Data(contentsOf: url),
                  var record = try? decoder.decode(ReviewRecord.self, from: data) else { return nil }
            record.folder = folder
            return record
        }
        .sorted { $0.finishedAt > $1.finishedAt }
    }

    /// Writes the report and its record into a new folder named so Finder sorts by time.
    public func save(_ record: ReviewRecord, report: String) throws -> ReviewRecord {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let folder = try makeFolder(for: record)
        var saved = record
        saved.folder = folder
        do {
            try Data(report.utf8).write(to: saved.reportURL, options: .atomic)
            try Self.encoder.encode(saved).write(to: folder.appendingPathComponent(Self.recordName), options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return saved
    }

    public func report(_ record: ReviewRecord) -> String? {
        try? String(contentsOf: record.reportURL, encoding: .utf8)
    }

    public func delete(_ record: ReviewRecord) throws {
        try FileManager.default.removeItem(at: record.folder)
    }

    private func makeFolder(for record: ReviewRecord) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let branch = record.sourceBranch.replacingOccurrences(of: "/", with: "-")
        let base = "\(formatter.string(from: record.finishedAt)) \(record.repositoryName) \(branch)"
        for attempt in 1...100 {
            let folder = root.appendingPathComponent(attempt == 1 ? base : "\(base) \(attempt)", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                return folder
            } catch CocoaError.fileWriteFileExists {
                continue
            }
        }
        throw ReviewFailure("无法在保存位置创建审查记录。")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

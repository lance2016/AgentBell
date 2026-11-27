import Foundation

/// What a session's transcript says about it, taken from the end of the file only:
/// Claude's own title, the last prompt and the first line of the last reply.
/// Nothing else is kept, and none of it is ever logged.
public struct TranscriptSummary: Sendable, Equatable, Codable {
    public var title: String?
    /// The name given with /rename, which `claude agents` stops reporting once the
    /// session has closed.
    public var customTitle: String?
    public var lastPrompt: String?
    public var lastReply: String?
    /// The last few rounds in the tail, oldest first, for the session's detail.
    public var turns: [TranscriptTurn] = []
    /// The file's modification time: when the session last did anything.
    public var modifiedAt: Date

    public init(title: String? = nil, lastPrompt: String? = nil, lastReply: String? = nil, modifiedAt: Date) {
        self.title = title
        self.lastPrompt = lastPrompt
        self.lastReply = lastReply
        self.modifiedAt = modifiedAt
    }
}

/// One round as the detail shows it: the first line of what was asked and of the
/// last reply to it.
public struct TranscriptTurn: Sendable, Equatable, Codable {
    /// Nil for a round no prompt was heard for.
    public var prompt: String?
    public var reply: String?
    public var at: Date?

    public init(prompt: String?, reply: String? = nil, at: Date? = nil) {
        self.prompt = prompt
        self.reply = reply
        self.at = at
    }
}

/// One round for the session detail: the question as typed, and Claude's closing answer.
public struct ConversationTurn: Sendable, Equatable {
    public let prompt: String
    /// The last text Claude wrote in the round; empty while it has said nothing.
    public var reply: String
    public let at: Date?
    public internal(set) var sourceOffset: UInt64?

    public init(prompt: String, reply: String = "", at: Date? = nil) {
        self.prompt = prompt
        self.reply = reply
        self.at = at
    }
}

extension ISO8601DateFormatter {
    /// Claude Code's timestamps, like "2026-11-26T06:39:28.481Z".
    nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}

public enum Transcript {
    /// Claude Code writes its `ai-title` and `last-prompt` lines near the end; one
    /// attachment line can be large, so the tail is generous.
    static let tailBytes = 256 * 1024
    static let maxTitleChars = 80
    static let maxReplyChars = 160
    /// A heading this short is a section label ("结论", "Summary"), not news.
    static let maxLabelChars = 8
    static let maxTurns = 5

    public static var projectsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }

    /// `~/.claude/projects/<cwd with every non-alphanumeric as "-">/<session>.jsonl`.
    /// Falls back to searching every project folder, since the session's cwd may have
    /// changed after it started.
    public static func locate(sessionID: String, cwd: String, in projects: URL = projectsDirectory) -> URL? {
        let fileName = sessionID + ".jsonl"
        guard isSafeFileName(fileName) else { return nil }
        let fileManager = FileManager.default
        let guess = projects.appendingPathComponent(slug(cwd)).appendingPathComponent(fileName)
        if fileManager.fileExists(atPath: guess.path) { return guess }
        let folders = (try? fileManager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        return folders
            .map { $0.appendingPathComponent(fileName) }
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    static func slug(_ cwd: String) -> String {
        String(cwd.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    private static func isSafeFileName(_ name: String) -> Bool {
        !name.contains("/") && !name.hasPrefix(".")
    }

    public static func read(_ url: URL) -> TranscriptSummary? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let handle = try? FileHandle(forReadingFrom: url)
        else { return nil }
        defer { try? handle.close() }
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        try? handle.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        var summary = summarize(tail: String(decoding: data, as: UTF8.self), cutAtStart: size > UInt64(tailBytes))
        summary.modifiedAt = modified
        return summary
    }

    /// Every round of the session, oldest first, read on demand for the detail. The whole
    /// file is read: a round of tool output can push the question before it megabytes back.
    public static func conversation(_ url: URL) -> [ConversationTurn] {
        (try? Data(contentsOf: url, options: .mappedIfSafe)).map { conversation($0) } ?? []
    }

    public struct ConversationWindow: Sendable {
        public let turns: [ConversationTurn]
        public var hasEarlier: Bool { start > 0 }
        fileprivate let url: URL
        fileprivate let identity: UInt64
        fileprivate let start: UInt64
        fileprivate let end: UInt64
        fileprivate let byteLimit: UInt64
        fileprivate let skipsFirstLine: Bool
    }

    /// Start near the end. A live refresh only reads new complete lines. Loading earlier
    /// history grows the window explicitly, including the context needed to pair replies.
    public static func conversationWindow(
        _ url: URL,
        previous: ConversationWindow? = nil,
        loadEarlier: Bool = false,
        initialBytes: UInt64 = 1_048_576
    ) -> ConversationWindow? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let identity = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
              let size = try? handle.seekToEnd() else { return nil }

        let previous = previous.flatMap {
            $0.url == url && $0.identity == identity && $0.end <= size ? $0 : nil
        }
        let previousLimit = previous?.byteLimit ?? max(1, initialBytes)
        let loadedBytes = previous.map { size - $0.start } ?? 0
        let coveredBytes = min(size, max(previousLimit, loadedBytes))
        let limit = loadEarlier ? coveredBytes + min(previousLimit, size - coveredBytes) : previousLimit
        let appendWindow = loadEarlier ? nil : previous
        let start = appendWindow?.start ?? (size - min(size, limit))
        let readAt = appendWindow?.end ?? start
        guard size > readAt else {
            return previous ?? ConversationWindow(turns: [], url: url, identity: identity,
                                                  start: 0, end: 0, byteLimit: limit, skipsFirstLine: false)
        }
        // Start one byte early to tell a split line from an exact line boundary.
        let padding: UInt64 = appendWindow == nil && readAt > 0 ? 1 : 0
        let fileOffset = readAt - padding
        guard let count = Int(exactly: size - fileOffset),
              let data = try? readBytes(handle, offset: fileOffset, count: count)
        else { return nil }

        let skipsFirstLine = padding > 0 || appendWindow?.skipsFirstLine == true
        let firstNewline = data.firstIndex(of: 0x0A)
        let first = skipsFirstLine ? (firstNewline.map { $0 + 1 } ?? data.count) : 0
        let end = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? (skipsFirstLine ? data.count : 0)
        let lines = first < end ? data[first..<end] : Data()
        let turns = conversation(lines, appendingTo: appendWindow?.turns ?? [],
                                 offset: fileOffset + UInt64(first))
        return ConversationWindow(turns: turns, url: url, identity: identity, start: start,
                                  end: fileOffset + UInt64(end), byteLimit: limit,
                                  skipsFirstLine: skipsFirstLine && firstNewline == nil)
    }

    private static func readBytes(_ handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: count) ?? Data()
    }

    private static let userMark = Array(#""type":"user""#.utf8)
    private static let toolResultMark = Array(#""type":"tool_result""#.utf8)
    private static let assistantMark = Array(#""type":"assistant""#.utf8)
    private static let textMark = Array(#""type":"text""#.utf8)

    static func conversation(
        _ data: Data, appendingTo previous: [ConversationTurn] = [], offset fileOffset: UInt64? = nil
    ) -> [ConversationTurn] {
        var turns = previous
        data.withUnsafeBytes { (file: UnsafeRawBufferPointer) in
            guard let base = file.baseAddress else { return }
            var offset = 0
            while offset < file.count {
                let lineOffset = fileOffset.map { $0 + UInt64(offset) }
                let start = base + offset
                let rest = file.count - offset
                let length = memchr(start, 0x0A, rest).map { start.distance(to: UnsafeRawPointer($0)) } ?? rest
                offset += length + 1
                // Most of a transcript is tool output; only prompts and Claude's own words are decoded.
                let line = UnsafeRawBufferPointer(start: start, count: length)
                let isPrompt = has(line, userMark) && !has(line, toolResultMark)
                guard isPrompt || (has(line, assistantMark) && has(line, textMark)),
                      let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      object["isSidechain"] as? Bool != true,
                      let type = object["type"] as? String
                else { continue }
                if type == "user", let prompt = promptText(object).flatMap(fullPrompt) {
                    let at = (object["timestamp"] as? String).flatMap(ISO8601DateFormatter.withFraction.date(from:))
                    var turn = ConversationTurn(prompt: prompt, at: at)
                    turn.sourceOffset = lineOffset
                    turns.append(turn)
                } else if type == "assistant", !turns.isEmpty, let reply = replyText(object) {
                    turns[turns.count - 1].reply = reply
                }
            }
        }
        return turns
    }

    private static func has(_ line: UnsafeRawBufferPointer, _ mark: [UInt8]) -> Bool {
        memmem(line.baseAddress, line.count, mark, mark.count) != nil
    }

    /// The prompt as typed, without image placeholders or pasted-content tags; nil when
    /// nothing readable is left, as for a slash command's wrapper.
    private static func fullPrompt(_ text: String) -> String? {
        guard firstLine(text, limit: .max) != nil else { return nil }
        let cleaned = text
            .replacingOccurrences(of: #"\[(Image|Pasted text) #\d+[^\]]*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"</?pasted_content[^>]*>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Parses the tail of a transcript. When `cutAtStart`, the first line is partial and skipped.
    static func summarize(tail: String, cutAtStart: Bool) -> TranscriptSummary {
        var summary = TranscriptSummary(modifiedAt: .distantPast)
        var lines = tail.split(separator: "\n", omittingEmptySubsequences: true)
        if cutAtStart, !lines.isEmpty { lines.removeFirst() }
        for line in lines {
            // Cheap filter before decoding: most lines are tool output.
            let interesting = line.contains("\"ai-title\"") || line.contains("\"custom-title\"")
                || line.contains("\"last-prompt\"")
                || line.contains("\"assistant\"") || (line.contains("\"user\"") && !line.contains("\"tool_result\""))
            guard interesting,
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = object["type"] as? String
            else { continue }
            switch type {
            case "ai-title":
                if let title = (object["aiTitle"] as? String).flatMap({ firstLine($0, limit: maxTitleChars) }) {
                    summary.title = title
                }
            case "custom-title":
                if let title = (object["customTitle"] as? String).flatMap({ firstLine($0, limit: maxTitleChars) }) {
                    summary.customTitle = title
                }
            case "last-prompt":
                if let prompt = (object["lastPrompt"] as? String).flatMap({ firstLine($0, limit: maxTitleChars) }) {
                    summary.lastPrompt = prompt
                }
            case "user":
                if let prompt = promptLine(object) {
                    let at = (object["timestamp"] as? String).flatMap(ISO8601DateFormatter.withFraction.date(from:))
                    summary.turns.append(TranscriptTurn(prompt: prompt, at: at))
                    if summary.turns.count > maxTurns { summary.turns.removeFirst() }
                }
            case "assistant":
                if let reply = replyText(object).flatMap(replyLine) {
                    summary.lastReply = reply
                    if !summary.turns.isEmpty { summary.turns[summary.turns.count - 1].reply = reply }
                }
            default:
                break
            }
        }
        return summary
    }

    /// What the user typed, or nil for everything else that is filed as a user line:
    /// tool results, attachments, the compaction summary, slash-command output,
    /// background work waking the session, and the note an interruption leaves.
    private static func promptLine(_ object: [String: Any]) -> String? {
        promptText(object).flatMap { firstLine($0, limit: maxTitleChars) }
    }

    private static func promptText(_ object: [String: Any]) -> String? {
        guard object["isMeta"] as? Bool != true, object["isCompactSummary"] as? Bool != true,
              let message = object["message"] as? [String: Any]
        else { return nil }
        let text: String?
        if let string = message["content"] as? String {
            text = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            text = blocks.first { $0["type"] as? String == "text" }?["text"] as? String
        } else {
            text = nil
        }
        guard let text, !text.hasPrefix("<task-notification>"), !text.hasPrefix("[Request interrupted") else { return nil }
        return text
    }

    private static func replyText(_ object: [String: Any]) -> String? {
        replyTexts(object).last
    }

    private static func replyTexts(_ object: [String: Any]) -> [String] {
        guard let message = object["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]]
        else { return [] }
        return content.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// The first meaningful line, without Markdown marks, pasted-content tags,
    /// `[Image #2]` placeholders or a closing period, cut to `limit`.
    static func firstLine(_ text: String, limit: Int) -> String? {
        let line = text.split(separator: "\n")
            .map { String($0).replacingOccurrences(of: #"\[(Image|Pasted text) #\d+[^\]]*\]"#, with: "", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#>-* ")) }
            .first { !$0.isEmpty && !$0.hasPrefix("<") }
        guard let line else { return nil }
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
        var joined = plain.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while let last = joined.last, "。.".contains(last) { joined.removeLast() }
        guard !joined.isEmpty else { return nil }
        return joined.count > limit ? String(joined.prefix(limit - 1)) + "…" : joined
    }

    /// A reply's first line, past a short section heading such as "## 结论", which
    /// says little; the line under it says what happened.
    public static func replyLine(_ text: String) -> String? {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        if let first = lines.first, first.hasPrefix("#"),
           first.trimmingCharacters(in: CharacterSet(charactersIn: "#* ")).count <= maxLabelChars,
           let body = firstLine(lines.dropFirst().joined(separator: "\n"), limit: maxReplyChars) {
            return body
        }
        return firstLine(text, limit: maxReplyChars)
    }
}

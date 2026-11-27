import Foundation

public enum ReviewRequest: Equatable, Sendable {
    case mergeRequest(project: ReviewProject?, iid: Int)
    case branch(String)

    public static func parse(_ message: String) throws -> Self {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = trimmed.matches(of: #/https:\/\/[^\s<>()\[\]"，。！、]+/#)
        let requests = Set(urls.compactMap { match -> MergeRequestLink? in
            guard let components = URLComponents(string: String(match.output)),
                  let project = ReviewProject(url: components),
                  let marker = project.path.range(of: "/-/merge_requests/"),
                  let iid = number(project.path[marker.upperBound...].split(separator: "/").first ?? ""),
                  let repository = ReviewProject(host: project.host, path: String(project.path[..<marker.lowerBound]))
            else { return nil }
            return MergeRequestLink(project: repository, iid: iid)
        })
        if requests.count > 1 { throw ReviewFailure("消息里有多个合并请求链接，请只保留要审查的一个。") }
        if let request = requests.first { return .mergeRequest(project: request.project, iid: request.iid) }
        let numberText = trimmed.hasPrefix("!") ? trimmed.dropFirst() : trimmed[...]
        if let iid = number(numberText) { return .mergeRequest(project: nil, iid: iid) }
        guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("!"),
              !trimmed.contains(where: { $0.isWhitespace }),
              !trimmed.contains(":") else {
            throw ReviewFailure("请粘贴含完整 GitLab MR 链接的消息，或填写 !编号、分支名。")
        }
        return .branch(trimmed)
    }

    private static func number(_ value: Substring) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(value), number > 0 else { return nil }
        return number
    }

    private struct MergeRequestLink: Hashable {
        let project: ReviewProject
        let iid: Int
    }
}

public struct ReviewProject: Hashable, Sendable {
    public let host: String
    public let path: String

    init?(host: String, path: String) {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !host.isEmpty, !host.hasPrefix("-"), trimmed.split(separator: "/").count >= 2,
              !trimmed.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { return nil }
        self.host = host.lowercased()
        self.path = trimmed
    }

    init?(url: URLComponents) {
        guard url.scheme == "https", let host = url.host,
              url.user == nil, url.password == nil else { return nil }
        self.init(host: url.port.map { "\(host):\($0)" } ?? host, path: url.path)
    }

    public init?(remote: String) {
        let host: String
        let path: String
        if remote.contains("://"), let url = URLComponents(string: remote),
           ["https", "http", "ssh"].contains(url.scheme), let server = url.host {
            host = url.scheme == "ssh" ? server : (url.port.map { "\(server):\($0)" } ?? server)
            path = url.path
        } else if let at = remote.firstIndex(of: "@"), let colon = remote[at...].firstIndex(of: ":") {
            host = String(remote[remote.index(after: at)..<colon])
            path = String(remote[remote.index(after: colon)...])
        } else {
            return nil
        }
        self.init(host: host, path: path.hasSuffix(".git") ? String(path.dropLast(4)) : path)
    }

    var apiPath: String {
        path.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
    }
}

public struct ReviewFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

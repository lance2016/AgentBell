import Foundation

/// The newest published release on GitHub.
public struct Release: Sendable, Equatable {
    /// The tag without a leading "v", such as "0.2.0".
    public let version: String
    /// The release page, where the user downloads it.
    public let page: URL
}

/// Reads GitHub's "latest release" answer and decides whether it is newer than this build.
public enum ReleaseCheck {
    /// Drafts and pre-releases never show up here.
    public static let latestURL = URL(string: "https://api.github.com/repos/lance2016/AgentBell/releases/latest")!

    private struct Payload: Decodable {
        let tag_name: String
        let html_url: URL
    }

    public static func decode(_ data: Data) -> Release? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        return Release(version: strip(payload.tag_name), page: payload.html_url)
    }

    /// Compares dotted numbers; "1.0" and "1.0.0" are the same. A pre-release suffix
    /// such as "-beta" is ignored.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = numbers(candidate)
        let b = numbers(current)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func strip(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    private static func numbers(_ version: String) -> [Int] {
        let core = strip(version).split(separator: "-", maxSplits: 1).first ?? ""
        return core.split(separator: ".").map { Int($0) ?? 0 }
    }
}

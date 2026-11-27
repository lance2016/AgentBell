import Foundation

/// The newest published release on GitHub.
public struct Release: Sendable, Equatable {
    /// The tag without a leading "v", such as "0.2.0".
    public let version: String
    /// The release page, where the user downloads it.
    public let page: URL
    /// The zipped app to install in place, and its signature. Nil when the release has
    /// no signed archive; then only the page is offered.
    public var archive: URL?
    public var signature: URL?
}

/// Reads GitHub's "latest release" answer and decides whether it is newer than this build.
public enum ReleaseCheck {
    /// Drafts and pre-releases never show up here.
    public static let latestURL = URL(string: "https://api.github.com/repos/lance2016/AgentBell/releases/latest")!

    /// The archive `scripts/release.sh` uploads; its signature has ".sig" appended.
    static let archiveSuffix = "-macOS-AppleSilicon.zip"

    private struct Payload: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }

        let tag_name: String
        let html_url: URL
        let assets: [Asset]?
    }

    public static func decode(_ data: Data) -> Release? {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return nil }
        var release = Release(version: strip(payload.tag_name), page: payload.html_url)
        let assets = payload.assets ?? []
        if let archive = assets.first(where: { $0.name.hasSuffix(archiveSuffix) }),
           let signature = assets.first(where: { $0.name == archive.name + ".sig" }) {
            release.archive = archive.browser_download_url
            release.signature = signature.browser_download_url
        }
        return release
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

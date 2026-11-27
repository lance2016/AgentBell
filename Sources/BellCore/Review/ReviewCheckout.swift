import Foundation

/// What a review checkout reviews. Kept in `review.json` beside the checkout, so a
/// session resumed there can say so; checkouts made before the file have all nil.
public struct ReviewCheckout: Sendable, Equatable, Codable {
    public var sourceBranch: String?
    public var targetBranch: String?
    /// The first line of the prompt AgentBell sent: it is not a question of the user's.
    public var prompt: String?

    static let fileName = "review.json"

    /// "feat/x → main", in place of the checkout's detached commit.
    public var range: String? {
        guard let sourceBranch, let targetBranch else { return nil }
        return "\(sourceBranch) → \(targetBranch)"
    }

    /// The session's name until the user gives one: Claude titles no `-p` session.
    public var title: String { sourceBranch.map { "审查 \($0)" } ?? "代码审查" }

    /// True when `prompt` is the one AgentBell sent. Claude Code folds its lines into one.
    public func isRequest(_ prompt: String) -> Bool {
        guard let sent = self.prompt, !sent.isEmpty else { return false }
        return prompt.hasPrefix(sent)
    }

    /// `checkout` is `<reviews>/<review>/<repository>`; the file sits in `<review>`.
    static func read(checkout: String) -> ReviewCheckout {
        let url = URL(fileURLWithPath: checkout).deletingLastPathComponent().appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return ReviewCheckout() }
        return (try? JSONDecoder().decode(ReviewCheckout.self, from: data)) ?? ReviewCheckout()
    }

    func write(beside checkout: URL) throws {
        let url = checkout.deletingLastPathComponent().appendingPathComponent(Self.fileName)
        try JSONEncoder().encode(self).write(to: url)
    }
}

import Foundation
import Testing
@testable import BellCore

struct ReviewTests {
    @Test func recognizesAChatMessageWithMarkdownAndMentions() throws {
        let link = "https://gitlab.example.org/platform/team/demo/robot/-/merge_requests/718"
        let request = try ReviewRequest.parse("[\(link)](\(link)) @队友一 @队友二 [看]")
        let project = ReviewProject(remote: "git@gitlab.example.org:platform/team/demo/robot.git")
        #expect(request == .mergeRequest(project: project, iid: 718))
        #expect(try ReviewRequest.parse("!718") == .mergeRequest(project: nil, iid: 718))
        #expect(try ReviewRequest.parse("feat/retry") == .branch("feat/retry"))
        #expect(throws: ReviewFailure.self) {
            try ReviewRequest.parse("\(link) https://gitlab.example.org/platform/team/demo/robot/-/merge_requests/719")
        }
    }

    @Test func preparesAndReviewsAnMRWithoutTouchingTheUsersCheckout() async throws {
        let gitPath = try #require(GitSnapshot.gitCandidates.first(where: FileManager.default.isExecutableFile(atPath:)))
        let git = URL(fileURLWithPath: gitPath)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let remote = root.appendingPathComponent("remote.git")
        let repo = root.appendingPathComponent("clone")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func command(_ args: [String], in folder: URL? = nil) async throws -> String {
            let output = try await ProcessRunner.run(git, arguments: args, currentDirectory: folder)
            try #require(output.exitCode == 0, "\(output.standardError)")
            return String(decoding: output.standardOutput, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        _ = try await command(["init", "--bare", remote.path])
        _ = try await command(["init", "-b", "main", repo.path])
        _ = try await command(["config", "user.email", "review@example.test"], in: repo)
        _ = try await command(["config", "user.name", "Review Test"], in: repo)
        _ = try await command(["config", "commit.gpgsign", "false"], in: repo)
        let code = repo.appendingPathComponent("app.txt")
        try Data("initial\n".utf8).write(to: code)
        _ = try await command(["add", "app.txt"], in: repo)
        _ = try await command(["commit", "-m", "base"], in: repo)
        _ = try await command(["switch", "-c", "feat/retry"], in: repo)
        try Data("review-marker\n".utf8).write(to: code)
        _ = try await command(["commit", "-am", "feature"], in: repo)
        let head = try await command(["rev-parse", "HEAD"], in: repo)
        _ = try await command(["switch", "main"], in: repo)
        try Data("target change\n".utf8).write(to: repo.appendingPathComponent("other.txt"))
        _ = try await command(["add", "other.txt"], in: repo)
        _ = try await command(["commit", "-m", "advanced target"], in: repo)
        let origin = "https://gitlab.example.org/platform/team/robot.git"
        _ = try await command(["remote", "add", "origin", origin], in: repo)
        _ = try await command(["config", "url.\(remote.path).insteadOf", origin], in: repo)
        _ = try await command(["push", "origin", "main", "feat/retry", "feat/retry:refs/merge-requests/718/head"], in: repo)
        try Data("local edits\n".utf8).write(to: code)
        let original = try await command(["worktree", "list", "--porcelain"], in: repo)

        let glab = root.appendingPathComponent("glab")
        try executable("""
        #!/bin/sh
        [ "$1" = api ] && [ "$2" = --hostname ] && [ "$3" = gitlab.example.org ] &&
          [ "$4" = 'projects/platform%2Fteam%2Frobot/merge_requests/718' ] || exit 10
        printf '%s' '{"source_branch":"feat/retry","target_branch":"main","sha":"\(head)"}'
        """, at: glab)
        let link = "https://gitlab.example.org/platform/team/robot/-/merge_requests/718"
        let request = try ReviewRequest.parse("[\(link)](\(link)) @队友 [看]")
        let other = root.appendingPathComponent("other")
        let duplicate = root.appendingPathComponent("duplicate")
        _ = try await command(["init", other.path])
        _ = try await command(["init", duplicate.path])
        _ = try await command(["remote", "add", "origin", "git@gitlab.example.org:platform/team/elsewhere.git"], in: other)
        _ = try await command(["remote", "add", "origin", "git@gitlab.example.org:platform/team/robot.git"], in: duplicate)

        let canonicalRepo = repo.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalOther = other.standardizedFileURL.resolvingSymlinksInPath()
        let canonicalDuplicate = duplicate.standardizedFileURL.resolvingSymlinksInPath()
        #expect(try await ReviewRunner.chooseRepository(for: request, preferred: other, candidates: [repo]) == .use(canonicalRepo))
        #expect(try await ReviewRunner.chooseRepository(for: request, preferred: nil, candidates: [other]) == .choose([]))
        #expect(try await ReviewRunner.chooseRepository(for: request, preferred: nil, candidates: [repo, duplicate])
                == .choose([canonicalRepo, canonicalDuplicate]))
        #expect(try await ReviewRunner.chooseRepository(for: request, preferred: repo, candidates: [duplicate])
                == .use(canonicalRepo))
        #expect(try await ReviewRunner.chooseRepository(for: .mergeRequest(project: nil, iid: 718), preferred: other, candidates: [repo])
                == .use(canonicalOther))

        let plan = try await ReviewRunner.prepare(request, directory: repo, base: "ignored", glab: glab)
        #expect(plan.head == head)
        #expect(plan.targetBranch == "main")
        #expect(plan.behind == 1)
        let branchPlan = try await ReviewRunner.prepare(.branch("feat/retry"), directory: repo, base: "main", glab: nil)
        #expect(branchPlan.head == plan.head)
        #expect(branchPlan.diff == plan.diff)

        let claude = root.appendingPathComponent("claude")
        try executable("""
        #!/bin/sh
        [ "$(git rev-parse HEAD)" = '\(head)' ] && [ "$(cat app.txt)" = review-marker ] || exit 11
        input=$(cat)
        printf '%s' "$input" | grep -q '关注：测试重试' || exit 12
        printf '%s' "$input" | grep -q '^+review-marker' || exit 13
        printf '%s' "$input" | grep -q 'local edits' && exit 14
        printf '%s' '{"is_error":false,"result":"P1 审查结果"}'
        """, at: claude)
        let output = try await ReviewRunner.run(plan, claude: claude, template: "关注：{{focus}}", focus: "测试重试")
        #expect(output.contains(link) && output.contains(head) && output.contains("P1 审查结果"))
        #expect(try await command(["worktree", "list", "--porcelain"], in: repo) == original)
        #expect(try await command(["for-each-ref", "refs/agentbell/review"], in: repo).isEmpty)
        #expect(try String(contentsOf: code, encoding: .utf8) == "local edits\n")
    }

    private func executable(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

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
        case " $* " in *" --permission-mode dontAsk "*" --tools Read,Grep,Glob "*" --model opus "*) ;; *) exit 15 ;; esac
        input=$(cat)
        printf '%s' "$input" | grep -q '关注：测试重试' || exit 12
        printf '%s' "$input" | grep -q '^+review-marker' || exit 13
        printf '%s' "$input" | grep -q 'local edits' && exit 14
        printf '%s' "$input" | grep -q ' feature$' || exit 16
        printf '%s' '{"is_error":false,"result":"P1 审查结果","session_id":"review-session"}'
        """, at: claude)
        let reviews = root.appendingPathComponent("reviews")
        let outcome = try await ReviewRunner.run(
            plan, claude: claude, template: "关注：{{focus}}", focus: "测试重试", model: .opus, root: reviews
        )
        #expect(outcome.report.contains(link) && outcome.report.contains(head) && outcome.report.contains("P1 审查结果"))
        #expect(outcome.report.contains("- 模型 Opus"))
        #expect(outcome.sessionID == "review-session")
        // Kept for `claude --resume`, named after the repository, and only the input is gone.
        #expect(outcome.checkout.lastPathComponent == "clone")
        #expect(try await command(["rev-parse", "HEAD"], in: outcome.checkout) == head)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outcome.checkout.deletingLastPathComponent().path).sorted()
            == ["clone", "review.json"])
        // A session resumed there says what it reviews.
        let resumed = ProjectInfo.lookup(cwd: outcome.checkout.path, reviews: reviews.path)
        #expect(resumed.review == ReviewCheckout(sourceBranch: plan.sourceBranch, targetBranch: plan.targetBranch,
                                                 prompt: "关注：测试重试"))
        #expect(try await command(["for-each-ref", "refs/agentbell/review"], in: repo).isEmpty)
        #expect(try String(contentsOf: code, encoding: .utf8) == "local edits\n")

        await ReviewRunner.pruneCheckouts(git, repo, root: reviews)
        #expect(FileManager.default.fileExists(atPath: outcome.checkout.path))
        await ReviewRunner.pruneCheckouts(git, repo, root: reviews, now: Date().addingTimeInterval(4 * 24 * 3600))
        #expect(!FileManager.default.fileExists(atPath: outcome.checkout.deletingLastPathComponent().path))
        #expect(try await command(["worktree", "list", "--porcelain"], in: repo) == original)

        // Saved reports outlive their checkout and are listed newest first.
        let archive = ReviewArchive(root: root.appendingPathComponent("reports"))
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let older = try archive.save(ReviewRecord(id: "a", plan: plan, outcome: outcome, model: .opus, focus: "测试重试",
                                                  startedAt: start, finishedAt: start), report: outcome.report)
        let newer = try archive.save(ReviewRecord(id: "b", plan: plan, outcome: outcome, model: .fable, focus: "",
                                                  startedAt: start, finishedAt: start), report: "second")
        #expect(older.folder != newer.folder)
        #expect(older.folder.lastPathComponent.hasSuffix("clone feat-retry"))
        let loaded = archive.load()
        #expect(loaded.map(\.id).sorted() == ["a", "b"])
        let first = try #require(loaded.first { $0.id == "a" })
        #expect(first.folder.resolvingSymlinksInPath() == older.folder.resolvingSymlinksInPath())
        #expect(first.model == .opus && first.sessionID == "review-session" && first.finishedAt == start)
        #expect(first.checkout == outcome.checkout.path && first.range == "feat/retry → main")
        #expect(archive.report(first) == outcome.report)
        try archive.delete(first)
        #expect(archive.load().map(\.id) == ["b"])
    }

    @Test func modelsMatchClaudeCodesChoices() {
        #expect(ReviewModel.recommended.arguments.isEmpty)
        #expect(ReviewModel.fable.arguments == ["--model", "fable"])
        #expect(ReviewModel.opus.arguments == ["--model", "opus"])
    }

    @Test func cancellingStopsTheChildProcess() async throws {
        let started = Date()
        let task = Task {
            try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 60)
        }
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    private func executable(_ text: String, at url: URL) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

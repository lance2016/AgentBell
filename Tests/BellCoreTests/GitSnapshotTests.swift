import Foundation
import Testing
@testable import BellCore

struct GitSnapshotTests {
    @Test func readsBranchUpstreamAndChanges() throws {
        let status = """
        # branch.oid 0123456789abcdef
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 aaa bbb Sources/App.swift
        1 A. N... 000000 100644 100644 000 ccc docs/new file.md
        1 D. N... 100644 000000 000000 ddd 000 old.txt
        2 R. N... 100644 100644 100644 eee fff R100 renamed.swift\tbefore.swift
        u UU N... 100644 100644 100644 100644 a b c conflict.swift
        ? 草稿.md

        """
        let numstat = "3\t1\tSources/App.swift\n10\t0\tdocs/new file.md\n-\t-\tlogo.png\n"
        let log = "fix: keep rows still\u{1F}1700000000\n"

        let snapshot = try #require(GitSnapshot.parse(status: status, numstat: numstat, log: log))

        #expect(snapshot.branch == "main")
        #expect(snapshot.upstream == "origin/main")
        #expect(snapshot.ahead == 2)
        #expect(snapshot.behind == 1)
        #expect(snapshot.changes == [
            .init(path: "Sources/App.swift", kind: .modified, added: 3, deleted: 1),
            .init(path: "docs/new file.md", kind: .added, added: 10, deleted: 0),
            .init(path: "old.txt", kind: .deleted),
            .init(path: "renamed.swift", kind: .renamed),
            .init(path: "conflict.swift", kind: .conflicted),
            .init(path: "草稿.md", kind: .untracked),
        ])
        #expect(snapshot.lastCommit == .init(subject: "fix: keep rows still", date: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    @Test func detachedHeadWithoutUpstreamOrCommits() throws {
        let status = "# branch.oid (initial)\n# branch.head (detached)\n"
        let snapshot = try #require(GitSnapshot.parse(status: status, numstat: "", log: ""))
        #expect(snapshot.branch == nil)
        #expect(snapshot.upstream == nil)
        #expect(snapshot.ahead == 0 && snapshot.behind == 0)
        #expect(snapshot.changes.isEmpty)
        #expect(snapshot.lastCommit == nil)
    }

    @Test func outputWithoutBranchHeaderIsNotARepository() {
        #expect(GitSnapshot.parse(status: "", numstat: "", log: "") == nil)
    }
}

import Foundation
import Testing
@testable import BellCore

struct ProjectInfoTests {
    /// A throwaway directory tree; removed when the test ends.
    final class Sandbox {
        let root: String

        init() throws {
            root = (NSTemporaryDirectory() as NSString)
                .appendingPathComponent("bell-\(UUID().uuidString)")
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        }

        func write(_ relative: String, _ text: String) throws {
            let path = (root as NSString).appendingPathComponent(relative)
            try FileManager.default.createDirectory(
                atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }

        func mkdir(_ relative: String) throws {
            try FileManager.default.createDirectory(
                atPath: (root as NSString).appendingPathComponent(relative), withIntermediateDirectories: true)
        }

        func path(_ relative: String) -> String {
            ((root as NSString).appendingPathComponent(relative) as NSString).standardizingPath
        }

        deinit { try? FileManager.default.removeItem(atPath: root) }
    }

    @Test func findsRepositoryRootFromSubdirectory() throws {
        let box = try Sandbox()
        try box.write("app/.git/HEAD", "ref: refs/heads/feat/pid-tune\n")
        try box.mkdir("app/src/deep")
        let info = ProjectInfo.lookup(cwd: box.path("app/src/deep"))
        #expect(info.root == box.path("app"))
        #expect(info.name == "app")
        #expect(info.branch == "feat/pid-tune")
    }

    @Test func worktreeGroupsUnderMainRepository() throws {
        let box = try Sandbox()
        try box.write("main/.git/HEAD", "ref: refs/heads/main\n")
        try box.write("main/.git/worktrees/wt/HEAD", "ref: refs/heads/fix\n")
        try box.write("wt/.git", "gitdir: \(box.path("main/.git/worktrees/wt"))\n")
        let info = ProjectInfo.lookup(cwd: box.path("wt"))
        #expect(info.root == box.path("main"))
        #expect(info.branch == "fix")
    }

    @Test func ignoresRepositoryInHomeFolder() throws {
        let box = try Sandbox()
        try box.write(".git/HEAD", "ref: refs/heads/main\n")
        try box.mkdir("work/tool")
        let info = ProjectInfo.lookup(cwd: box.path("work/tool"), home: box.root)
        #expect(info.root == box.path("work/tool"))
        #expect(info.name == "tool")
        #expect(info.branch == nil)
    }

    @Test func detachedHeadShowsShortHash() throws {
        let box = try Sandbox()
        try box.write("app/.git/HEAD", "0123456789abcdef0123456789abcdef01234567\n")
        #expect(ProjectInfo.lookup(cwd: box.path("app")).branch == "0123456")
    }

    @Test func outsideRepositoryUsesCwd() throws {
        let box = try Sandbox()
        try box.mkdir("plain")
        // The sandbox lives under the system temp dir, which is not a repository.
        let info = ProjectInfo.lookup(cwd: box.path("plain"))
        #expect(info.root == box.path("plain"))
        #expect(info.branch == nil)
    }
}

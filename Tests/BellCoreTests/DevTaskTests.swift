import Foundation
import Testing
@testable import BellCore

struct DevTaskTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String, cwd: String, root: String, branch: String?) -> Session {
        Session(id: id, pid: 1, cwd: cwd, project: ProjectInfo(root: root, branch: branch),
                startedAt: now, state: .idle, stateSince: now)
    }

    private var web: Session {
        session("web-1", cwd: "/work/robot-web-share", root: "/work/robot-web", branch: "feat/photo-share-ui")
    }

    private var api: Session {
        session("api-1", cwd: "/work/robot-api-share", root: "/work/robot-api", branch: "feat/photo-share-api")
    }

    @Test func workspaceTakesProjectDirectoryBranchAndSession() {
        let workspace = TaskWorkspace(session: web, at: now)
        #expect(workspace.projectName == "robot-web")
        #expect(workspace.cwd == "/work/robot-web-share")
        #expect(workspace.branch == "feat/photo-share-ui")
        #expect(workspace.sessionID == "web-1")
        #expect(workspace.resumeCommand == "cd '/work/robot-web-share' && claude --resume web-1")
    }

    @Test func resumeCommandQuotesDirectoryAndUnsafeID() {
        let odd = session("a b", cwd: "/work/it's here", root: "/work/x", branch: nil)
        #expect(TaskWorkspace(session: odd, at: now).resumeCommand
            == #"cd '/work/it'\''s here' && claude --resume 'a b'"#)
        // The session's own command is unchanged by sharing the code.
        #expect(odd.resumeInDirectoryCommand == TaskWorkspace(session: odd, at: now).resumeCommand)
    }

    @Test func oneTaskHoldsSeveralWorkspaces() {
        let task = DevTask(title: "照片分享", createdAt: now)
            .linking(TaskWorkspace(session: web, at: now))
            .linking(TaskWorkspace(session: api, at: now))
        #expect(task.workspaces.map(\.projectName) == ["robot-web", "robot-api"])
        #expect(task.contains(sessionID: "api-1"))
        #expect(!task.contains(sessionID: "other"))
    }

    @Test func linkingAgainInSameDirectoryReplacesTheOlderSession() {
        let later = session("web-2", cwd: web.cwd, root: web.project.root, branch: "feat/photo-share-ui-2")
        let task = DevTask(title: "照片分享", createdAt: now)
            .linking(TaskWorkspace(session: web, at: now))
            .linking(TaskWorkspace(session: api, at: now))
            .linking(TaskWorkspace(session: later, at: now.addingTimeInterval(60)))
        #expect(task.workspaces.count == 2)
        #expect(task.workspaces[0].sessionID == "web-2")
        #expect(task.workspaces[0].branch == "feat/photo-share-ui-2")
    }

    @Test func linkingLeavesTheOriginalUntouched() {
        let original = DevTask(title: "照片分享", createdAt: now)
        _ = original.linking(TaskWorkspace(session: web, at: now))
        #expect(original.workspaces.isEmpty)
    }

    @Test func unlinkingRemovesOneWorkspace() {
        let task = DevTask(title: "照片分享", createdAt: now)
            .linking(TaskWorkspace(session: web, at: now))
            .linking(TaskWorkspace(session: api, at: now))
            .unlinking(workspace: web.cwd)
        #expect(task.workspaces.map(\.sessionID) == ["api-1"])
    }

    @Test func searchMatchesTitleProjectAndBranch() {
        let task = DevTask(title: "照片分享", nextStep: "前端还差失败提示", createdAt: now)
            .linking(TaskWorkspace(session: web, at: now))
        #expect(task.matches("照片"))
        #expect(task.matches("ROBOT-WEB"))
        #expect(task.matches("photo-share-ui"))
        #expect(task.matches("  "))
        #expect(!task.matches("robot-api"))
        // The next step is read on the detail, not searched.
        #expect(!task.matches("失败提示"))
    }

    @Test func listOrderPutsWorkInProgressFirstAndDoneLast() {
        let done = DevTask(title: "done", status: .done, createdAt: now.addingTimeInterval(30))
        let oldTodo = DevTask(title: "old todo", createdAt: now)
        let newTodo = DevTask(title: "new todo", createdAt: now.addingTimeInterval(20))
        let doing = DevTask(title: "doing", status: .inProgress, createdAt: now.addingTimeInterval(-100))
        #expect(DevTask.listOrder([done, oldTodo, newTodo, doing]).map(\.title)
            == ["doing", "new todo", "old todo", "done"])
    }

    @Test func savedTasksComeBack() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("bell-tasks-\(UUID().uuidString)/tasks.json")
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let task = DevTask(title: "照片分享", note: "说明", nextStep: "后端接口已通，前端还差失败提示",
                           status: .inProgress, createdAt: now)
            .linking(TaskWorkspace(session: web, at: now))
            .linking(TaskWorkspace(session: api, at: now))
        try SavedState.save([task], to: file)
        #expect(try TaskFile.load(from: file) == [task])
    }

    @Test func missingFileMeansNoTasks() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bell-none-\(UUID().uuidString).json")
        #expect(try TaskFile.load(from: file).isEmpty)
    }

    @Test func unreadableFileIsSetAsideNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("bell-broken-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("tasks.json")
        try Data("not json".utf8).write(to: file)

        #expect(throws: (any Error).self) { try TaskFile.load(from: file) }
        let kept = try TaskFile.setAside(file, at: now)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(try Data(contentsOf: kept) == Data("not json".utf8))
        #expect(kept.lastPathComponent.hasPrefix("tasks.json.unreadable-"))
    }
}

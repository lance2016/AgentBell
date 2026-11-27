import Foundation
import Testing
@testable import BellCore

struct SessionStopperTests {
    let started = Date(timeIntervalSince1970: 1_000_000)

    @Test func onlyThatSessionsOwnClaudeMatches() {
        #expect(SessionStopper.matches(name: "claude", started: started + 2, sessionStarted: started))
        // npm installs run Claude Code under node.
        #expect(SessionStopper.matches(name: "node", started: started - 3, sessionStarted: started))
        // The native installer runs ~/.local/share/claude/versions/<version>, so the
        // kernel names the process after its version.
        #expect(SessionStopper.matches(name: "2.1.332", started: started, sessionStarted: started))
        #expect(!SessionStopper.matches(name: "2.1.", started: started, sessionStarted: started))
        // The pid was reused by something else, or by a later process.
        #expect(!SessionStopper.matches(name: "zsh", started: started, sessionStarted: started))
        #expect(!SessionStopper.matches(name: "claude", started: started + 3600, sessionStarted: started))
    }

    /// A stand-in `claude`: a tiny program built under that name, so the kernel names it
    /// so. A copied `/bin/sleep` is killed on launch, and a link or script runs under
    /// the target's or the interpreter's name.
    private func launchStandIn() throws -> (Process, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("stopper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("claude.c")
        let binary = folder.appendingPathComponent("claude")
        try "#include <unistd.h>\nint main(int c, char **v) { sleep(30); return 0; }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
        compiler.arguments = ["-o", binary.path, source.path]
        try compiler.run()
        compiler.waitUntilExit()
        try #require(compiler.terminationStatus == 0)
        let process = Process()
        process.executableURL = binary
        process.arguments = ["30"]
        try process.run()
        return (process, folder)
    }

    private func session(pid: Int32, startedAt: Date) -> Session {
        Session(id: "s", pid: pid, cwd: "/p", project: ProjectInfo(root: "/p", branch: nil),
                startedAt: startedAt, state: .working, stateSince: startedAt)
    }

    @Test func stopsTheSessionsProcess() async throws {
        let (process, folder) = try launchStandIn()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(SessionStopper.stop(session(pid: process.processIdentifier, startedAt: Date())))
        process.waitUntilExit()
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGTERM)
    }

    @Test func leavesAProcessThatIsNotTheSessions() async throws {
        let (process, folder) = try launchStandIn()
        defer {
            process.terminate()
            try? FileManager.default.removeItem(at: folder)
        }
        let stale = session(pid: process.processIdentifier, startedAt: Date().addingTimeInterval(-3600))
        #expect(!SessionStopper.stop(stale))
        #expect(process.isRunning)
    }

    @Test func endedSessionIsLeftAlone() {
        var ended = session(pid: getpid(), startedAt: Date())
        ended.endedAt = Date()
        #expect(!SessionStopper.stop(ended))
    }
}

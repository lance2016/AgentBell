import Foundation
import Testing
@testable import BellCore

struct HookSettingsTests {
    let command = HookSettings.command(for: URL(fileURLWithPath: "/Users/me/Library/Application Support/AgentBell/bin/agent-bell-hook"))

    let usersOwn = """
    {
      "model": "opus",
      "hooks": {
        "Stop": [
          {
            "hooks": [
              {
                "type": "command",
                "command": "other-stop"
              }
            ]
          }
        ],
        "PreToolUse": [
          {
            "matcher": "Bash",
            "hooks": [
              {
                "type": "command",
                "command": "other-pre",
                "timeout": 5
              }
            ]
          }
        ]
      },
      "theme": "dark"
    }
    """

    @Test func printsExactlyWhatItParsed() throws {
        let text = "{\n  \"a\": [],\n  \"b\": {},\n  \"c\": \"中文 \\\"引号\\\" \\n\",\n  \"d\": 1.50,\n  \"e\": null\n}"
        #expect(try OrderedJSON.parse(text).printed() == text)
    }

    @Test func parsesEscapesAndRejectsJunk() throws {
        #expect(try OrderedJSON.parse("\"\\u00e9\\ud83d\\ude00\"") == .string("é😀"))
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse("{\"a\": 1,}") }
        #expect(throws: OrderedJSON.ParseError.self) { try OrderedJSON.parse("{} extra") }
    }

    @Test func commandIsQuotedForTheShell() {
        let path = URL(fileURLWithPath: "/tmp/it's here/agent-bell-hook")
        #expect(HookSettings.command(for: path) == #"[ -x '/tmp/it'\''s here/agent-bell-hook' ] && '/tmp/it'\''s here/agent-bell-hook' || true"#)
    }

    @Test func addsOneAsyncHookPerEventAfterTheUsersOwn() throws {
        let settings = try HookSettings.addingOurs(to: OrderedJSON.parse(usersOwn), command: command)
        let stop = settings["hooks"]?["Stop"]?.arrayValue
        #expect(stop?.count == 2)
        #expect(stop?[0]["hooks"]?.arrayValue?[0]["command"] == .string("other-stop"))
        #expect(stop?[1]["hooks"]?.arrayValue?[0]["command"] == .string(command))
        #expect(stop?[1]["hooks"]?.arrayValue?[0]["async"] == .bool(true))
        #expect(settings["hooks"]?["Notification"]?.arrayValue?[0]["matcher"] == .string("permission_prompt|elicitation_dialog"))
        #expect(settings.objectValue?.map(\.key) == ["model", "hooks", "theme"])
        #expect(try HookSettings.connection(in: settings, command: command) == .connected)
    }

    @Test func disconnectingGivesBackTheSameText() throws {
        let connected = try HookSettings.addingOurs(to: OrderedJSON.parse(usersOwn), command: command)
        #expect(try HookSettings.removingOurs(from: connected).printed() == usersOwn)
    }

    @Test func noHooksBeforeMeansNoHooksAfter() throws {
        let plain = "{\n  \"model\": \"opus\"\n}"
        let connected = try HookSettings.addingOurs(to: OrderedJSON.parse(plain), command: command)
        #expect(try HookSettings.removingOurs(from: connected).printed() == plain)
    }

    @Test func connectingTwiceOrFromElsewhereLeavesOneEach() throws {
        let old = HookSettings.command(for: URL(fileURLWithPath: "/old/agent-bell-hook"))
        let first = try HookSettings.addingOurs(to: OrderedJSON.parse(usersOwn), command: old)
        #expect(try HookSettings.connection(in: first, command: command) == .stale)
        let second = try HookSettings.addingOurs(to: first, command: command)
        #expect(second["hooks"]?["Stop"]?.arrayValue?.count == 2)
        #expect(try HookSettings.connection(in: second, command: command) == .connected)
    }

    @Test func keepsAUsersHookSharingAGroupWithOurs() throws {
        let shared = try OrderedJSON.parse(#"{"hooks": {"Stop": [{"hooks": [{"command": "mine"}, {"command": "x/agent-bell-hook"}]}]}}"#)
        let cleaned = try HookSettings.removingOurs(from: shared)
        #expect(cleaned["hooks"]?["Stop"]?.arrayValue?[0]["hooks"]?.arrayValue == [.object([("command", .string("mine"))])])
    }

    @Test func refusesSettingsItDoesNotUnderstand() throws {
        #expect(throws: HookSettingsError.unexpectedHooksShape) {
            try HookSettings.addingOurs(to: OrderedJSON.parse(#"{"hooks": []}"#), command: command)
        }
        #expect(throws: HookSettingsError.invalidJSON) {
            try HookSettings.addingOurs(to: OrderedJSON.parse("[]"), command: command)
        }
    }

    // MARK: - Files

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("bell-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func connectAndDisconnectARealSettingsFile() throws {
        // DESIGN.md §3.8 acceptance: the user's own settings.json, connected and
        // disconnected, comes back byte for byte. Run on a copy, never the original.
        let real = BellPaths.claudeSettings
        guard FileManager.default.fileExists(atPath: real.path) else { return }
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let copy = dir.appendingPathComponent("settings.json")
        try FileManager.default.copyItem(at: real, to: copy)
        // The real file may already be connected; start from how it was before.
        try HookSettings.disconnect(at: copy)
        let original = try Data(contentsOf: copy)

        try HookSettings.connect(at: copy, command: command)
        #expect(try HookSettings.connection(at: copy, command: command) == .connected)
        try HookSettings.disconnect(at: copy)
        #expect(try Data(contentsOf: copy) == original)
    }

    @Test func backsUpOnceAndKeepsPermissions() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try usersOwn.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)

        try HookSettings.connect(at: file, command: command)
        try HookSettings.disconnect(at: file)
        try HookSettings.connect(at: file, command: command)

        let backup = dir.appendingPathComponent("settings.json.agent-bell-backup")
        #expect(try String(contentsOf: backup, encoding: .utf8) == usersOwn)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o640)
    }

    @Test func writesThroughALink() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("dotfiles-settings.json")
        let link = dir.appendingPathComponent("settings.json")
        try usersOwn.write(to: real, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        try HookSettings.connect(at: link, command: command)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == real.path)
        #expect(try HookSettings.connection(at: real, command: command) == .connected)
    }

    @Test func createsAMissingFilePrivately() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try HookSettings.connect(at: file, command: command)
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        #expect(try HookSettings.connection(at: file, command: command) == .connected)
    }

    @Test func leavesAnInvalidFileAlone() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("settings.json")
        try "{ not json".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: HookSettingsError.invalidJSON) { try HookSettings.connect(at: file, command: command) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json")
    }
}

struct HookEventTests {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    func parse(_ json: String) -> HookEvent? {
        HookEvent.from(hookInput: Data(json.utf8), now: now)
    }

    @Test func keepsOnlyShortLines() {
        let prompt = parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"abc-1","prompt":"<pasted_content id=\"1\">\n\n## 修复按钮\n第二行"}"#)
        #expect(prompt?.prompt == "修复按钮")
        #expect(prompt?.at == 1_700_000_000_000)

        let edit = parse(#"{"hook_event_name":"PermissionRequest","session_id":"abc-1","tool_name":"Edit","tool_input":{"file_path":"/Users/me/secret/App.tsx","old_string":"code"}}"#)
        #expect(edit?.tool == "Edit")
        #expect(edit?.detail == "App.tsx")

        let bash = parse(#"{"hook_event_name":"PreToolUse","session_id":"abc-1","tool_name":"Bash","tool_input":{"command":"rm -rf build","description":"清理构建目录"}}"#)
        #expect(bash?.detail == "清理构建目录")
        let line = String(decoding: bash?.line() ?? Data(), as: UTF8.self)
        #expect(!line.contains("rm -rf"))
    }

    @Test func stopAndFailure() {
        let stop = parse(#"{"hook_event_name":"Stop","session_id":"abc-1","last_assistant_message":"**完成了**。\n细节","background_tasks":[{"id":1}]}"#)
        #expect(stop?.reply == "完成了")
        #expect(stop?.background == true)
        let quiet = parse(#"{"hook_event_name":"Stop","session_id":"abc-1","background_tasks":[]}"#)
        #expect(quiet?.background == nil)
        #expect(parse(#"{"hook_event_name":"StopFailure","session_id":"abc-1","error":"rate_limit"}"#)?.error == "rate_limit")
        #expect(parse(#"{"hook_event_name":"StopFailure","session_id":"abc-1","error":{"type":"server_error"}}"#)?.error == "server_error")
    }

    @Test func wakeUpAndSubagent() {
        let woke = parse(#"{"hook_event_name":"UserPromptSubmit","session_id":"abc-1","prompt":"<task-notification>done</task-notification>"}"#)
        #expect(woke?.woke == true)
        #expect(woke?.prompt == nil)
        #expect(parse(#"{"hook_event_name":"PreToolUse","session_id":"abc-1","tool_name":"Read","agent_id":"x"}"#)?.subagent == true)
    }

    @Test func refusesWhatItDoesNotFollow() {
        #expect(parse(#"{"hook_event_name":"PreCompact","session_id":"abc-1"}"#) == nil)
        #expect(parse(#"{"hook_event_name":"Stop","session_id":"../../etc"}"#) == nil)
        #expect(parse("not json") == nil)
    }

    @Test func lineRoundTripsAndJunkIsDropped() throws {
        let event = HookEvent(event: "Stop", session: "abc-1", at: 5, reply: "好")
        let line = try #require(event.line())
        #expect(HookEvent.decode(line: line.dropLast()) == event)
        #expect(HookEvent.decode(line: Data("{}".utf8)) == nil)
        #expect(HookEvent.decode(line: Data(repeating: 0x20, count: 9000)) == nil)
    }
}

struct HookSocketTests {
    @Test func deliversALine() async throws {
        // Short path: sockaddr_un holds about 100 bytes.
        let dir = URL(fileURLWithPath: "/tmp/bell-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sock")
        let received = AsyncStream<HookEvent>.makeStream()
        let server = HookServer(path: path) { received.continuation.yield($0) }
        try server.start()
        defer { server.stop() }

        let event = HookEvent(event: "UserPromptSubmit", session: "abc-1", at: 1, prompt: "你好")
        HookSocket.send(try #require(event.line()), to: path)
        var iterator = received.stream.makeAsyncIterator()
        #expect(await iterator.next() == event)

        let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o700)
    }

    @Test func sendingWithNoAppRunningDoesNothing() {
        HookSocket.send(Data("x\n".utf8), to: URL(fileURLWithPath: "/tmp/no-such-bell.sock"))
    }

    @Test func leavesARunningCopysSocketAlone() async throws {
        let dir = URL(fileURLWithPath: "/tmp/bell-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sock")
        let received = AsyncStream<HookEvent>.makeStream()
        let first = HookServer(path: path) { received.continuation.yield($0) }
        try first.start()
        defer { first.stop() }

        let second = HookServer(path: path) { _ in Issue.record("the second copy must not hear events") }
        #expect(throws: HookServer.StartError.inUse) { try second.start() }

        let event = HookEvent(event: "Stop", session: "abc-1", at: 1)
        HookSocket.send(try #require(event.line()), to: path)
        var iterator = received.stream.makeAsyncIterator()
        #expect(await iterator.next() == event)
    }

    @Test func replacesASocketLeftByACrash() async throws {
        let dir = URL(fileURLWithPath: "/tmp/bell-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("s.sock")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Bound and closed without unlinking: the file stays, nobody listens.
        var address = try #require(HookSocket.address(for: path))
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        close(fd)
        #expect(bound == 0)

        let received = AsyncStream<HookEvent>.makeStream()
        let server = HookServer(path: path) { received.continuation.yield($0) }
        try server.start()
        defer { server.stop() }
        let event = HookEvent(event: "Stop", session: "abc-1", at: 1)
        HookSocket.send(try #require(event.line()), to: path)
        var iterator = received.stream.makeAsyncIterator()
        #expect(await iterator.next() == event)
    }
}

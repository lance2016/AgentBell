import Foundation

public enum ClaudeCLIError: Error, Sendable, Equatable {
    case commandFailed(exitCode: Int32, message: String)
    case unreadableOutput
}

/// Finds the `claude` executable and lists sessions with `claude agents --json`.
public enum ClaudeCLI {
    /// Where we look, in order, before asking the login shell. A GUI app launched from
    /// Finder does not inherit the shell's PATH, so no single location can be assumed.
    public static func candidatePaths(home: String) -> [String] {
        [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.bun/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
    }

    /// Returns the first executable `claude`. `override` is a path the user picked by hand
    /// and is the only place looked at when given.
    public static func locate(override: String? = nil) async -> URL? {
        let fileManager = FileManager.default
        if let override {
            return fileManager.isExecutableFile(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        if let path = candidatePaths(home: home).first(where: fileManager.isExecutableFile(atPath:)) {
            return URL(fileURLWithPath: path)
        }
        return await locateViaLoginShell()
    }

    /// `$SHELL -lc 'command -v claude'`. The command text is constant.
    private static func locateViaLoginShell() async -> URL? {
        guard let shell = ProcessInfo.processInfo.environment["SHELL"],
              let output = try? await ProcessRunner.run(
                  URL(fileURLWithPath: shell),
                  arguments: ["-lc", "command -v claude"],
                  timeout: 5
              )
        else { return nil }
        let path = String(decoding: output.standardOutput, as: UTF8.self)
            .split(separator: "\n").last
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    public static func listAgents(executable: URL) async throws -> [AgentRecord] {
        try await snapshot(executable: executable).records
    }

    public static func snapshot(executable: URL) async throws -> AgentRecord.Snapshot {
        let output = try await ProcessRunner.run(
            executable,
            arguments: ["agents", "--json"],
            environment: environment(for: executable),
            timeout: 10
        )
        guard output.exitCode == 0 else {
            let firstLine = output.standardError.split(separator: "\n").first.map(String.init) ?? ""
            throw ClaudeCLIError.commandFailed(exitCode: output.exitCode, message: firstLine)
        }
        do {
            return try AgentRecord.parseSnapshot(output.standardOutput)
        } catch {
            throw ClaudeCLIError.unreadableOutput
        }
    }

    /// An npm-installed `claude` is a node script, so `node` must be on PATH. It usually
    /// sits next to `claude` (nvm) or in a Homebrew prefix.
    static func environment(for executable: URL) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let directory = executable.deletingLastPathComponent().path
        env["PATH"] = [directory, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
            .joined(separator: ":")
        return env
    }
}

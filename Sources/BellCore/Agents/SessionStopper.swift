import Darwin
import Foundation

/// Ends an open session the way closing its terminal tab would: SIGTERM to its `claude`
/// process. The conversation is kept, and `claude --resume` brings it back.
///
/// `claude stop` only stops background sessions, so there is no command to ask instead.
public enum SessionStopper {
    /// `claude agents` and the kernel agree on a start time within a few seconds.
    static let startTolerance: TimeInterval = 10

    /// Returns false, sending nothing, unless the pid is still this session's own
    /// `claude`: pids are reused, and a stale one must never end someone else's process.
    public static func stop(_ session: Session) -> Bool {
        guard !session.isEnded,
              let process = ProcessInspector.identity(of: session.pid),
              matches(name: process.name, started: process.started, sessionStarted: session.startedAt)
        else { return false }
        return kill(session.pid, SIGTERM) == 0
    }

    /// Claude Code runs as `claude`, as `node` when installed with npm, or under its
    /// version (like `2.1.332`) when installed natively: `~/.local/bin/claude` links to
    /// `~/.local/share/claude/versions/<version>`, and the kernel names the process after that.
    static func matches(name: String, started: Date, sessionStarted: Date) -> Bool {
        (["claude", "node"].contains(name) || isVersion(name))
            && abs(started.timeIntervalSince(sessionStarted)) <= startTolerance
    }

    private static func isVersion(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}

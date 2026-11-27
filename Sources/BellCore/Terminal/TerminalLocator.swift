import Foundation

/// Finds which app a Claude session runs in, and how to bring it back.
public enum TerminalLocator {
    public static let ghosttyBundleID = "com.mitchellh.ghostty"

    /// Walks up the parent chain from `pid` to the first process that is a GUI app,
    /// such as Ghostty, Terminal or VS Code.
    ///
    /// - Parameters:
    ///   - parent: the parent of a process, nil when unknown.
    ///   - isApp: whether a process is a regular GUI app.
    public static func hostApp(
        of pid: Int32,
        parent: (Int32) -> Int32?,
        isApp: (Int32) -> Bool
    ) -> Int32? {
        var current = pid
        // A real chain is a handful of steps (claude, shell, login, app); the limit only
        // guards against a cycle in a racing process table.
        for _ in 0..<32 {
            if isApp(current) { return current }
            guard let next = parent(current), next > 1, next != current else { return nil }
            current = next
        }
        return nil
    }

    /// macOS names pseudo-terminals "/dev/ttys" plus digits. Anything else is rejected
    /// before it is handed to a script.
    public static func isTTYPath(_ path: String) -> Bool {
        guard path.hasPrefix("/dev/ttys") else { return false }
        let number = path.dropFirst("/dev/ttys".count)
        return (1...4).contains(number.count) && number.allSatisfy(\.isASCII) && number.allSatisfy(\.isNumber)
    }
}

/// Focuses the Ghostty terminal on a given device: its window, its tab and its split.
/// Ported from AI Pet, where it is verified against Ghostty 1.4.
public enum GhosttyScript {
    /// Opens a tab in the project with the user's own shell, as Ghostty starts any tab,
    /// and types claude into it, as iTerm2 and Terminal do. A scripted `command` is not
    /// used: Ghostty 1.4 runs it through `bash -c` without reading a `shell:` prefix.
    /// Initial input reaches the pty as raw bytes, not as a paste, so the line runs; the
    /// shell stays once claude exits.
    public static let launch = #"""
    on run argv
      set projectDirectory to item 1 of argv
      set claudeExecutable to item 2 of argv
      tell application id "com.mitchellh.ghostty"
        set cfg to new surface configuration
        set initial working directory of cfg to projectDirectory
        set initial input of cfg to (quoted form of claudeExecutable) & linefeed
        if (count of windows) is 0 then
          new window with configuration cfg
        else
          new tab in front window with configuration cfg
        end if
        activate
        return "launched"
      end tell
    end run
    """#

    public enum Outcome: Equatable, Sendable {
        case focused
        case missing
        case failed
    }

    /// The device arrives as the script's only argument and is never spliced into the
    /// source. Windows and tabs are referenced by id: Ghostty lists windows front to
    /// back, so a positional reference points somewhere else once focus moves. `focus`
    /// does not unzoom (1.4), so a zoomed sibling split is unzoomed first and zoomed back
    /// if focus still does not land. `focus` returns early, hence the pauses.
    public static let source = """
    on run argv
      set wanted to item 1 of argv
      tell application id "com.mitchellh.ghostty"
        set found to missing value
        repeat with w in windows
          repeat with tb in tabs of w
            repeat with candidate in terminals of tb
              if found is missing value and tty of candidate is wanted then set found to {id of w, id of tb, id of candidate}
            end repeat
          end repeat
        end repeat
        if found is missing value then return "missing"
        set {windowId, tabId, targetId} to found
        set target to terminal id targetId
        set place to tab id tabId of window id windowId
        focus target
        delay 0.3
        if id of focused terminal of place is not targetId then
          set shown to terminal id (id of focused terminal of place)
          perform action "toggle_split_zoom" on shown
          delay 0.3
          focus target
          delay 0.3
          if id of focused terminal of place is not targetId then perform action "toggle_split_zoom" on shown
        end if
        activate
        return "focused"
      end tell
    end run
    """

    public static func outcome(exitCode: Int32, output: String) -> Outcome {
        guard exitCode == 0 else { return .failed }
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "focused": return .focused
        case "missing": return .missing
        default: return .failed
        }
    }
}

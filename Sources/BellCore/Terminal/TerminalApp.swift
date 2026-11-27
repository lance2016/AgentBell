import Foundation

/// The terminals AgentBell opens new sessions in and finds a session's tab in. Each is
/// driven by AppleScript; paths and devices arrive as the script's arguments and are
/// never spliced into its source. Every focus script answers "focused" or "missing",
/// read with `GhosttyScript.outcome`.
public enum TerminalApp: String, CaseIterable, Identifiable, Sendable {
    case ghostty, iTerm, terminal

    /// Settings › 通用: where new sessions open.
    public static let defaultsKey = "terminal.app"

    public var id: String { rawValue }

    public var bundleID: String {
        switch self {
        case .ghostty: TerminalLocator.ghosttyBundleID
        case .iTerm: "com.googlecode.iterm2"
        case .terminal: "com.apple.Terminal"
        }
    }

    public var title: String {
        switch self {
        case .ghostty: "Ghostty"
        case .iTerm: "iTerm2"
        case .terminal: "终端"
        }
    }

    /// The name inside a Chinese sentence: a Latin name gets a space on each side, the
    /// Chinese one is quoted. Trim the sentence's ends after use.
    public var inSentence: String {
        self == .terminal ? "「终端」" : " \(title) "
    }

    /// Where to get it; nil for the one that comes with macOS.
    public var downloadPage: URL? {
        switch self {
        case .ghostty: URL(string: "https://ghostty.org/download")
        case .iTerm: URL(string: "https://iterm2.com/downloads.html")
        case .terminal: nil
        }
    }

    public init?(bundleID: String) {
        guard let app = Self.allCases.first(where: { $0.bundleID == bundleID }) else { return nil }
        self = app
    }

    /// The user's choice, even once uninstalled, so Settings can say so; with no choice
    /// yet, the first one installed. Terminal always is.
    public static func resolve(stored: String?, isInstalled: (TerminalApp) -> Bool) -> TerminalApp {
        stored.flatMap(TerminalApp.init(rawValue:)) ?? allCases.first(where: isInstalled) ?? .terminal
    }

    /// Arguments: project directory, Claude executable, and an optional session ID.
    public var launchScript: String {
        switch self {
        case .ghostty: GhosttyScript.launch
        case .iTerm: ITermScript.launch
        case .terminal: AppleTerminalScript.launch
        }
    }

    /// Argument: the session's terminal device.
    public var focusScript: String {
        switch self {
        case .ghostty: GhosttyScript.source
        case .iTerm: ITermScript.focus
        case .terminal: AppleTerminalScript.focus
        }
    }

    /// No arguments; answers the device of the terminal in front, or nothing. Only run
    /// while the app is in front, so the reference to the front window is the one shown.
    public var focusedTTYScript: String {
        let reference = switch self {
        case .ghostty: "tty of focused terminal of selected tab of front window"
        case .iTerm: "tty of current session of current window"
        case .terminal: "tty of selected tab of front window"
        }
        return """
        tell application id "\(bundleID)"
          try
            return \(reference)
          on error
            return ""
          end try
        end tell
        """
    }
}

/// iTerm2: a new tab in the front window, or a window of its own; a session found by
/// its device is brought forward with its window and tab. The shell stays once claude
/// exits, as in any tab the user opens.
enum ITermScript {
    static let launch = #"""
    on run argv
      set projectDirectory to item 1 of argv
      set claudeExecutable to item 2 of argv
      set claudeCommand to quoted form of claudeExecutable
      if (count of argv) > 2 then set claudeCommand to claudeCommand & " --resume " & quoted form of (item 3 of argv)
      set shellLine to "cd " & quoted form of projectDirectory & " && " & claudeCommand
      set wasRunning to application id "com.googlecode.iterm2" is running
      tell application id "com.googlecode.iterm2"
        if (count of windows) is 0 then
          set w to (create window with default profile)
        else if wasRunning then
          set w to current window
          tell w to create tab with default profile
        else
          -- Launching opened a window of its own: use it rather than add another.
          set w to current window
        end if
        tell current session of w to write text shellLine
        activate
        return "launched"
      end tell
    end run
    """#

    static let focus = """
    on run argv
      set wanted to item 1 of argv
      tell application id "com.googlecode.iterm2"
        repeat with w in windows
          repeat with t in tabs of w
            repeat with s in sessions of t
              if tty of s is wanted then
                tell w to select
                tell t to select
                tell s to select
                activate
                return "focused"
              end if
            end repeat
          end repeat
        end repeat
        return "missing"
      end tell
    end run
    """
}

/// The Terminal that comes with macOS. `do script` opens a window; when Terminal was not
/// running, launching it already opened one, so the command goes there.
enum AppleTerminalScript {
    static let launch = #"""
    on run argv
      set projectDirectory to item 1 of argv
      set claudeExecutable to item 2 of argv
      set claudeCommand to quoted form of claudeExecutable
      if (count of argv) > 2 then set claudeCommand to claudeCommand & " --resume " & quoted form of (item 3 of argv)
      set shellLine to "cd " & quoted form of projectDirectory & " && " & claudeCommand
      set wasRunning to application id "com.apple.Terminal" is running
      tell application id "com.apple.Terminal"
        if wasRunning or (count of windows) is 0 then
          do script shellLine
        else
          do script shellLine in window 1
        end if
        activate
        return "launched"
      end tell
    end run
    """#

    static let focus = """
    on run argv
      set wanted to item 1 of argv
      tell application id "com.apple.Terminal"
        repeat with w in windows
          repeat with t in tabs of w
            if tty of t is wanted then
              set selected of t to true
              set index of w to 1
              activate
              return "focused"
            end if
          end repeat
        end repeat
        return "missing"
      end tell
    end run
    """
}

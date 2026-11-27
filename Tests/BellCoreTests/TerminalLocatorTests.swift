import Foundation
import Testing
@testable import BellCore

struct TerminalLocatorTests {
    // claude(500) -> zsh(400) -> login(300) -> Ghostty(200) -> launchd(1)
    let parents: [Int32: Int32] = [500: 400, 400: 300, 300: 200, 200: 1]

    @Test func walksUpToTheFirstApp() {
        let host = TerminalLocator.hostApp(of: 500, parent: { parents[$0] }, isApp: { $0 == 200 })
        #expect(host == 200)
    }

    @Test func noAppInChain() {
        let host = TerminalLocator.hostApp(of: 500, parent: { parents[$0] }, isApp: { _ in false })
        #expect(host == nil)
    }

    @Test func unknownProcess() {
        let host = TerminalLocator.hostApp(of: 999, parent: { parents[$0] }, isApp: { $0 == 200 })
        #expect(host == nil)
    }

    @Test func cycleTerminates() {
        let host = TerminalLocator.hostApp(of: 10, parent: { $0 == 10 ? 11 : 10 }, isApp: { _ in false })
        #expect(host == nil)
    }

    @Test func ttyPaths() {
        #expect(TerminalLocator.isTTYPath("/dev/ttys001"))
        #expect(TerminalLocator.isTTYPath("/dev/ttys0123"))
        #expect(!TerminalLocator.isTTYPath("/dev/ttys"))
        #expect(!TerminalLocator.isTTYPath("/dev/ttys12345"))
        #expect(!TerminalLocator.isTTYPath("/dev/console"))
        #expect(!TerminalLocator.isTTYPath("/dev/ttys1\" & quit"))
        #expect(!TerminalLocator.isTTYPath("/dev/ttys１２"))
    }

    @Test func liveProcessHasParent() {
        // The test runner itself always has a parent.
        #expect(ProcessInspector.parent(of: getpid()) != nil)
    }

    @Test func scriptOutcome() {
        #expect(GhosttyScript.outcome(exitCode: 0, output: "focused\n") == .focused)
        #expect(GhosttyScript.outcome(exitCode: 0, output: "missing\n") == .missing)
        #expect(GhosttyScript.outcome(exitCode: 1, output: "") == .failed)
        #expect(GhosttyScript.outcome(exitCode: 0, output: "?") == .failed)
    }
}

struct TerminalAppTests {
    @Test func knowsTheTerminalsBySessionHost() {
        #expect(TerminalApp(bundleID: "com.mitchellh.ghostty") == .ghostty)
        #expect(TerminalApp(bundleID: "com.googlecode.iterm2") == .iTerm)
        #expect(TerminalApp(bundleID: "com.apple.Terminal") == .terminal)
        #expect(TerminalApp(bundleID: "com.microsoft.VSCode") == nil)
    }

    /// AgentBell's Ghostty scripts need 1.4.0; the others have no floor.
    @Test func ghosttyOlderThan140IsOutdated() {
        #expect(TerminalApp.ghostty.minimumVersion == "1.4.0")
        #expect(TerminalApp.ghostty.isOutdated(version: "1.3.1"))
        #expect(TerminalApp.ghostty.isOutdated(version: "1.2"))
        #expect(TerminalApp.ghostty.isOutdated(version: "0.9.9"))
        #expect(!TerminalApp.ghostty.isOutdated(version: "1.4.0"))
        #expect(!TerminalApp.ghostty.isOutdated(version: "1.4"))
        #expect(!TerminalApp.ghostty.isOutdated(version: "1.10.0"))
        #expect(!TerminalApp.ghostty.isOutdated(version: "2.0.0"))
        // Tip builds carry a suffix after the numbers.
        #expect(!TerminalApp.ghostty.isOutdated(version: "1.4.0-tip+0a1b2c3"))
        #expect(TerminalApp.ghostty.isOutdated(version: "1.3.2-tip+0a1b2c3"))
        // A version that cannot be read is not held against it.
        #expect(!TerminalApp.ghostty.isOutdated(version: nil))
        #expect(!TerminalApp.ghostty.isOutdated(version: "tip"))
        #expect(!TerminalApp.iTerm.isOutdated(version: "1.0"))
        #expect(TerminalApp.iTerm.minimumVersion == nil)
    }

    @Test func theUsersChoiceStandsEvenWhenItIsGone() {
        let onlyTerminal: (TerminalApp) -> Bool = { $0 == .terminal }
        #expect(TerminalApp.resolve(stored: "iTerm", isInstalled: onlyTerminal) == .iTerm)
        // No choice yet: the first one installed, in the order of the list.
        #expect(TerminalApp.resolve(stored: nil, isInstalled: { $0 != .ghostty }) == .iTerm)
        #expect(TerminalApp.resolve(stored: nil, isInstalled: onlyTerminal) == .terminal)
        #expect(TerminalApp.resolve(stored: "warp", isInstalled: { _ in true }) == .ghostty)
    }

    @Test func scriptsTakeTheirInputAsArguments() {
        for app in TerminalApp.allCases {
            #expect(app.launchScript.contains("item 1 of argv"))
            #expect(app.launchScript.contains("quoted form of claudeExecutable"))
            #expect(app.launchScript.contains(#"if (count of argv) > 2 then set claudeCommand to claudeCommand & " --resume " & quoted form of (item 3 of argv)"#))
            #expect(app.focusScript.contains("item 1 of argv"))
            #expect(app.focusScript.contains(app.bundleID))
            #expect(app.launchScript.contains(app.bundleID))
        }
        #expect(TerminalApp.terminal.downloadPage == nil)
        #expect(TerminalApp.ghostty.downloadPage != nil)
    }

    /// Ghostty 1.4 runs a scripted `command` through `bash -c "exec -l …"` without
    /// reading the `shell:` prefix, so the tab died with "exec: shell:exec: not found".
    /// The user's own shell starts as usual and claude is typed into it.
    @Test func ghosttyTypesClaudeIntoTheUsersShell() {
        let script = GhosttyScript.launch
        #expect(!script.contains("set command of"))
        #expect(script.contains("set initial input of cfg to claudeCommand & linefeed"))
        #expect(script.contains("set initial working directory of cfg to projectDirectory"))
    }
}

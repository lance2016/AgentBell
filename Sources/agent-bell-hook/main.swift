import BellCore
import Foundation

// Claude Code runs this for each hook event (DESIGN.md §3.3). It reads the event from
// stdin, keeps a few short fields, writes one line to AgentBell's socket and exits 0
// without printing anything, so it can neither block nor steer Claude Code.

/// PostToolUse carries the tool's whole output; anything past this is not read.
let maxInput = 32 * 1024 * 1024

let input = FileHandle.standardInput.readData(ofLength: maxInput)
if let event = HookEvent.from(hookInput: input, now: Date()), let line = event.line() {
    HookSocket.send(line)
}
exit(0)

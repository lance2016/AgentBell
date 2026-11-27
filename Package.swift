// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentBell",
    platforms: [.macOS(.v14)],
    targets: [
        // Pure logic: no AppKit or SwiftUI, fully unit-testable.
        .target(name: "BellCore"),
        // The menu bar app: status item, panel, notifications.
        .executableTarget(name: "AgentBell", dependencies: ["BellCore"]),
        // Run by Claude Code for each hook event; Foundation and BellCore only, so it starts fast.
        .executableTarget(name: "agent-bell-hook", dependencies: ["BellCore"]),
        .testTarget(name: "BellCoreTests", dependencies: ["BellCore"]),
    ]
)

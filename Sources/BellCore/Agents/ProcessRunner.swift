import Foundation

public struct ProcessOutput: Sendable {
    public let exitCode: Int32
    public let standardOutput: Data
    public let standardError: String
}

public enum ProcessRunnerError: Error, Sendable, Equatable {
    case launchFailed(String)
    case timedOut
}

/// Runs a short-lived child process without a shell. Arguments are passed as an array,
/// so nothing from a path or session name can become a command.
public enum ProcessRunner {
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 10
    ) async throws -> ProcessOutput {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(with: Result {
                    try runBlocking(executable, arguments, environment, timeout)
                })
            }
        }
    }

    private static func runBlocking(
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ timeout: TimeInterval
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        let killer = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // Drain stderr concurrently: a child that fills one pipe while we block on the
        // other would deadlock.
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let out = outPipe.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        killer.cancel()

        if process.terminationReason == .uncaughtSignal {
            throw ProcessRunnerError.timedOut
        }
        return ProcessOutput(
            exitCode: process.terminationStatus,
            standardOutput: out,
            standardError: String(decoding: errBox.data, as: UTF8.self)
        )
    }
}

/// Written by one thread, read after `DispatchGroup.wait()` on another.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

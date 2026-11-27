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
        timeout: TimeInterval = 10,
        currentDirectory: URL? = nil,
        inputFile: URL? = nil
    ) async throws -> ProcessOutput {
        // Cancelling the calling task stops the child and throws `CancellationError`.
        let handle = ProcessHandle()
        let output: ProcessOutput
        do {
            output = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async {
                        continuation.resume(with: Result {
                            try runBlocking(executable, arguments, environment, timeout, currentDirectory, inputFile, handle)
                        })
                    }
                }
            } onCancel: {
                handle.terminate()
            }
        } catch where Task.isCancelled {
            throw CancellationError()
        }
        try Task.checkCancellation()
        return output
    }

    private static func runBlocking(
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String]?,
        _ timeout: TimeInterval,
        _ currentDirectory: URL?,
        _ inputFile: URL?,
        _ handle: ProcessHandle
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectory
        if let environment { process.environment = environment }
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let input = try inputFile.map { try FileHandle(forReadingFrom: $0) }
        defer { try? input?.close() }
        process.standardInput = input ?? FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }
        handle.attach(process)

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

/// Lets a cancelled task stop its child, even one that has not started yet.
private final class ProcessHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func attach(_ process: Process) {
        lock.withLock {
            self.process = process
            if cancelled { process.terminate() }
        }
    }

    func terminate() {
        lock.withLock {
            cancelled = true
            if process?.isRunning == true { process?.terminate() }
        }
    }
}

/// Written by one thread, read after `DispatchGroup.wait()` on another.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

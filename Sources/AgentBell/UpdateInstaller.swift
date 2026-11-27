import BellCore
import Foundation

/// Puts a downloaded release next to the installed app, and swaps it in after the app quits.
/// Staging beside the app keeps the final move on one volume, so it is a rename.
enum UpdateInstaller {
    struct Failure: Error {
        let message: String
    }

    struct Staged: Sendable {
        /// Holds the unpacked app; removed after the swap.
        let directory: URL
        let app: URL
    }

    private static let stagingPrefix = ".AgentBell-update-"

    static func stage(
        _ release: Release,
        replacing installed: URL,
        progress: @escaping @Sendable (Double?) -> Void
    ) async throws -> Staged {
        guard let archiveURL = release.archive, let signatureURL = release.signature else {
            throw Failure(message: "这个版本没有安装包，请从下载页手动安装")
        }
        let parent = installed.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw Failure(message: "没有权限替换 \(parent.path) 里的 AgentBell，请从下载页手动安装")
        }
        removeLeftovers(in: parent)

        let signature = String(decoding: try await download(signatureURL, progress: nil), as: UTF8.self)
        let archive = try await download(archiveURL, progress: progress)
        guard UpdateSignature.isValid(archive, signature: signature) else {
            throw Failure(message: "安装包签名不对，已放弃安装")
        }

        let directory = parent.appendingPathComponent(stagingPrefix + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        do {
            let zip = directory.appendingPathComponent("update.zip")
            try archive.write(to: zip)
            try await run("/usr/bin/ditto", ["-x", "-k", zip.path, directory.path])
            try FileManager.default.removeItem(at: zip)
            let app = directory.appendingPathComponent(installed.lastPathComponent)
            try await check(app, version: release.version)
            return Staged(directory: directory, app: app)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Starts a shell that waits for this process to exit, moves the old app aside, moves
    /// the new one in (putting the old one back if that fails), and opens the result.
    static func swapAfterExit(_ staged: Staged, replacing installed: URL) throws {
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        if mv "$3" "$4/previous.app"; then
          mv "$2" "$3" || mv "$4/previous.app" "$3"
        fi
        open "$3"
        rm -rf "$4"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            "-c", script, "agentbell-update",
            String(ProcessInfo.processInfo.processIdentifier),
            staged.app.path, installed.path, staged.directory.path,
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    private static func download(_ url: URL, progress: (@Sendable (Double?) -> Void)?) async throws -> Data {
        let (bytes, response) = try await URLSession.shared.bytes(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw Failure(message: "下载没有完成，检查网络后再试一次")
        }
        let total = response.expectedContentLength
        var data = Data()
        if total > 0 { data.reserveCapacity(Int(total)) }
        var reported = -1
        for try await byte in bytes {
            data.append(byte)
            guard let progress, total > 0 else { continue }
            let percent = Int(Int64(data.count) * 100 / total)
            if percent != reported {
                reported = percent
                progress(Double(percent) / 100)
            }
        }
        return data
    }

    /// The unpacked app must be AgentBell, the version the release names, and intact.
    private static func check(_ app: URL, version: String) async throws {
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == version
        else { throw Failure(message: "安装包内容不对，已放弃安装") }
        try await run("/usr/bin/codesign", ["--verify", "--strict", app.path], failure: "安装包签名校验没通过，已放弃安装")
    }

    private static func run(_ tool: String, _ arguments: [String], failure: String = "安装包解压失败") async throws {
        let output = try await ProcessRunner.run(URL(fileURLWithPath: tool), arguments: arguments, timeout: 60)
        guard output.exitCode == 0 else { throw Failure(message: failure) }
    }

    /// Staging folders from an update that was downloaded but never restarted into.
    private static func removeLeftovers(in parent: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: parent.path)) ?? []
        for name in names where name.hasPrefix(stagingPrefix) {
            try? FileManager.default.removeItem(at: parent.appendingPathComponent(name))
        }
    }
}

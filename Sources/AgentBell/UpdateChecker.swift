import AppKit
import BellCore
import Foundation
import Observation
import os

/// Asks GitHub for the latest release once at launch and whenever the user asks, and
/// installs it in place when the user says so. It only reads the public release list and
/// downloads the release's files; nothing about the user is sent.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed
        /// Progress from 0 to 1, or nil while the size is unknown.
        case downloading(Release, progress: Double?)
        /// Unpacked and checked next to the installed app; a restart swaps it in.
        case ready(Release)
        case installFailed(Release, String)
    }

    private(set) var state: State = .idle

    /// Nil when run outside the app bundle, such as `swift run`: no version to compare.
    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    @ObservationIgnored private let log = Logger(subsystem: "com.agentbell.AgentBell", category: "update")
    @ObservationIgnored private var staged: UpdateInstaller.Staged?

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    func check() async {
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        guard let currentVersion else { return }
        state = .checking
        do {
            let (data, response) = try await URLSession.shared.data(from: ReleaseCheck.latestURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 404: the repository has no published release yet.
            if status == 404 {
                state = .upToDate
                return
            }
            guard status == 200, let release = ReleaseCheck.decode(data) else {
                log.error("update check got status \(status, privacy: .public)")
                state = .failed
                return
            }
            state = ReleaseCheck.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
            log.notice("update check latest=\(release.version, privacy: .public) current=\(currentVersion, privacy: .public)")
        } catch {
            log.error("update check failed: \(String(describing: error), privacy: .public)")
            state = .failed
        }
    }

    /// Downloads, verifies and unpacks the release next to the running app.
    func install(_ release: Release) async {
        guard case .available = state else { return }
        state = .downloading(release, progress: nil)
        do {
            staged = try await UpdateInstaller.stage(release, replacing: Bundle.main.bundleURL) { progress in
                Task { @MainActor [weak self] in
                    guard let self, case .downloading = self.state else { return }
                    self.state = .downloading(release, progress: progress)
                }
            }
            state = .ready(release)
            log.notice("update \(release.version, privacy: .public) staged")
        } catch {
            log.error("update install failed: \(String(describing: error), privacy: .public)")
            let message = (error as? UpdateInstaller.Failure)?.message ?? "下载没有完成，检查网络后再试一次"
            state = .installFailed(release, message)
        }
    }

    /// Quits; a helper swaps the new app in once this process is gone and opens it.
    func restart() {
        guard case .ready(let release) = state, let staged else { return }
        do {
            try UpdateInstaller.swapAfterExit(staged, replacing: Bundle.main.bundleURL)
            NSApp.terminate(nil)
        } catch {
            log.error("update swap failed to start: \(String(describing: error), privacy: .public)")
            state = .installFailed(release, "没能自动重启，请从下载页手动安装")
        }
    }
}

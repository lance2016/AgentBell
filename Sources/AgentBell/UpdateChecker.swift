import BellCore
import Foundation
import Observation
import os

/// Asks GitHub for the latest release once at launch and whenever the user asks.
/// It only reads the public release list; nothing about the user is sent.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed
    }

    private(set) var state: State = .idle

    /// Nil when run outside the app bundle, such as `swift run`: no version to compare.
    let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String

    @ObservationIgnored private let log = Logger(subsystem: "com.agentbell.AgentBell", category: "update")

    var available: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    func check() async {
        guard let currentVersion, state != .checking else { return }
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
}

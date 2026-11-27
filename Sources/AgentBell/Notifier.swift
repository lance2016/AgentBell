import AppKit
import BellCore
import Observation
import UserNotifications
import os

/// Posts and withdraws the system notifications (DESIGN.md §3.5, UI_DESIGN.md §5).
@MainActor
@Observable
final class Notifier: NSObject {
    enum Permission: Equatable {
        case unknown
        case notAsked
        case allowed
        case denied
    }

    /// Keys of the switches in Settings; all default to on.
    enum Key {
        static let waiting = "notify.waiting"
        static let failed = "notify.failed"
        static let done = "notify.done"
        static let showContent = "notify.showContent"
        /// Seconds a round must run before its end is worth a notification.
        static let longRound = "notify.longRound"
        /// Where they go: macOS notifications, and the bubbles beside the desktop icon.
        static let system = "notify.system"
        static let bubble = "notify.bubble"
    }

    private(set) var permission: Permission = .unknown
    /// macOS "显示预览" is "never": banners then say only "1 个通知". "When unlocked"
    /// shows them whenever the user is there to read them.
    private(set) var previewsHidden = false
    /// A notification was clicked; the session id it was about.
    @ObservationIgnored var onOpen: ((String) -> Void)?
    /// What to post and take back, for the bubbles beside the desktop icon.
    @ObservationIgnored var onChanges: ((Notices.Changes) -> Void)?

    /// The sessions as last seen. Nil until the first poll, which only sets the baseline:
    /// a restart must not announce everything that was already so.
    @ObservationIgnored private var previous: [String: Session]?
    /// Notices waiting on the check whether their terminal is in view, by id, with the
    /// check each belongs to.
    @ObservationIgnored private var checking: [String: Int] = [:]
    @ObservationIgnored private var checkCount = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.agentbell.AgentBell", category: "notify")

    private var center: UNUserNotificationCenter { .current() }

    static var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "")")
    }

    override init() {
        super.init()
        center.delegate = self
        Task { await refresh() }
    }

    func update(_ live: [String: Session]) {
        guard let previous else {
            previous = live
            return
        }
        self.previous = live
        let changes = Notices.changes(from: previous, to: live, prefs: Self.prefs)
        if !changes.withdraw.isEmpty {
            for id in changes.withdraw { checking[id] = nil }
            onChanges?(Notices.Changes(withdraw: changes.withdraw))
            // Taken back even with system notifications off: some may be from before.
            center.removeDeliveredNotifications(withIdentifiers: changes.withdraw)
        }
        guard !changes.post.isEmpty else { return }
        checkCount += 1
        let check = checkCount
        for notice in changes.post { checking[notice.id] = check }
        let sessions = changes.post.compactMap { live[$0.session] }
        Task {
            let watched = await TerminalJumper.watched(sessions)
            // Dropped meanwhile: taken back, or replaced by a newer notice.
            let post = changes.post.filter { checking[$0.id] == check && !watched.contains($0.session) }
            for notice in changes.post where checking[notice.id] == check { checking[notice.id] = nil }
            if !watched.isEmpty { log.notice("held back \(changes.post.count - post.count) for a watched terminal") }
            guard !post.isEmpty else { return }
            onChanges?(Notices.Changes(post: post))
            guard Self.isOn(Key.system) else { return }
            for notice in post {
                self.post(notice)
            }
        }
    }

    /// Shows the system's own prompt. Asked only once the user connected the hooks.
    func requestPermission() async {
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            log.error("notification authorization failed: \(String(describing: error), privacy: .public)")
        }
        await refresh()
    }

    func refresh() async {
        // The settings object is not Sendable; only the two values cross over.
        let (status, previews) = await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: (settings.authorizationStatus, settings.showPreviewsSetting))
            }
        }
        switch status {
        case .notDetermined: permission = .notAsked
        case .denied: permission = .denied
        default: permission = .allowed
        }
        previewsHidden = previews == .never
    }

    /// Every switch defaults to on.
    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    private static var prefs: NoticePrefs {
        NoticePrefs(
            waiting: isOn(Key.waiting),
            failed: isOn(Key.failed),
            done: isOn(Key.done),
            showContent: isOn(Key.showContent),
            longRound: UserDefaults.standard.object(forKey: Key.longRound) as? Double ?? NoticePrefs.longRoundChoices[0]
        )
    }

    private func post(_ notice: Notice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        if let subtitle = notice.subtitle { content.subtitle = subtitle }
        if let body = notice.body { content.body = body }
        content.threadIdentifier = notice.session
        content.userInfo = ["session": notice.session]
        content.sound = notice.silent ? nil : .default
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
        let kind = notice.kind.rawValue
        center.add(request) { [log] error in
            if let error {
                log.error("posting \(kind, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        log.notice("posted \(kind, privacy: .public)")
    }
}

extension Notifier: UNUserNotificationCenterDelegate {
    /// The panel makes AgentBell the active app; banners still show then.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let session = response.notification.request.content.userInfo["session"] as? String else { return }
        await MainActor.run { onOpen?(session) }
    }
}

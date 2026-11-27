import BellCore
import Foundation
import Observation
import os

/// Owns the session list and the polling loop. Read-only towards Claude Code: it only
/// runs `claude agents --json`.
@MainActor
@Observable
final class SessionStore {
    enum ClaudeState: Equatable {
        case locating
        case notFound
        case ready(URL)
    }

    private(set) var claude: ClaudeState = .locating
    /// The last `claude agents --json` call failed (old Claude Code, broken install).
    private(set) var listFailed = false
    private(set) var listIncomplete = false
    private(set) var tracker = SessionTracker()
    private static let pinnedProjectsKey = "pinnedProjects"
    private(set) var pinnedProjects = UserDefaults.standard.stringArray(forKey: pinnedProjectsKey) ?? []
    /// Claude Code's hooks: connection and incoming events.
    @ObservationIgnored let hooks = HookController()
    @ObservationIgnored let notifier = Notifier()
    @ObservationIgnored let updates = UpdateChecker()
    @ObservationIgnored let tasks = TaskStore()

    /// Polls faster while a panel is visible: the menu bar's, the window, or both.
    @ObservationIgnored private var openPanels = 0
    private var panelOpen: Bool { openPanels > 0 }

    func panelDidShow() {
        openPanels += 1
        if openPanels == 1 { pollNow() }
    }

    func panelDidHide() {
        openPanels = max(openPanels - 1, 0)
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var pollDelay: Task<Void, Never>?
    @ObservationIgnored private var pollRequested = false
    @ObservationIgnored private var claudePathRevision = 0
    @ObservationIgnored private let log = Logger(subsystem: "com.agentbell.AgentBell", category: "store")
    @ObservationIgnored private let overrideKey = "claudePathOverride"
    /// Transcript summaries by session id, re-read only when the file changes.
    @ObservationIgnored private var transcripts: [String: CachedTranscript] = [:]
    @ObservationIgnored private var hookPoll: Task<Void, Never>?
    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var roundsChanged = false
    @ObservationIgnored private var sessionsChanged = false
    private static let saveDelay: Duration = .seconds(1)

    @ObservationIgnored private var gitCache: [String: (snapshot: GitSnapshot?, at: Date)] = [:]
    @ObservationIgnored private var gitReads: [String: Task<GitSnapshot?, Never>] = [:]

    var liveSessions: [Session] { Array(tracker.live.values) }

    func toggleProjectPin(_ id: String) {
        if pinnedProjects.contains(id) {
            pinnedProjects.removeAll { $0 == id }
        } else {
            pinnedProjects.insert(id, at: 0)
        }
        UserDefaults.standard.set(pinnedProjects, forKey: Self.pinnedProjectsKey)
    }

    func workspaceSnapshot(cwd: String, force: Bool) async -> GitSnapshot? {
        if let running = gitReads[cwd] { return await running.value }
        let now = Date()
        gitCache = gitCache.filter { now.timeIntervalSince($0.value.at) < 5 }
        if !force, let cached = gitCache[cwd] { return cached.snapshot }
        let task = Task { await GitSnapshot.load(cwd: cwd) }
        gitReads[cwd] = task
        let snapshot = await task.value
        gitCache[cwd] = (snapshot, Date())
        gitReads[cwd] = nil
        return snapshot
    }

    func start() {
        tasks.load()
        tracker.restore(
            SavedState.load([String: HookState].self, from: SavedState.roundsFile) ?? [:],
            sessions: SavedState.load([Session].self, from: SavedState.sessionsFile) ?? []
        )
        hooks.start { [weak self] event in self?.applyHook(event) }
        pollNow()
    }

    /// Wakes the loop, or queues one refresh behind the command already running.
    func pollNow() {
        pollRequested = true
        pollDelay?.cancel()
        guard loop == nil else { return }
        loop = Task { await runLoop() }
    }

    /// A hook event: show it at once, and poll within 0.3 s so a session that just
    /// started or ended shows too. Events in a burst share one poll.
    func applyHook(_ event: HookEvent) {
        log.notice("hook \(event.event, privacy: .public)")
        hooks.noteEvent()
        let before = tracker
        tracker.applyHook(event)
        save(ifChangedFrom: before)
        // Before the first poll nothing is listed and nothing changes here.
        if tracker.live != before.live { notifier.update(tracker.live) }
        guard ["SessionStart", "SessionEnd", "UserPromptSubmit", "PermissionRequest", "Notification", "Stop", "StopFailure"].contains(event.event),
              hookPoll == nil else { return }
        hookPoll = Task {
            try? await Task.sleep(for: .milliseconds(300))
            hookPoll = nil
            pollNow()
        }
    }

    /// Keeps hook state and the session list across restarts. Each file is a few KB.
    /// Every tool call changes them, so writes wait a moment and go out together.
    private func save(ifChangedFrom before: SessionTracker) {
        if tracker.rounds != before.rounds { roundsChanged = true }
        if tracker.live != before.live || tracker.recent != before.recent { sessionsChanged = true }
        guard roundsChanged || sessionsChanged, pendingSave == nil else { return }
        pendingSave = Task {
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            pendingSave = nil
            saveNow()
        }
    }

    /// Writes what is waiting; also called on quit, so nothing waiting is lost.
    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        tasks.saveNow()
        do {
            if roundsChanged {
                try SavedState.save(tracker.rounds, to: SavedState.roundsFile)
                roundsChanged = false
            }
            if sessionsChanged {
                try SavedState.save(tracker.savedSessions, to: SavedState.sessionsFile)
                sessionsChanged = false
            }
        } catch {
            log.error("saving state failed: \(String(describing: error), privacy: .public)")
        }
    }

    func useClaude(at path: String) {
        UserDefaults.standard.set(path, forKey: overrideKey)
        claudePathRevision += 1
        claude = .locating
        tracker.invalidatePendingClosures()
        pollNow()
    }

    /// Each poll starts `claude agents`, about 0.1 s of CPU and 160 MB at its peak. With
    /// the hooks connected, every start, end, prompt and stop already polls within
    /// 0.3 s, so the timer only catches what no hook reports: an Esc, a closed terminal.
    private var interval: Duration {
        // Went idle mid-round: look again once the grace for a late Stop has passed.
        if tracker.needsRecheck { return .seconds(3.2) }
        if panelOpen { return .seconds(2) }
        if hooks.isReady { return tracker.live.isEmpty ? .seconds(60) : .seconds(20) }
        return tracker.live.isEmpty ? .seconds(30) : .seconds(10)
    }

    private func runLoop() async {
        defer { loop = nil }
        while !Task.isCancelled {
            pollRequested = false
            let revision = claudePathRevision
            let executable = await resolveClaude(revision: revision)
            if let executable { await refresh(executable: executable, revision: revision) }
            if pollRequested { continue }
            guard executable != nil else { return }
            let interval = interval
            let delay = Task { _ = try? await Task.sleep(for: interval) }
            pollDelay = delay
            await delay.value
            pollDelay = nil
        }
    }

    private func resolveClaude(revision: Int) async -> URL? {
        if case .ready(let url) = claude { return url }
        let override = UserDefaults.standard.string(forKey: overrideKey)
        let found = await ClaudeCLI.locate(override: override)
        guard !Task.isCancelled, revision == claudePathRevision else { return nil }
        claude = found.map(ClaudeState.ready) ?? .notFound
        if found == nil { log.error("claude executable not found") }
        return found
    }

    private func refresh(executable: URL, revision: Int) async {
        do {
            let snapshot = try await ClaudeCLI.snapshot(executable: executable)
            let records = snapshot.records
            let files = await Self.readFiles(records, cache: transcripts)
            guard !Task.isCancelled, revision == claudePathRevision else { return }
            listIncomplete = !snapshot.isComplete
            transcripts = files.transcripts
            var next = tracker
            next.applyPoll(
                records,
                at: Date(),
                isComplete: snapshot.isComplete,
                project: { files.projects[$0] ?? ProjectInfo(root: $0, branch: nil) },
                transcript: { files.transcripts[$0]?.summary }
            )
            if next != tracker {
                let before = tracker
                tracker = next
                save(ifChangedFrom: before)
            }
            transcripts = transcripts.filter { tracker.live[$0.key] != nil }
            notifier.update(tracker.live)
            if listFailed { listFailed = false }
        } catch {
            guard !Task.isCancelled, revision == claudePathRevision else { return }
            tracker.invalidatePendingClosures()
            log.error("claude agents failed: \(String(describing: error), privacy: .public)")
            listFailed = true
        }
    }

    /// Reads `.git` and the end of each transcript, off the main actor. A transcript is
    /// re-read only when its modification time changed since the last poll.
    nonisolated private static func readFiles(
        _ records: [AgentRecord],
        cache: [String: CachedTranscript]
    ) async -> (projects: [String: ProjectInfo], transcripts: [String: CachedTranscript]) {
        var projects: [String: ProjectInfo] = [:]
        for cwd in Set(records.map(\.cwd)) {
            projects[cwd] = ProjectInfo.lookup(cwd: cwd)
        }
        var transcripts = cache
        for record in records where record.pid != nil {
            let cached = cache[record.sessionId]
            guard let url = cached.flatMap({ FileManager.default.fileExists(atPath: $0.url.path) ? $0.url : nil })
                ?? Transcript.locate(sessionID: record.sessionId, cwd: record.cwd)
            else { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let cached, cached.url == url, cached.summary.modifiedAt == modified {
                transcripts[record.sessionId] = cached
            } else if let summary = Transcript.read(url) {
                transcripts[record.sessionId] = CachedTranscript(url: url, summary: summary)
            }
        }
        return (projects, transcripts)
    }
}

struct CachedTranscript: Sendable {
    let url: URL
    let summary: TranscriptSummary
}

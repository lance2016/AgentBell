import BellCore
import Foundation
import Observation
import os

/// The development tasks, kept in `tasks.json`. Edits land at once; writes wait a
/// moment so typing in a field saves once, and quitting writes what is left.
@MainActor
@Observable
final class TaskStore {
    private(set) var tasks: [DevTask] = []

    @ObservationIgnored private var pendingSave: Task<Void, Never>?
    @ObservationIgnored private var changed = false
    @ObservationIgnored private let log = Logger(subsystem: "com.agentbell.AgentBell", category: "tasks")
    private static let saveDelay: Duration = .milliseconds(500)

    /// A file that cannot be read is moved aside first, so the next save cannot overwrite it.
    func load() {
        do {
            tasks = try TaskFile.load()
        } catch {
            log.error("reading tasks failed: \(String(describing: error), privacy: .public)")
            do {
                let kept = try TaskFile.setAside(TaskFile.url, at: Date())
                log.error("unreadable tasks kept at \(kept.path, privacy: .public)")
            } catch {
                log.error("setting tasks aside failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    func task(_ id: UUID) -> DevTask? {
        tasks.first { $0.id == id }
    }

    func tasks(containing sessionID: String) -> [DevTask] {
        tasks.filter { $0.contains(sessionID: sessionID) }
    }

    /// Nil when the title is blank.
    @discardableResult
    func add(title: String) -> DevTask? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        let task = DevTask(title: title, createdAt: Date())
        tasks.append(task)
        scheduleSave()
        return task
    }

    /// Named after the session, already in progress, with its workspace linked.
    func add(from session: Session) -> DevTask {
        let now = Date()
        let task = DevTask(title: session.title, status: .inProgress, createdAt: now)
            .linking(TaskWorkspace(session: session, at: now))
        tasks.append(task)
        scheduleSave()
        return task
    }

    func link(_ session: Session, to id: UUID) {
        update(id) { $0.linking(TaskWorkspace(session: session, at: Date())) }
    }

    func unlink(workspace cwd: String, from id: UUID) {
        update(id) { $0.unlinking(workspace: cwd) }
    }

    func update(_ id: UUID, _ change: (DevTask) -> DevTask) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let next = change(tasks[index])
        guard next != tasks[index] else { return }
        tasks[index] = next
        scheduleSave()
    }

    func remove(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        scheduleSave()
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard changed else { return }
        do {
            try SavedState.save(tasks, to: TaskFile.url)
            changed = false
        } catch {
            log.error("saving tasks failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func scheduleSave() {
        changed = true
        guard pendingSave == nil else { return }
        pendingSave = Task {
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            pendingSave = nil
            saveNow()
        }
    }
}

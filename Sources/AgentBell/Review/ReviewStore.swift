import AppKit
import BellCore
import Observation

/// The reviews: those still running or failed in this run, and those saved as reports.
/// Owned by the app, not the window, so closing it loses nothing.
@MainActor
@Observable
final class ReviewStore {
    struct Job: Identifiable {
        enum Stage: Equatable {
            case preparing
            case reviewing
            case failed(String)
        }

        let id: String
        let request: ReviewRequest
        let message: String
        let directory: URL
        let model: ReviewModel
        let focus: String
        let startedAt: Date
        var plan: ReviewPlan?
        var stage: Stage

        var repositoryName: String { directory.lastPathComponent }
        var range: String? { plan.map { "\($0.sourceBranch) → \($0.targetBranch)" } }
        var running: Bool { stage == .preparing || stage == .reviewing }
    }

    private(set) var jobs: [Job] = []
    private(set) var records: [ReviewRecord] = []
    /// A review ended: its id, and whether it failed.
    @ObservationIgnored var onFinish: ((_ id: String, _ title: String, _ body: String, _ failed: Bool) -> Void)?

    @ObservationIgnored private let sessions: SessionStore
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loadedRoot: URL?

    init(sessions: SessionStore) {
        self.sessions = sessions
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.loadedRoot != nil, self.loadedRoot != ReviewPreference.reportsRoot else { return }
                self.reload()
            }
        }
    }

    var archive: ReviewArchive { ReviewArchive(root: ReviewPreference.reportsRoot) }

    /// Reads the saved reports again: the folder may have changed in Settings or Finder.
    func reload() {
        let archive = archive
        loadedRoot = archive.root
        records = archive.load()
    }

    func job(_ id: String) -> Job? { jobs.first { $0.id == id } }
    func record(_ id: String) -> ReviewRecord? { records.first { $0.id == id } }

    /// Starts a review and returns its id. Several may run at once.
    @discardableResult
    func start(_ request: ReviewRequest, message: String, directory: URL, model: ReviewModel, focus: String) -> String {
        let job = Job(id: UUID().uuidString, request: request, message: message, directory: directory,
                      model: model, focus: focus, startedAt: Date(), stage: .preparing)
        jobs.insert(job, at: 0)
        run(job)
        return job.id
    }

    /// Starts a failed review again with what it was asked.
    func retry(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].running else { return }
        jobs[index].stage = .preparing
        jobs[index].plan = nil
        run(jobs[index])
    }

    /// Stops a running review. Nothing is saved; its checkout is removed.
    func cancel(_ id: String) {
        tasks.removeValue(forKey: id)?.cancel()
        jobs.removeAll { $0.id == id }
    }

    /// Removes reports and failed reviews. Saved reports go with their checkouts.
    func delete(_ ids: Set<String>) {
        jobs.removeAll { ids.contains($0.id) && !$0.running }
        let archive = archive
        var problems: [String] = []
        for record in records where ids.contains(record.id) {
            do {
                try archive.delete(record)
            } catch {
                problems.append(record.folder.lastPathComponent)
            }
            Task {
                await ReviewRunner.discardCheckout(URL(fileURLWithPath: record.checkout),
                                                   repository: URL(fileURLWithPath: record.repository))
            }
        }
        reload()
        if !problems.isEmpty {
            let alert = NSAlert()
            alert.messageText = "部分审查记录无法删除"
            alert.informativeText = problems.joined(separator: "\n")
            alert.runModal()
        }
    }

    private func run(_ job: Job) {
        let base = UserDefaults.standard.string(forKey: ReviewPreference.baseBranch) ?? "main"
        let template = UserDefaults.standard.string(forKey: ReviewPreference.template) ?? ReviewRunner.defaultTemplate
        let requireFreshBase = UserDefaults.standard.object(forKey: ReviewPreference.requireCurrentTarget) as? Bool ?? true
        let claude = sessions.claude
        tasks[job.id] = Task { [weak self] in
            do {
                guard case .ready(let executable) = claude else {
                    throw ReviewFailure("找不到 Claude Code。请先在 AgentBell 通用设置选择可用的 Claude。")
                }
                let plan = try await ReviewRunner.prepare(job.request, directory: job.directory, base: base)
                try Task.checkCancellation()
                if requireFreshBase && plan.behind > 0 {
                    self?.update(job.id) { $0.plan = plan }
                    throw ReviewFailure("源分支落后目标分支 \(plan.behind) 个提交。请作者更新分支后重试，或在「审查设置」关闭这项检查。")
                }
                self?.update(job.id) {
                    $0.plan = plan
                    $0.stage = .reviewing
                }
                let outcome = try await ReviewRunner.run(
                    plan, claude: executable, template: template, focus: job.focus, model: job.model
                )
                try Task.checkCancellation()
                self?.finish(job, plan: plan, outcome: outcome)
            } catch where Task.isCancelled {
                // Stopped by the user: `cancel` already took it off the list. A Git step
                // cut short reports its own failure, so the task's state decides.
            } catch {
                self?.fail(job, error.localizedDescription)
            }
        }
    }

    private func finish(_ job: Job, plan: ReviewPlan, outcome: ReviewOutcome) {
        tasks[job.id] = nil
        let record = ReviewRecord(id: job.id, plan: plan, outcome: outcome, model: job.model, focus: job.focus,
                                  startedAt: job.startedAt)
        do {
            _ = try archive.save(record, report: outcome.report)
        } catch {
            fail(job, "审查已完成，但报告无法保存到「\(archive.root.path)」：\(error.localizedDescription)")
            return
        }
        jobs.removeAll { $0.id == job.id }
        reload()
        onFinish?(job.id, "审查完成", "\(job.repositoryName) · \(plan.sourceBranch) → \(plan.targetBranch)", false)
    }

    private func fail(_ job: Job, _ message: String) {
        tasks[job.id] = nil
        update(job.id) { $0.stage = .failed(message) }
        onFinish?(job.id, "审查失败", "\(job.repositoryName) · \(message)", true)
    }

    private func update(_ id: String, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }
}

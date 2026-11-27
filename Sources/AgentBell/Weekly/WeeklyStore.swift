import AppKit
import BellCore
import Observation

enum WeeklyPreference {
    static let template = "weekly.promptTemplate"
    static let model = "weekly.model"
    private static let excludedKey = "weekly.excludedProjects"

    /// Project folders left out of reports. Kept across weeks: a project not meant for
    /// the report usually stays that way.
    static var excludedProjects: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: excludedKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: excludedKey) }
    }
}

/// The weekly reports: those still being written or failed in this run, and those saved.
/// Owned by the app, not the window, so closing it loses nothing.
@MainActor
@Observable
final class WeeklyStore {
    struct Job: Identifiable {
        enum Stage: Equatable {
            case collecting
            case writing
            case failed(String)
        }

        let id: String
        let period: WeeklyPeriod
        let interval: DateInterval
        let model: ReviewModel
        let startedAt: Date
        var material: WeeklyMaterial?
        var stage: Stage

        var title: String { "周报 \(WeeklyPeriod.days(interval))" }
        var running: Bool { stage == .collecting || stage == .writing }
    }

    private(set) var jobs: [Job] = []
    private(set) var records: [WeeklyRecord] = []
    /// A report ended: its id, and whether it failed.
    @ObservationIgnored var onFinish: ((_ id: String, _ title: String, _ body: String, _ failed: Bool) -> Void)?

    @ObservationIgnored let archive = WeeklyArchive()
    @ObservationIgnored private let sessions: SessionStore
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]

    init(sessions: SessionStore) {
        self.sessions = sessions
    }

    func reload() {
        records = archive.load()
    }

    func job(_ id: String) -> Job? { jobs.first { $0.id == id } }
    func record(_ id: String) -> WeeklyRecord? { records.first { $0.id == id } }

    /// Reads the week's sessions off the main thread: a week of transcripts is hundreds of MB.
    nonisolated static func collect(_ interval: DateInterval) async -> WeeklyMaterial {
        await Task.detached(priority: .userInitiated) { WeeklyMaterial.collect(in: interval) }.value
    }

    /// Starts a report and returns its id. `material` is what the form already read, if
    /// any, with every project: the ones left out are dropped when the report starts.
    @discardableResult
    func start(_ period: WeeklyPeriod, model: ReviewModel, material: WeeklyMaterial?) -> String {
        let job = Job(id: UUID().uuidString, period: period, interval: period.interval(), model: model,
                      startedAt: Date(), material: material, stage: .collecting)
        jobs.insert(job, at: 0)
        run(job)
        return job.id
    }

    /// Starts a failed report again, reading the sessions afresh.
    func retry(_ id: String) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].running else { return }
        jobs[index].stage = .collecting
        jobs[index].material = nil
        run(jobs[index])
    }

    func cancel(_ id: String) {
        tasks.removeValue(forKey: id)?.cancel()
        jobs.removeAll { $0.id == id }
    }

    /// Removes reports and failed jobs. A saved report goes with its session's folder.
    func delete(_ ids: Set<String>) {
        jobs.removeAll { ids.contains($0.id) && !$0.running }
        var problems: [String] = []
        for record in records where ids.contains(record.id) {
            do {
                try archive.delete(record)
                WeeklyRunner.discardWorkspace(URL(fileURLWithPath: record.workspace))
            } catch {
                problems.append(record.folder.lastPathComponent)
            }
        }
        reload()
        if !problems.isEmpty {
            let alert = NSAlert()
            alert.messageText = "部分周报无法删除"
            alert.informativeText = problems.joined(separator: "\n")
            alert.runModal()
        }
    }

    private func run(_ job: Job) {
        let template = UserDefaults.standard.string(forKey: WeeklyPreference.template) ?? WeeklyRunner.defaultTemplate
        let claude = sessions.claude
        let days = WeeklyPeriod.days(job.interval)
        tasks[job.id] = Task { [weak self] in
            do {
                guard case .ready(let executable) = claude else {
                    throw ReviewFailure("找不到 Claude Code。请先在 AgentBell 通用设置选择可用的 Claude。")
                }
                let read: WeeklyMaterial
                if let material = job.material {
                    read = material
                } else {
                    read = await Self.collect(job.interval)
                }
                try Task.checkCancellation()
                let material = read.excluding(WeeklyPreference.excludedProjects)
                guard material.sessionCount > 0 else {
                    throw ReviewFailure(read.sessionCount == 0
                                        ? "\(days) 没有找到 Claude Code 会话记录。"
                                        : "\(days) 的项目都没有勾选，没有可写的内容。")
                }
                self?.update(job.id) {
                    $0.material = material
                    $0.stage = .writing
                }
                let prompt = WeeklyRunner.prompt(template: template, period: job.period, days: days)
                let outcome = try await WeeklyRunner.run(
                    material: material.rendered(), prompt: prompt, days: days, claude: executable, model: job.model
                )
                try Task.checkCancellation()
                self?.finish(job, material: material, outcome: outcome)
            } catch where Task.isCancelled {
                // Stopped by the user: `cancel` already took it off the list.
            } catch {
                self?.fail(job, error.localizedDescription)
            }
        }
    }

    private func finish(_ job: Job, material: WeeklyMaterial, outcome: WeeklyOutcome) {
        tasks[job.id] = nil
        let record = WeeklyRecord(id: job.id, period: job.period, interval: job.interval, model: job.model,
                                  material: material, outcome: outcome, startedAt: job.startedAt)
        do {
            _ = try archive.save(record, report: outcome.report)
        } catch {
            WeeklyRunner.discardWorkspace(outcome.workspace)
            fail(job, "周报已写好，但无法保存到「\(archive.root.path)」：\(error.localizedDescription)")
            return
        }
        jobs.removeAll { $0.id == job.id }
        reload()
        onFinish?(job.id, "周报写好了", "\(job.title) · \(material.sessionCount) 个会话", false)
    }

    private func fail(_ job: Job, _ message: String) {
        tasks[job.id] = nil
        update(job.id) { $0.stage = .failed(message) }
        onFinish?(job.id, "周报没写成", message, true)
    }

    private func update(_ id: String, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }
}

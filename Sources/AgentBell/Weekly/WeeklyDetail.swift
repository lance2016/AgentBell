import AppKit
import BellCore
import SwiftUI

/// What can be done with a saved report, from its page, the toolbar or the list's menu.
@MainActor
enum WeeklyActions {
    static func open(_ record: WeeklyRecord) {
        NSWorkspace.shared.open(record.reportURL)
    }

    static func reveal(_ record: WeeklyRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.reportURL])
    }

    static func canResume(_ record: WeeklyRecord) -> Bool {
        record.sessionID != nil && FileManager.default.fileExists(atPath: record.workspace)
    }

    /// Opens the report's own session in the terminal, to ask for changes in words.
    static func resume(_ record: WeeklyRecord, store: SessionStore) {
        guard let sessionID = record.sessionID, canResume(record) else { return }
        guard case .ready(let executable) = store.claude else {
            alert("找不到 Claude Code", "请先在 AgentBell 通用设置选择可用的 Claude。")
            return
        }
        Task {
            do {
                try await TerminalJumper.launchClaude(
                    in: .current, executable: executable, directory: record.workspace, resumeSessionID: sessionID
                ) {}
                store.pollNow()
            } catch {
                alert("无法在终端继续", error.localizedDescription)
            }
        }
    }

    static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// Picks the week and shows how much there is to write from before anything is sent.
struct NewWeeklyForm: View {
    let store: SessionStore
    let weekly: WeeklyStore
    @Bindable var state: WeeklyWindowState
    let openSettings: () -> Void

    /// The sessions read for a week, and when: reading them again takes seconds.
    private struct Read {
        let period: WeeklyPeriod
        let material: WeeklyMaterial
        let at: Date
    }

    /// A read older than this is done again when the report starts.
    private static let freshness: TimeInterval = 300

    @AppStorage(WeeklyPreference.model) private var defaultModel = ReviewModel.recommended
    @ViewState private var read: Read?
    @ViewState private var problem: String?
    @ViewState private var excluded = WeeklyPreference.excludedProjects

    private var model: Binding<ReviewModel> {
        Binding(get: { state.model ?? defaultModel }, set: { state.model = $0 })
    }

    private var current: Read? { read?.period == state.period ? read : nil }

    /// Starting needs no finished read; it only waits out a week with nothing picked.
    private var canStart: Bool { current.map { $0.material.excluding(excluded).sessionCount > 0 } ?? true }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Picker("时间", selection: $state.period) {
                        ForEach(WeeklyPeriod.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    LabeledContent("日期", value: WeeklyPeriod.days(state.period.interval()))
                    LabeledContent("会话记录") { materialStatus }
                } header: {
                    Text("生成周报")
                }
                if let projects = current?.material.projects, !projects.isEmpty {
                    Section {
                        ForEach(projects) { project in
                            projectToggle(project, among: projects)
                        }
                    } header: {
                        Text("项目")
                    } footer: {
                        Text("不勾选的项目不会写进周报，下次也会保持不勾选。")
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Picker("模型", selection: model) {
                        ForEach(ReviewModel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } footer: {
                    Text("会把这段时间你在 Claude Code 里的提问和每轮最后的回答交给所选模型整理。AgentBell 发起的审查和周报会话不算在内。")
                        .foregroundStyle(.secondary)
                }
                if let problem {
                    Text(problem).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("周报设置…", action: openSettings)
                Spacer()
                Button("生成周报", action: start)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canStart)
            }
            .padding(16)
        }
        .navigationTitle("生成周报")
        .task(id: state.period) {
            problem = nil
            let period = state.period
            let material = await WeeklyStore.collect(period.interval())
            guard !Task.isCancelled else { return }
            read = Read(period: period, material: material, at: Date())
        }
    }

    @ViewBuilder private var materialStatus: some View {
        if let material = current?.material {
            let picked = material.excluding(excluded)
            if material.sessionCount == 0 {
                Text("这段时间没有会话记录").foregroundStyle(.secondary)
            } else if picked.sessionCount == 0 {
                Text("没有勾选项目").foregroundStyle(.secondary)
            } else {
                Text("\(picked.sessionCount) 个会话 · \(picked.turnCount) 轮对话 · \(picked.projectCount) 个项目")
            }
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在读取…").foregroundStyle(.secondary)
            }
        }
    }

    /// A project of the same name as another says where it is.
    private func projectToggle(_ project: WeeklyMaterial.Project, among all: [WeeklyMaterial.Project]) -> some View {
        let included = Binding(
            get: { !excluded.contains(project.root) },
            set: { include in
                if include { excluded.remove(project.root) } else { excluded.insert(project.root) }
                WeeklyPreference.excludedProjects = excluded
            }
        )
        let duplicated = all.contains { $0.root != project.root && $0.name == project.name }
        return Toggle(isOn: included) {
            Text(project.name)
            Text(duplicated
                 ? "\(project.sessionCount) 个会话 · \(project.turnCount) 轮对话 · \((project.root as NSString).abbreviatingWithTildeInPath)"
                 : "\(project.sessionCount) 个会话 · \(project.turnCount) 轮对话")
        }
        .toggleStyle(.checkbox)
        .help((project.root as NSString).abbreviatingWithTildeInPath)
    }

    private func start() {
        guard canStart else { return }
        guard case .ready = store.claude else {
            problem = "找不到 Claude Code。请先在 AgentBell 通用设置选择可用的 Claude。"
            return
        }
        let fresh = current.flatMap { Date().timeIntervalSince($0.at) < Self.freshness ? $0.material : nil }
        let id = weekly.start(state.period, model: model.wrappedValue, material: fresh)
        state.model = nil
        state.selection = [id]
    }
}

/// A report still being written, or one that failed in this run.
struct WeeklyJobDetail: View {
    let job: WeeklyStore.Job
    let weekly: WeeklyStore

    @ViewState private var confirmingStop = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            switch job.stage {
            case .collecting, .writing:
                ProgressView().controlSize(.large)
                TimelineView(.periodic(from: job.startedAt, by: 1)) { context in
                    Text("\(job.stage == .collecting ? "正在读取会话记录" : "Claude 正在写周报")（\(ReviewActions.elapsed(since: job.startedAt, now: context.date))）")
                        .font(.title3)
                }
                Text("可以关闭窗口，写好后会通知你。")
                    .foregroundStyle(.secondary)
                Button("停止生成") { confirmingStop = true }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("周报没写成").font(.title3)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 440)
                HStack {
                    Button("移除") { weekly.delete([job.id]) }
                    Button("重试") { weekly.retry(job.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                GridRow { Text("时间").foregroundStyle(.secondary); Text("\(job.period.title) · \(WeeklyPeriod.days(job.interval))") }
                if let material = job.material {
                    GridRow { Text("素材").foregroundStyle(.secondary); Text("\(material.sessionCount) 个会话 · \(material.turnCount) 轮对话") }
                }
                GridRow { Text("模型").foregroundStyle(.secondary); Text(job.model.title) }
            }
            .font(.callout)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(job.title)
        .confirmationDialog("停止生成这份周报？", isPresented: $confirmingStop) {
            Button("停止生成", role: .destructive) { weekly.cancel(job.id) }
        } message: {
            Text("已经花掉的用量不会退回，也不会保存周报。")
        }
    }
}

/// A saved report: read as Markdown, or edited in place. Edits are saved to `report.md`
/// as you type, so there is nothing to forget to save.
struct WeeklyReportDetail: View {
    let record: WeeklyRecord
    let archive: WeeklyArchive
    let store: SessionStore
    let delete: () -> Void

    private enum Mode: Hashable { case preview, edit }

    /// Typing pauses this long before the file is written.
    private static let saveDelay: Duration = .milliseconds(600)

    @ViewState private var mode = Mode.preview
    @ViewState private var text = ""
    /// What the file holds, and whose file it is: the view outlives a change of record.
    @ViewState private var saved = ""
    @ViewState private var loaded: WeeklyRecord?
    @ViewState private var missing = false
    @ViewState private var copied = false

    var body: some View {
        Group {
            if missing {
                ContentUnavailableView("找不到周报文件", systemImage: "doc.questionmark",
                                       description: Text(record.reportURL.path))
            } else if mode == .edit {
                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(16)
                    .accessibilityLabel("周报内容")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        header
                        Divider()
                        MarkdownReport(text)
                    }
                    .padding(24)
                    .frame(maxWidth: 820, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .navigationTitle(record.title)
        .navigationSubtitle(subtitle)
        .task(id: record.id) { load() }
        .task(id: text) {
            do { try await Task.sleep(for: Self.saveDelay) } catch { return }
            save()
        }
        .onDisappear { save() }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("显示方式", selection: $mode) {
                    Label("预览", systemImage: "doc.richtext").tag(Mode.preview)
                    Label("编辑", systemImage: "pencil").tag(Mode.edit)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleOnly)
                .help("预览排版，或直接修改 Markdown")
                .disabled(missing)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label(copied ? "已复制" : "复制周报", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("复制周报的 Markdown 内容")
                .disabled(missing)
                Button { WeeklyActions.reveal(record) } label: { Label("在访达中显示", systemImage: "folder") }
                    .help("在访达中显示 report.md")
                Button { WeeklyActions.open(record) } label: { Label("用默认应用打开", systemImage: "arrow.up.forward.app") }
                    .help("用默认应用打开 report.md")
                Button { WeeklyActions.resume(record, store: store) } label: { Label("在终端继续", systemImage: "terminal") }
                    .help(WeeklyActions.canResume(record)
                          ? "在终端里接着这次会话，让 Claude 改周报"
                          : "这次会话的目录已不在，无法继续")
                    .disabled(!WeeklyActions.canResume(record))
                Button(role: .destructive, action: delete) { Label("删除", systemImage: "trash") }
                    .help("删除这份周报")
            }
        }
    }

    private var subtitle: String {
        guard mode == .edit else { return "\(record.sessionCount) 个会话 · \(record.model.title)" }
        return text == saved ? "已保存" : "正在保存…"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(record.title).font(.title2.weight(.semibold))
            Text("\(record.period.title) · \(record.sessionCount) 个会话、\(record.turnCount) 轮对话 · \(record.model.title) · \(record.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                .foregroundStyle(.secondary)
            Text((record.reportURL.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    /// Writes what is pending for the record shown before, then reads this one's file:
    /// it may have been edited elsewhere since.
    private func load() {
        save()
        copied = false
        let report = archive.report(record)
        missing = report == nil
        text = report ?? ""
        saved = text
        loaded = record
    }

    private func save() {
        guard let loaded, text != saved else { return }
        do {
            try archive.write(text, to: loaded)
            saved = text
        } catch {
            WeeklyActions.alert("无法保存周报", error.localizedDescription)
        }
    }
}

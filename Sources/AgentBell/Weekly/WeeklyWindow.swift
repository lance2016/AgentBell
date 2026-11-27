import AppKit
import BellCore
import Observation
import SwiftUI

/// What the weekly window shows, kept outside its views so a selection and the form's
/// choices survive closing the window.
@MainActor
@Observable
final class WeeklyWindowState {
    var selection: Set<String> = []
    var period: WeeklyPeriod = .thisWeek
    /// Nil until the user picks one: the default from Settings applies.
    var model: ReviewModel?
}

@MainActor
final class WeeklyWindowController {
    private let store: SessionStore
    private let weekly: WeeklyStore
    private let state = WeeklyWindowState()
    private let openSettings: () -> Void
    private lazy var window: NSWindow = {
        let host = NSHostingController(rootView: WeeklyView(
            store: store, weekly: weekly, state: state, openSettings: openSettings
        ))
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: host)
        window.title = "周报"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 440)
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 900, height: 620))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }()

    private static let frameName = "AgentBell.Weekly"

    init(store: SessionStore, weekly: WeeklyStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.weekly = weekly
        self.openSettings = openSettings
        weekly.onFinish = { [weak self] id, title, body, failed in
            self?.finished(id: id, title: title, body: body, failed: failed)
        }
    }

    /// Opens the window on a report, or on the form for a new one when `id` is nil.
    func show(selecting id: String?) {
        weekly.reload()
        state.selection = id.map { [$0] } ?? []
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Say when a report is done, unless the user is looking at it.
    private func finished(id: String, title: String, body: String, failed: Bool) {
        guard !(NSApp.isActive && window.isKeyWindow && state.selection == [id]) else { return }
        store.notifier.postBackground(.weekly, id: id, title: title, body: body, failed: failed)
    }
}

private struct WeeklyView: View {
    let store: SessionStore
    let weekly: WeeklyStore
    @Bindable var state: WeeklyWindowState
    let openSettings: () -> Void

    @ViewState private var pendingDeletion: Set<String> = []

    var body: some View {
        NavigationSplitView {
            WeeklySidebar(weekly: weekly, selection: $state.selection, delete: { pendingDeletion = deletable($0) })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.selection = []
                } label: {
                    Label("生成周报", systemImage: "square.and.pencil")
                }
                .help("生成周报（⌘N）")
                .keyboardShortcut("n")
            }
        }
        .confirmationDialog(
            pendingDeletion.count > 1 ? "删除 \(pendingDeletion.count) 份周报？" : "删除这份周报？",
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
        ) {
            Button("删除", role: .destructive) {
                weekly.delete(pendingDeletion)
                state.selection.subtract(pendingDeletion)
                pendingDeletion = []
            }
        } message: {
            Text("周报文件会一起删除，无法恢复，也不能再在终端继续这次会话。")
        }
        .onAppear { weekly.reload() }
    }

    @ViewBuilder private var detail: some View {
        if state.selection.count > 1 {
            ContentUnavailableView {
                Label("已选择 \(state.selection.count) 项", systemImage: "doc.on.doc")
            } actions: {
                Button("删除…", role: .destructive) { pendingDeletion = deletable(state.selection) }
                    .disabled(deletable(state.selection).isEmpty)
            }
        } else if let id = state.selection.first, let job = weekly.job(id) {
            WeeklyJobDetail(job: job, weekly: weekly)
        } else if let id = state.selection.first, let record = weekly.record(id) {
            WeeklyReportDetail(record: record, archive: weekly.archive, store: store,
                               delete: { pendingDeletion = [record.id] })
        } else {
            NewWeeklyForm(store: store, weekly: weekly, state: state, openSettings: openSettings)
        }
    }

    /// Reports still being written are stopped, not deleted.
    private func deletable(_ ids: Set<String>) -> Set<String> {
        ids.filter { weekly.job($0)?.running != true }
    }
}

private struct WeeklySidebar: View {
    let weekly: WeeklyStore
    @Binding var selection: Set<String>
    let delete: (Set<String>) -> Void

    private var running: [WeeklyStore.Job] { weekly.jobs.filter(\.running) }
    private var failed: [WeeklyStore.Job] { weekly.jobs.filter { !$0.running } }

    var body: some View {
        List(selection: $selection) {
            if !running.isEmpty {
                Section("生成中") {
                    ForEach(running) { WeeklyJobRow(job: $0).tag($0.id) }
                }
            }
            if !failed.isEmpty || !weekly.records.isEmpty {
                Section("已完成") {
                    ForEach(failed) { WeeklyJobRow(job: $0).tag($0.id) }
                    ForEach(weekly.records) { WeeklyRecordRow(record: $0).tag($0.id) }
                }
            }
        }
        .overlay {
            if weekly.jobs.isEmpty && weekly.records.isEmpty {
                ContentUnavailableView("还没有周报", systemImage: "calendar",
                                       description: Text("生成的周报会保存在这里，可以随时修改。"))
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first, let record = weekly.record(id) {
                WeeklyActions.open(record)
            }
        }
        .onDeleteCommand { delete(selection) }
    }

    @ViewBuilder private func menu(for ids: Set<String>) -> some View {
        if ids.count == 1, let id = ids.first, let record = weekly.record(id) {
            Button("用默认应用打开") { WeeklyActions.open(record) }
            Button("在访达中显示") { WeeklyActions.reveal(record) }
            Divider()
            Button("删除…", role: .destructive) { delete(ids) }
        } else if ids.count == 1, let id = ids.first, let job = weekly.job(id) {
            if job.running {
                Button("停止生成") { weekly.cancel(id) }
            } else {
                Button("重试") { weekly.retry(id) }
                Button("移除", role: .destructive) { weekly.delete(ids) }
            }
        } else if ids.count > 1 {
            Button("删除 \(ids.count) 项…", role: .destructive) { delete(ids) }
        }
    }
}

/// A report still being written or failed, in the window's list and on the panel's page.
struct WeeklyJobRow: View {
    let job: WeeklyStore.Job

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if job.running {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.title).fontWeight(.medium)
                status.font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        switch job.stage {
        case .collecting:
            Text("正在读取会话记录 · \(job.model.title)")
        case .writing:
            TimelineView(.periodic(from: job.startedAt, by: 1)) { context in
                Text("Claude 正在写 \(ReviewActions.elapsed(since: job.startedAt, now: context.date)) · \(job.model.title)")
            }
        case .failed:
            Text("失败").foregroundStyle(.red)
        }
    }
}

/// A saved report, in the window's list and on the panel's page.
struct WeeklyRecordRow: View {
    let record: WeeklyRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "calendar").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).fontWeight(.medium)
                Text("\(record.sessionCount) 个会话 · \(record.turnCount) 轮对话").lineLimit(1).foregroundStyle(.secondary)
                Text("\(record.finishedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.model.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

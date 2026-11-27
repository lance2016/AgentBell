import AppKit
import BellCore
import Observation
import SwiftUI

/// What the review window shows, kept outside its views so a draft or a selection
/// survives moving between reviews and closing the window.
@MainActor
@Observable
final class ReviewWindowState {
    var selection: Set<String> = []
    var message = ""
    var focus = ""
    /// Nil until the user picks one: the default from Settings applies.
    var model: ReviewModel?
}

@MainActor
final class ReviewWindowController {
    private let store: SessionStore
    private let reviews: ReviewStore
    private let state = ReviewWindowState()
    private let openSettings: () -> Void
    private lazy var window: NSWindow = {
        let host = NSHostingController(rootView: ReviewView(
            store: store, reviews: reviews, state: state, openSettings: openSettings
        ))
        // The views' toolbar items go into the window's toolbar.
        host.sceneBridgingOptions = [.toolbars]
        let window = NSWindow(contentViewController: host)
        window.title = "代码审查"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 700, height: 440)
        if !window.setFrameUsingName(Self.frameName) {
            window.setContentSize(NSSize(width: 900, height: 600))
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        return window
    }()

    private static let frameName = "AgentBell.Review"

    init(store: SessionStore, reviews: ReviewStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.reviews = reviews
        self.openSettings = openSettings
        reviews.onFinish = { [weak self] id, title, body, failed in
            self?.finished(id: id, title: title, body: body, failed: failed)
        }
    }

    /// Opens the window on a review, or on the form for a new one when `id` is nil.
    func show(selecting id: String?) {
        reviews.reload()
        state.selection = id.map { [$0] } ?? []
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Reviews run for minutes: say when one ends, unless the user is looking at it.
    private func finished(id: String, title: String, body: String, failed: Bool) {
        guard !(NSApp.isActive && window.isKeyWindow && state.selection == [id]) else { return }
        store.notifier.postReview(id: id, title: title, body: body, failed: failed)
    }
}

private struct ReviewView: View {
    let store: SessionStore
    let reviews: ReviewStore
    @Bindable var state: ReviewWindowState
    let openSettings: () -> Void

    @ViewState private var pendingDeletion: Set<String> = []

    var body: some View {
        NavigationSplitView {
            ReviewSidebar(reviews: reviews, selection: $state.selection, store: store,
                          delete: { pendingDeletion = deletable($0) })
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 360)
        } detail: {
            detail
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.selection = []
                } label: {
                    Label("新建审查", systemImage: "square.and.pencil")
                }
                .help("新建审查（⌘N）")
                .keyboardShortcut("n")
            }
        }
        .confirmationDialog(
            pendingDeletion.count > 1 ? "删除 \(pendingDeletion.count) 条审查记录？" : "删除这条审查记录？",
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } })
        ) {
            Button("删除", role: .destructive) {
                reviews.delete(pendingDeletion)
                state.selection.subtract(pendingDeletion)
                pendingDeletion = []
            }
        } message: {
            Text("报告文件和审查用的检出代码会一起删除，无法恢复。")
        }
        .onAppear { reviews.reload() }
    }

    @ViewBuilder private var detail: some View {
        if state.selection.count > 1 {
            ContentUnavailableView {
                Label("已选择 \(state.selection.count) 项", systemImage: "doc.on.doc")
            } actions: {
                Button("删除…", role: .destructive) { pendingDeletion = deletable(state.selection) }
                    .disabled(deletable(state.selection).isEmpty)
            }
        } else if let id = state.selection.first, let job = reviews.job(id) {
            JobDetail(job: job, reviews: reviews)
        } else if let id = state.selection.first, let record = reviews.record(id) {
            ReportDetail(record: record, archive: reviews.archive, store: store,
                         delete: { pendingDeletion = [record.id] })
        } else {
            NewReviewForm(store: store, reviews: reviews, state: state, openSettings: openSettings)
        }
    }

    /// Running reviews are stopped, not deleted.
    private func deletable(_ ids: Set<String>) -> Set<String> {
        ids.filter { reviews.job($0)?.running != true }
    }
}

private struct ReviewSidebar: View {
    let reviews: ReviewStore
    @Binding var selection: Set<String>
    let store: SessionStore
    let delete: (Set<String>) -> Void

    private var running: [ReviewStore.Job] { reviews.jobs.filter(\.running) }
    private var failed: [ReviewStore.Job] { reviews.jobs.filter { !$0.running } }

    var body: some View {
        List(selection: $selection) {
            if !running.isEmpty {
                Section("进行中") {
                    ForEach(running) { JobRow(job: $0).tag($0.id) }
                }
            }
            if !failed.isEmpty || !reviews.records.isEmpty {
                Section("已完成") {
                    ForEach(failed) { JobRow(job: $0).tag($0.id) }
                    ForEach(reviews.records) { RecordRow(record: $0).tag($0.id) }
                }
            }
        }
        .overlay {
            if reviews.jobs.isEmpty && reviews.records.isEmpty {
                ContentUnavailableView("还没有审查", systemImage: "text.magnifyingglass",
                                       description: Text("审查完成后，报告会保存在这里。"))
            }
        }
        .contextMenu(forSelectionType: String.self) { ids in
            menu(for: ids)
        } primaryAction: { ids in
            if ids.count == 1, let id = ids.first, let record = reviews.record(id) {
                ReviewActions.open(record)
            }
        }
        .onDeleteCommand { delete(selection) }
    }

    @ViewBuilder private func menu(for ids: Set<String>) -> some View {
        if ids.count == 1, let id = ids.first, let record = reviews.record(id) {
            Button("用默认应用打开") { ReviewActions.open(record) }
            Button("在访达中显示") { ReviewActions.reveal(record) }
            Button("复制报告") { _ = ReviewActions.copy(record, from: reviews.archive) }
            Button("在终端继续") { ReviewActions.resume(record, store: store) }
                .disabled(!ReviewActions.canResume(record))
            Divider()
            Button("删除…", role: .destructive) { delete(ids) }
        } else if ids.count == 1, let id = ids.first, let job = reviews.job(id) {
            if job.running {
                Button("停止审查") { reviews.cancel(id) }
            } else {
                Button("重试") { reviews.retry(id) }
                Button("移除", role: .destructive) { reviews.delete(ids) }
            }
        } else if ids.count > 1 {
            Button("删除 \(ids.count) 项…", role: .destructive) { delete(ids) }
        }
    }
}

private struct JobRow: View {
    let job: ReviewStore.Job

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
                Text(job.repositoryName).fontWeight(.medium)
                Text(job.range ?? job.message).lineLimit(1).foregroundStyle(.secondary)
                status.font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        switch job.stage {
        case .preparing:
            Text("准备中 · \(job.model.title)")
        case .reviewing:
            TimelineView(.periodic(from: job.startedAt, by: 1)) { context in
                Text("审查中 \(ReviewActions.elapsed(since: job.startedAt, now: context.date)) · \(job.model.title)")
            }
        case .failed:
            Text("失败").foregroundStyle(.red)
        }
    }
}

private struct RecordRow: View {
    let record: ReviewRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "doc.text").foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.repositoryName).fontWeight(.medium)
                Text(record.range).lineLimit(1).foregroundStyle(.secondary)
                Text("\(record.finishedAt.formatted(date: .abbreviated, time: .shortened)) · \(record.model.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

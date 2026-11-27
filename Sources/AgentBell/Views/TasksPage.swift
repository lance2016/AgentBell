import BellCore
import SwiftUI

/// What a task page and the session menus can do with tasks.
struct TaskActions {
    /// A new task named after the session, with its workspace linked.
    let newTask: (Session) -> Void
    let link: (Session, UUID) -> Void
    let open: (UUID) -> Void
    /// Back to a workspace's session while it still runs.
    let activate: (Session) -> Void
    let resume: (TaskWorkspace) -> Void
    let reveal: (String) -> Void
}

/// 开发任务: the tasks on the left, the picked one on the right. Too narrow for that, it
/// is the list, and a task's detail in its place once one is picked.
struct TasksPage: View {
    let store: SessionStore
    let state: PanelState
    let actions: TaskActions

    @FocusState private var addFocused: Bool
    @FocusState private var searchFocused: Bool
    @ViewState private var newTitle = ""

    private static let twoColumnWidth: CGFloat = 560
    private static let listWidth: CGFloat = 230

    private var tasks: TaskStore { store.tasks }

    private var shown: [DevTask] {
        DevTask.listOrder(tasks.tasks.filter { $0.matches(state.taskQuery) })
    }

    var body: some View {
        GeometryReader { geometry in
            let narrow = geometry.size.width < Self.twoColumnWidth
            Group {
                if !narrow {
                    HStack(spacing: 0) {
                        list.frame(width: Self.listWidth)
                        Rectangle().fill(BellLayout.hairline.opacity(0.6)).frame(width: 1)
                        detailColumn(picked(in: shown), back: false)
                    }
                } else if let task = state.taskID.flatMap(tasks.task) {
                    detailColumn(task, back: true)
                } else {
                    list
                }
            }
            .onChange(of: narrow, initial: true) { _, narrow in state.tasksNarrow = narrow }
        }
        .onChange(of: state.addingTask, initial: true) { _, adding in
            addFocused = adding
            if !adding { newTitle = "" }
        }
    }

    /// Beside the list: the task picked, or the first one when the search hides it.
    private func picked(in shown: [DevTask]) -> DevTask? {
        shown.first { $0.id == state.taskID } ?? shown.first
    }

    // MARK: - List

    private var list: some View {
        let shown = shown
        let picked = state.tasksNarrow ? nil : picked(in: shown)?.id
        return VStack(spacing: 8) {
            searchField
            if state.addingTask { addField }
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { task in
                        TaskRow(task: task, picked: task.id == picked) { state.taskID = task.id }
                    }
                }
                if shown.isEmpty { emptyList }
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索任务、项目或分支", text: Bindable(state).taskQuery)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("搜索任务、项目或分支")
            if !state.taskQuery.isEmpty {
                Button {
                    state.taskQuery = ""
                    searchFocused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, 8)
        .frame(height: BellLayout.controlHeight)
        .background(BellLayout.controlFill, in: RoundedRectangle(cornerRadius: BellLayout.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BellLayout.controlRadius, style: .continuous)
                .strokeBorder(searchFocused ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 2)
        }
    }

    /// A title is all a task needs; the rest can come later.
    private var addField: some View {
        HStack(spacing: 6) {
            Image(systemName: "plus")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("任务标题，回车保存", text: $newTitle)
                .textFieldStyle(.plain)
                .focused($addFocused)
                .onSubmit {
                    guard let task = tasks.add(title: newTitle) else { return }
                    state.taskQuery = ""
                    state.addingTask = false
                    if !state.tasksNarrow { state.taskID = task.id }
                }
        }
        .padding(.horizontal, 8)
        .frame(height: BellLayout.controlHeight)
        .background(BellLayout.cardFill, in: RoundedRectangle(cornerRadius: BellLayout.controlRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: BellLayout.controlRadius, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 2)
        }
        .help("回车保存，Esc 取消")
    }

    private var emptyList: some View {
        let filtering = !state.taskQuery.trimmingCharacters(in: .whitespaces).isEmpty
        return Text(filtering ? "没有匹配的任务" : "还没有任务。点「新建任务」记一条，或在会话详情里点「加入任务」。")
            .font(.rowDetail)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 96)
    }

    // MARK: - Detail

    @ViewBuilder private func detailColumn(_ task: DevTask?, back: Bool) -> some View {
        if let task {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if back { backButton }
                    TaskDetailView(task: task, store: store, actions: actions,
                                   focusTitle: state.taskToRename == task.id,
                                   didFocusTitle: { state.taskToRename = nil }) {
                        tasks.remove(task.id)
                        state.taskID = nil
                    }
                }
                .padding(.horizontal, BellLayout.inset + 6)
                .padding(.vertical, BellLayout.inset)
            }
            .id(task.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("没有选中的任务", systemImage: "checklist")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var backButton: some View {
        Button { state.taskID = nil } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                Text("全部任务")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .frame(height: BellLayout.controlHeight)
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
        .help("返回任务列表（Esc）")
        .padding(.leading, -6)
    }
}

private struct TaskRow: View {
    let task: DevTask
    let picked: Bool
    let onPick: () -> Void

    private var caption: String {
        let count = task.workspaces.count
        let place = count == 0 ? "未关联工作区" : "\(count) 个工作区"
        return task.status == .inProgress ? place : "\(task.status.title) · \(place)"
    }

    var body: some View {
        Button(action: onPick) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title.isEmpty ? "未命名任务" : task.title)
                    .font(.rowTitle)
                    .foregroundStyle(task.status == .done ? .secondary : .primary)
                    .strikethrough(task.status == .done)
                    .lineLimit(1)
                Text(caption)
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(picked ? BellLayout.selectionFill : .clear,
                        in: RoundedRectangle(cornerRadius: BellLayout.rowRadius + 2, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.rowRadius + 2))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}

extension DevTask.Status {
    var title: String {
        switch self {
        case .todo: "待做"
        case .inProgress: "进行中"
        case .done: "已完成"
        }
    }
}

/// The session menus' 加入任务: a new task from this session, the tasks it is already
/// in, and the open tasks it could join.
struct TaskMenuItems: View {
    let session: Session
    let tasks: TaskStore
    let actions: TaskActions

    var body: some View {
        let linked = tasks.tasks(containing: session.id)
        let open = DevTask.listOrder(tasks.tasks).filter { $0.status != .done && !$0.contains(sessionID: session.id) }
        Button("新建任务", systemImage: "plus") { actions.newTask(session) }
        if !open.isEmpty {
            Section("加入已有任务") {
                ForEach(open) { task in
                    Button(task.title.isEmpty ? "未命名任务" : task.title) { actions.link(session, task.id) }
                }
            }
        }
        if !linked.isEmpty {
            Section("已在任务中") {
                ForEach(linked) { task in
                    Button(task.title.isEmpty ? "未命名任务" : task.title) { actions.open(task.id) }
                }
            }
        }
    }
}

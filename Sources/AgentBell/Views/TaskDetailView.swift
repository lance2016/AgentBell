import AppKit
import BellCore
import SwiftUI

/// One task, to pick it back up: the next step first, then each workspace with the way
/// back to it. Every field edits in place and saves as you type.
struct TaskDetailView: View {
    let task: DevTask
    let store: SessionStore
    let actions: TaskActions
    /// Just made from a session: its title is the session's, likely worth renaming.
    let focusTitle: Bool
    let didFocusTitle: () -> Void
    let onDelete: () -> Void

    @FocusState private var titleFocused: Bool

    private var tasks: TaskStore { store.tasks }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            heading
            nextStep
            note
            workspaces
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: focusTitle, initial: true) { _, focus in
            guard focus else { return }
            // After the field is on screen, or the focus is lost.
            Task { @MainActor in
                titleFocused = true
                didFocusTitle()
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<DevTask, String>) -> Binding<String> {
        Binding(
            get: { task[keyPath: keyPath] },
            set: { value in
                tasks.update(task.id) { current in
                    var next = current
                    next[keyPath: keyPath] = value
                    return next
                }
            }
        )
    }

    private var status: Binding<DevTask.Status> {
        Binding(
            get: { task.status },
            set: { value in
                tasks.update(task.id) { current in
                    var next = current
                    next.status = value
                    return next
                }
            }
        )
    }

    // MARK: - Heading

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                TextField("任务标题", text: binding(\.title))
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
                    .focused($titleFocused)
                    .accessibilityLabel("任务标题")
                moreMenu
            }
            statusMenu
        }
    }

    /// A pop-up button, which HIG gives to a flat list of mutually exclusive states: it
    /// shows the current one and reads as a value, not as commands (a pull-down `Menu`)
    /// or as switching views (a segmented control, like the session detail's tabs).
    private var statusMenu: some View {
        Picker("状态", selection: status) {
            ForEach(DevTask.Status.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("任务状态")
    }

    private var moreMenu: some View {
        Menu {
            Button("删除任务", systemImage: "trash", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .fixedSize()
        .help("更多")
        .accessibilityLabel("更多操作")
    }

    // MARK: - Next step and note

    /// The one line to read when coming back, set off by an accent bar. Not green: green
    /// means done.
    private var nextStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("下一步").font(.system(size: 15, weight: .semibold)).accessibilityAddTraits(.isHeader)
            TextField("回来后第一件要做的事", text: binding(\.nextStep), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .lineLimit(1...8)
                .accessibilityLabel("下一步")
        }
        .padding(.leading, 12)
        .overlay(alignment: .leading) {
            Capsule().fill(Color.bellAccent).frame(width: 3)
        }
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("说明").font(.groupName).foregroundStyle(.secondary).accessibilityAddTraits(.isHeader)
            TextField("背景、链接、注意事项", text: binding(\.note), axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...12)
                .accessibilityLabel("说明")
        }
    }

    // MARK: - Workspaces

    private var workspaces: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("工作区").font(.groupName)
                if !task.workspaces.isEmpty {
                    Text("\(task.workspaces.count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if !task.workspaces.isEmpty { CardDivider() }
            if task.workspaces.isEmpty {
                Text("还没有关联工作区。在会话详情里点「加入任务」，会带上项目、目录、分支和会话。")
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
            }
            ForEach(Array(task.workspaces.enumerated()), id: \.element.id) { index, workspace in
                if index > 0 { CardDivider(leading: 14) }
                workspaceRow(workspace)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SessionGroupSurface())
    }

    private func workspaceRow(_ workspace: TaskWorkspace) -> some View {
        let live = store.tracker.live[workspace.sessionID]
        // The path is what you look for here, so it is never cut: when it does not fit
        // beside the status and button, those move under it.
        return ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                workspaceFacts(workspace, live: live, fullPath: true)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 8) {
                    sessionStatus(live)
                    workspaceButton(workspace, live: live)
                }
                .fixedSize()
            }
            VStack(alignment: .leading, spacing: 10) {
                workspaceFacts(workspace, live: live, fullPath: false)
                HStack(spacing: 8) {
                    sessionStatus(live)
                    Spacer(minLength: 8)
                    workspaceButton(workspace, live: live).fixedSize()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .contextMenu {
            if let live {
                Button("回到终端", systemImage: "terminal") { actions.activate(live) }
            }
            Button("复制恢复命令", systemImage: "doc.on.doc") { copy(workspace.resumeCommand) }
            Button("复制目录路径", systemImage: "folder") { copy(workspace.cwd) }
            Button("在访达中显示", systemImage: "folder") { actions.reveal(workspace.cwd) }
            Divider()
            Button("移除工作区", systemImage: "minus.circle", role: .destructive) {
                tasks.unlink(workspace: workspace.cwd, from: task.id)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Project, branch and directory. `fullPath` keeps the path whole so a row that
    /// would cut it does not fit.
    private func workspaceFacts(_ workspace: TaskWorkspace, live: Session?, fullPath: Bool) -> some View {
        // While the session runs, its branch is the one checked out now.
        let branch = live?.project.branch ?? workspace.branch
        let path = (workspace.cwd as NSString).abbreviatingWithTildeInPath
        return VStack(alignment: .leading, spacing: 4) {
            Text(workspace.projectName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.middle)
            if let branch {
                metaLine(branch, symbol: "arrow.triangle.branch")
                    .accessibilityLabel("分支 \(branch)")
            }
            metaLine(path, symbol: "folder", lines: fullPath ? 1 : 3)
                .fixedSize(horizontal: fullPath, vertical: false)
                .help(workspace.cwd)
                .accessibilityLabel("目录 \(workspace.cwd)")
        }
    }

    private func sessionStatus(_ live: Session?) -> some View {
        HStack(spacing: 6) {
            LampView(kind: live.map(LampKind.init) ?? .faint)
            Text(live == nil ? "会话已关闭" : "会话仍在运行")
                .font(.rowDetail)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func workspaceButton(_ workspace: TaskWorkspace, live: Session?) -> some View {
        if let live {
            Button("回到终端", systemImage: "terminal") { actions.activate(live) }
                .buttonStyle(.bordered)
        } else {
            Button("继续工作", systemImage: "terminal") { actions.resume(workspace) }
                .buttonStyle(.bordered)
                .help("在原工作区恢复 Claude Code 会话")
        }
    }

    private func metaLine(_ text: String, symbol: String, lines: Int = 1) -> some View {
        Label {
            Text(text).lineLimit(lines).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol).font(.system(size: 11)).frame(width: 14)
        }
        .labelStyle(TightLabelStyle())
        .font(.system(size: 12, design: .monospaced))
        .foregroundStyle(.secondary)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

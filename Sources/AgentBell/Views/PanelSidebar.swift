import BellCore
import SwiftUI

extension PanelView {
    /// Search, the cross-project inbox, and the project list above the settings button.
    var sidebar: some View {
        let projects = state.projects(store)
        let attentionPicked = state.needsAttentionOnly && !state.searchVisible
        let tasksPicked = state.tasksVisible && state.detailID == nil
        let picked = attentionPicked || tasksPicked || (state.searchVisible && state.detailID == nil)
            ? nil : state.detailSession(store)?.project.root ?? state.pickedEntry(store)?.id

        return VStack(alignment: .leading, spacing: 0) {
            if inWindow {
                Color.clear.frame(height: BellLayout.headerHeight(inWindow: true))
            }
            searchBox
                .padding(.horizontal, 10)
                .padding(.top, inWindow ? 0 : 11)
                .padding(.bottom, 10)
            VStack(spacing: 2) {
                sidebarAttention(picked: attentionPicked)
                sidebarTasks(picked: tasksPicked)
            }
            .padding(.horizontal, 10)
            // The pages above, the projects below.
            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(projects) { project in
                            let isPicked = project.id == picked
                            let pinned = store.pinnedProjects.contains(project.id)
                            ProjectPinRow(name: project.name, pinned: pinned,
                                          radius: BellLayout.rowRadius + 2,
                                          toggle: { store.toggleProjectPin(project.id) },
                                          newSession: { actions.launchInProject(project.id) },
                                          reveal: { actions.revealProject(project.id) }) { hovering in
                                ProjectItem(project: project, picked: isPicked,
                                            pinned: pinned, showCount: !hovering) {
                                    state.pick(project: project.id, store)
                                }
                            }
                            .background(isPicked ? BellLayout.selectionFill : .clear,
                                        in: RoundedRectangle(cornerRadius: BellLayout.rowRadius + 2, style: .continuous))
                            .id(project.id)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .onAppear {
                    if let picked { proxy.scrollTo(picked) }
                }
                .onChange(of: picked) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: store.pinnedProjects) { previous, current in
                    if let id = current.first, !previous.contains(id) { proxy.scrollTo(id, anchor: .top) }
                }
            }
            .accessibilityLabel("项目")
            Divider().padding(.horizontal, 14)
            HStack(spacing: 4) {
                Button(action: actions.openSettings) {
                    Label("设置…", systemImage: "gearshape")
                        .padding(.horizontal, 6)
                        .frame(height: BellLayout.controlHeight)
                }
                .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
                .help("设置（⌘,）")
                Spacer(minLength: 0)
                Button(action: actions.quit) {
                    Image(systemName: "power")
                        .frame(width: BellLayout.controlHeight, height: BellLayout.controlHeight)
                }
                .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
                .accessibilityLabel("退出 AgentBell")
                .help("退出 AgentBell（⌘Q）")
            }
            .font(.rowDetail)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .frame(height: 48)
        }
    }

    private func sidebarAttention(picked: Bool) -> some View {
        let count = state.attentionSessions(store).count
        return sidebarPage("待处理", symbol: "tray", count: count, picked: picked) {
            state.showAttention(true, store)
        }
        .accessibilityValue("\(count) 个待处理会话")
        .help("查看所有项目中待确认或出错的会话")
    }

    /// The count is what is not done yet.
    private func sidebarTasks(picked: Bool) -> some View {
        let count = store.tasks.tasks.count { $0.status != .done }
        return sidebarPage("开发任务", symbol: "chevron.left.forwardslash.chevron.right", count: count, picked: picked) {
            state.showTasks(true)
        }
        .accessibilityValue("\(count) 个未完成任务")
        .help("记下做到哪、在哪个分支和会话，回来时一键恢复")
    }

    /// A page above the projects, such as 待处理: picked like a project, with a count.
    private func sidebarPage(_ title: String, symbol: String, count: Int, picked: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                PanelSymbol(name: symbol)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)")
                        .font(.rowTime)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
            .background(picked ? BellLayout.selectionFill : .clear,
                        in: RoundedRectangle(cornerRadius: BellLayout.rowRadius + 2, style: .continuous))
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.rowRadius + 2))
        .accessibilityAddTraits(picked ? .isSelected : [])
    }

    /// One project in the content pane: its sessions as a plain list, and the closed ones
    /// folded away under them. Its name and how it stands are the pane's title.
    func projectPage(_ project: ProjectEntry, now: Date) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !project.live.isEmpty {
                sessionRows(project.live, now: now, mixedBranches: project.branchPerRow)
            }
            if !project.closed.isEmpty {
                closedFold(project, now: now)
            }
        }
        // The pane's own inset already stands the list off; the rows bring theirs.
        .padding(.horizontal, -BellLayout.rowInset)
    }

    /// "已关闭的 3 个会话": a fold while something is open, a plain caption once nothing is.
    @ViewBuilder private func closedFold(_ project: ProjectEntry, now: Date) -> some View {
        let expanded = state.showsClosed(project)
        let caption = Text("已关闭的 \(project.closed.count) 个会话")
            .font(.rowDetail)
            .foregroundStyle(.secondary)
        if project.live.isEmpty {
            caption
                .padding(.horizontal, BellLayout.rowInset + BellLayout.rowLeading)
                .padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
        } else {
            Button { state.toggleHistory(for: project.id) } label: {
                HStack(spacing: BellLayout.rowGap) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    caption
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, BellLayout.rowLeading)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(BellButtonStyle(radius: BellLayout.rowRadius + 2))
            .padding(.horizontal, BellLayout.rowInset)
            .padding(.top, 4)
            .accessibilityValue(expanded ? "已展开" : "已折叠")
        }
        if expanded {
            sessionRows(project.closed, now: now, compact: true)
        }
    }
}

private struct ProjectItem: View {
    let project: ProjectEntry
    let picked: Bool
    let pinned: Bool
    let showCount: Bool
    let onPick: () -> Void

    /// What wants a look first, then whether anything still runs; an idle project has no
    /// lamp, its count says the rest.
    private var lamp: LampKind? {
        let states = Set(project.live.map(\.state))
        if states.contains(.waiting) { return .waiting }
        if states.contains(.failed) { return .failed }
        if states.contains(.working) || states.contains(.background) { return .working }
        return nil
    }

    var body: some View {
        Button(action: onPick) {
            HStack(spacing: 8) {
                if let lamp {
                    LampView(kind: lamp).frame(width: 20)
                } else {
                    PanelSymbol(name: pinned ? "pin.fill" : "folder")
                }
                Text(project.name)
                    .font(.system(size: 13))
                    .foregroundStyle(project.live.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if showCount && !project.live.isEmpty {
                    Text("\(project.live.count)")
                        .font(.rowTime)
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 26, alignment: .trailing)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.rowRadius + 2, hovers: false))
        .help(project.id)
        .accessibilityLabel(project.name)
        .accessibilityValue(Copy.header(project.live) ?? "\(project.live.count) 个打开的会话")
        .accessibilityAddTraits(picked ? .isSelected : [])
    }
}


/// The pin replaces the count on hover; every project action is in the context menu.
/// The row draws the hover itself so the fill runs under the pin too.
struct ProjectPinRow<Content: View>: View {
    let name: String
    let pinned: Bool
    var radius = BellLayout.rowRadius
    let toggle: () -> Void
    let newSession: () -> Void
    let reveal: () -> Void
    @ViewBuilder let content: (Bool) -> Content
    @ViewState private var hovering = false

    private var title: String { pinned ? "取消置顶" : "置顶项目" }
    private var symbol: String { pinned ? "pin.fill" : "pin" }

    var body: some View {
        HStack(spacing: 0) {
            content(hovering)
            if hovering {
                Button(action: toggle) {
                    Image(systemName: symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: BellLayout.inlineControlSize, height: BellLayout.inlineControlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
                .accessibilityLabel("\(title)：\(name)")
                .help(title)
            }
        }
        .padding(.trailing, 4)
        .background(Color.primary.opacity(hovering ? BellLayout.hoverOpacity : 0),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu {
            Button("新建会话", systemImage: "plus", action: newSession)
            Button(title, systemImage: symbol, action: toggle)
            Button("在访达中显示", systemImage: "folder", action: reveal)
        }
        .accessibilityAction(named: Text(title), toggle)
        .accessibilityAction(named: Text("新建会话"), newSession)
        .accessibilityAction(named: Text("在访达中显示"), reveal)
    }
}

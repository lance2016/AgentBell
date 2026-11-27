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
                                ProjectItem(project: project, picked: isPicked, showCount: !hovering) {
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
        return sidebarPage("待处理", symbol: "tray.fill", tint: .attentionTile, count: count, picked: picked,
                           asksForYou: true) {
            state.showAttention(true, store)
        }
        .accessibilityValue("\(count) 个待处理会话")
        .help("查看所有项目中待确认或出错的会话")
    }

    /// The count is what is not done yet.
    private func sidebarTasks(picked: Bool) -> some View {
        let count = store.tasks.tasks.count { $0.status != .done }
        return sidebarPage("开发任务", symbol: "chevron.left.forwardslash.chevron.right", tint: .tasksTile,
                           count: count, picked: picked) {
            state.showTasks(true)
        }
        .accessibilityValue("\(count) 个未完成任务")
        .help("记下做到哪、在哪个分支和会话，回来时一键恢复")
    }

    /// A page above the projects, such as 待处理: picked like a project, with a count.
    /// A count that asks for you is a red badge, as System Settings marks an update.
    private func sidebarPage(_ title: String, symbol: String, tint: Color, count: Int, picked: Bool,
                             asksForYou: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconTile(symbol: symbol, color: tint)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
                if count > 0 {
                    SidebarCount(count: count, picked: picked, asksForYou: asksForYou)
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

    /// One project in the content pane: its sessions on a card, and the closed ones
    /// folded away on a card under it. Its name and how it stands are the pane's title.
    func projectPage(_ project: ProjectEntry, now: Date) -> some View {
        VStack(spacing: 10) {
            if !project.live.isEmpty {
                sessionRows(project.live, now: now)
                    .modifier(SessionGroupSurface())
            }
            if !project.closed.isEmpty {
                // A fold while something is open; with nothing open, the closed ones are the page.
                historySection(project.closed, now: now, expanded: state.showsClosed(project),
                               onToggle: project.live.isEmpty ? nil : { state.toggleHistory(for: project.id) })
                    .modifier(SessionGroupSurface())
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ProjectItem: View {
    let project: ProjectEntry
    let picked: Bool
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
                // Who it is on the left, as in System Settings; how it stands at the end.
                IconTile(symbol: "folder.fill", color: .project(project.id))
                    .opacity(project.live.isEmpty ? 0.5 : 1)
                Text(project.name)
                    .font(.system(size: 13))
                    .foregroundStyle(project.live.isEmpty ? .secondary : .primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if let lamp {
                    LampView(kind: lamp)
                }
                if showCount && !project.live.isEmpty {
                    SidebarCount(count: project.live.count, picked: picked)
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


/// A sidebar item's count: plain text, a filled accent badge once picked, or a red one
/// when it asks for you.
private struct SidebarCount: View {
    let count: Int
    let picked: Bool
    var asksForYou = false

    var body: some View {
        Group {
            if asksForYou {
                FilledBadge(count: count, color: Color(nsColor: .systemRed))
            } else if picked {
                FilledBadge(count: count, color: .bellAccent)
            } else {
                Text("\(count)")
                    .font(.rowTime)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 20)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The pin sits at the end of the row: always there once pinned, on hover otherwise.
/// Every project action is also in the context menu. The row draws the hover itself so
/// the fill runs under the pin too.
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
            if hovering || pinned {
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

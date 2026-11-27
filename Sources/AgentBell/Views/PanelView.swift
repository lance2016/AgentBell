import BellCore
import SwiftUI

struct PanelActions {
    let activate: (Session) -> Void
    let copyResume: (Session) -> Void
    /// Ends the session's `claude` process; asked for only after it was confirmed.
    let closeSession: (Session) -> Void
    let reveal: (Session) -> Void
    let revealProject: (String) -> Void
    let launchInProject: (String) -> Void
    let launchInFolder: () -> Void
    /// Opens a review in the review window.
    let openReview: (String) -> Void
    /// The form for a new review, in the given repository or matching one.
    let newReview: (String?) -> Void
    let chooseClaude: () -> Void
    let refreshSessions: () -> Void
    let openTerminalApp: (Session) -> Void
    let connectHooks: () -> Void
    let explainHooks: () -> Void
    let openSettings: () -> Void
    let quit: () -> Void
    let tasks: TaskActions
}

struct PanelView: View {
    let store: SessionStore
    let reviews: ReviewStore
    let state: PanelState
    let actions: PanelActions
    /// In the session window the panel draws under the title bar, around the traffic lights.
    let inWindow: Bool

    @AppStorage(PanelStyle.key) private var style = PanelStyle.list
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    /// The session list's own width, which decides how much a row says.
    @State private var listWidth: CGFloat = 0

    /// As in System Settings: the sidebar stays put while the content pane moves between
    /// a project's sessions, search results and a session's detail.
    private var showsSidebar: Bool { style == .sidebar && state.canBrowse(store) }

    var body: some View {
        let detailSession = state.detailSession(store)
        Group {
            if showsSidebar {
                // The sidebar runs the full height on the material; the content pane,
                // its header included, is a solid layer beside it.
                GeometryReader { geometry in
                    HStack(spacing: 0) {
                        sidebar.frame(width: BellLayout.sidebarWidth(for: geometry.size.width))
                        VStack(spacing: 0) {
                            contentHeader(detail: detailSession)
                            contentPane
                        }
                        .background(BellLayout.contentFill)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    listHeader(detail: detailSession)
                    contentPane
                    if detailSession == nil {
                        Divider()
                        footer
                    }
                }
            }
        }
        .ignoresSafeArea()
        .alert(closingTitle, isPresented: closing, presenting: closingSession) { session in
            Button("关闭会话", role: .destructive) { actions.closeSession(session) }
            Button("取消", role: .cancel) {}
        } message: { _ in
            Text("会结束这个会话的 Claude 进程，正在进行的这一轮会中断。对话会保留，之后可以用 claude --resume 恢复。")
        }
        .environment(\.lampsAnimate, state.isVisible)
        .onChange(of: style) { _, style in state.preserveSelection(afterSwitchTo: style, store) }
        .onChange(of: state.searchVisible) { _, visible in searchFocused = visible }
        .onChange(of: state.searchFocusRequest) { _, _ in searchFocused = true }
        .onChange(of: state.detailID) { _, id in
            searchFocused = id == nil && state.searchVisible
            if state.renamingID != id { state.renamingID = nil }
        }
    }

    private var closingSession: Session? {
        state.closingID.flatMap { id in store.liveSessions.first { $0.id == id } }
    }

    private var closingTitle: String {
        closingSession.map { "关闭「\($0.title)」？" } ?? "关闭会话？"
    }

    /// Asked before ending a process: the round in progress is lost (HIG: confirm a
    /// destructive action whose result is hard to take back).
    private var closing: Binding<Bool> {
        Binding(get: { closingSession != nil }, set: { if !$0 { state.closingID = nil } })
    }

    /// One column: the app's name and search on top, or the way back from a detail. In
    /// the window it starts past the traffic lights.
    private func listHeader(detail: Session?) -> some View {
        HStack(spacing: 10) {
            if let detail {
                detailBar(detail)
            } else if state.tasksVisible {
                pageBar("开发任务") { state.showTasks(false) }
            } else if state.reviewsVisible {
                pageBar("代码审查") { state.showReviews(false) }
            } else if state.searchVisible {
                BellAppIcon(size: 28)
                searchField
            } else {
                BellAppIcon(size: 28)
                Text("AgentBell").font(.panelHeader)
                Spacer(minLength: 0)
                searchButton
            }
            if detail == nil { headerAction }
        }
        .padding(.leading, inWindow ? BellLayout.trafficLightsWidth : 16)
        .padding(.trailing, 16)
        .modifier(PanelHeaderSurface(inWindow: inWindow))
    }

    /// Beside the sidebar: the current page or the way back from a detail.
    private func contentHeader(detail: Session?) -> some View {
        HStack(spacing: 10) {
            if let detail {
                detailBar(detail)
            } else if state.tasksVisible {
                pageTitle("开发任务")
            } else if state.reviewsVisible {
                pageTitle("代码审查")
            } else if state.searchVisible {
                pageTitle("搜索")
            } else if state.needsAttentionOnly {
                pageTitle("待处理")
            } else if let project = state.pickedEntry(store) {
                projectTitle(project.name)
                if let caption = Copy.header(project.live) {
                    Text(caption)
                        .font(.rowDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Spacer(minLength: 0)
            }
            if detail == nil {
                if state.searchVisible || state.needsAttentionOnly || state.tasksVisible || state.reviewsVisible {
                    Spacer(minLength: 0)
                }
                headerAction
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, BellLayout.inset)
        .modifier(PanelHeaderSurface(inWindow: inWindow))
    }

    private func pageTitle(_ title: String) -> some View {
        Text(title).font(.panelHeader).accessibilityAddTraits(.isHeader)
    }

    /// One column: the way back to the sessions, then the page's name.
    private func pageBar(_ title: String, back: @escaping () -> Void) -> some View {
        Group {
            Button(action: back) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .medium))
                    Text("会话")
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: BellLayout.controlHeight)
            }
            .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
            .accessibilityLabel("返回会话")
            .help("返回会话（Esc）")
            pageTitle(title)
            Spacer(minLength: 0)
        }
    }

    /// The header's one way to make something: a session, or on its own page a task or
    /// a review.
    @ViewBuilder private var headerAction: some View {
        if state.tasksVisible {
            newTaskButton
        } else if state.reviewsVisible {
            newReviewButton
        } else {
            newSessionMenu
        }
    }

    private var newReviewButton: some View {
        Button { actions.newReview(nil) } label: {
            Label("新建审查", systemImage: "plus")
                .padding(.horizontal, 6)
                .frame(height: BellLayout.controlHeight)
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
        .fixedSize()
        .help("在审查窗口填写要审查的 MR 或分支")
    }

    private var newTaskButton: some View {
        Button { state.addingTask = true } label: {
            Label("新建任务", systemImage: "plus")
                .padding(.horizontal, 6)
                .frame(height: BellLayout.controlHeight)
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
        .fixedSize()
        .help("记一条任务，只填标题也行")
    }

    private var tasksButton: some View {
        Button { state.showTasks(true) } label: {
            Label("任务", systemImage: "checklist")
                .labelStyle(TightLabelStyle())
                .font(.rowDetail)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: BellLayout.controlHeight)
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
        .help("开发任务：记下做到哪、在哪个分支和会话")
    }

    private var reviewsButton: some View {
        let running = reviews.jobs.count(where: \.running)
        return Button { state.showReviews(true) } label: {
            Label(running > 0 ? "审查 \(running)" : "审查", systemImage: "text.magnifyingglass")
                .labelStyle(TightLabelStyle())
                .font(.rowDetail)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: BellLayout.controlHeight)
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
        .accessibilityValue(running > 0 ? "\(running) 个进行中" : "")
        .help("代码审查：进行中的审查和已保存的报告")
    }

    private var newSessionMenu: some View {
        let pinned = store.pinnedProjects
        let recent = state.projects(store).map(\.id).filter { !pinned.contains($0) }
        return Menu {
            if !pinned.isEmpty {
                Section("置顶项目") { launchProjectButtons(pinned) }
            }
            if !recent.isEmpty {
                Section("最近项目") { launchProjectButtons(Array(recent.prefix(8))) }
            }
            Button("选择文件夹…", systemImage: "folder", action: actions.launchInFolder)
            Divider()
            Button("新建代码审查…", systemImage: "text.magnifyingglass") { actions.newReview(nil) }
        } label: {
            // macOS draws a menu's label itself and keeps only its icon and text, so
            // the text and the indicator have to say what it does.
            Label("新建会话", systemImage: "plus")
        }
        // The page's one main action: filled with the system accent the user picked.
        .menuStyle(.button)
        .buttonStyle(.borderedProminent)
        .menuIndicator(.visible)
        .fixedSize()
        .help("在项目里新建 Claude 会话")
    }

    private func launchProjectButtons(_ paths: [String]) -> some View {
        ForEach(paths, id: \.self) { path in
            let name = (path as NSString).lastPathComponent
            let duplicated = paths.contains { $0 != path && ($0 as NSString).lastPathComponent == name }
            Button(duplicated ? (path as NSString).abbreviatingWithTildeInPath : name) {
                actions.launchInProject(path)
            }
        }
    }

    /// The picked project's name. Only a title: its actions are on the project's row.
    private func projectTitle(_ name: String) -> some View {
        Text(name)
            .font(.panelHeader)
            .lineLimit(1)
            .truncationMode(.middle)
            .accessibilityAddTraits(.isHeader)
            .help(name)
    }

    /// "‹ 项目名": the way back says where it goes, as in a navigation bar.
    private func detailBar(_ detail: Session) -> some View {
        Group {
            Button { state.detailID = nil } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 13, weight: .medium))
                    Text(detail.project.name).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: BellLayout.controlHeight)
            }
            .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
            .accessibilityLabel("返回 \(detail.project.name)")
            .help("返回（Esc）")
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private var searchButton: some View {
        if state.canBrowse(store) {
            toolButton("搜索会话", symbol: "magnifyingglass", note: "搜索会话（⌘F）") {
                state.showSearch()
            }
        }
    }

    private var attentionButton: some View {
        let count = state.attentionSessions(store).count
        return Button { state.showAttention(!state.needsAttentionOnly, store) } label: {
            Label(count > 0 ? "待处理 \(count)" : "待处理", systemImage: "tray")
                .labelStyle(TightLabelStyle())
                .font(.rowDetail)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .frame(height: BellLayout.controlHeight)
                .background(state.needsAttentionOnly ? BellLayout.selectionFill : .clear,
                            in: RoundedRectangle(cornerRadius: BellLayout.controlRadius))
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
        .accessibilityAddTraits(state.needsAttentionOnly ? .isSelected : [])
        .help("跨项目查看待确认和失败的会话")
    }

    private var contentPane: some View {
        let session = state.detailSession(store)
        return Group {
            if state.canBrowse(store) || session != nil {
                ZStack {
                    browser
                        .opacity(session == nil ? 1 : 0)
                        .allowsHitTesting(session == nil)
                        .disabled(session != nil)
                        .accessibilityHidden(session != nil)
                    if let session {
                        detail(session)
                    }
                }
            } else {
                ScrollView {
                    setup.frame(maxWidth: .infinity, minHeight: 205)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BellLayout.contentFill)
    }

    private var browserID: String? {
        if state.searchVisible { return nil }
        if state.needsAttentionOnly { return "attention" }
        return showsSidebar ? state.pickedEntry(store)?.id : nil
    }

    private var browser: some View {
        VStack(spacing: 0) {
            notice
            if state.tasksVisible {
                TasksPage(store: store, state: state, actions: actions.tasks)
            } else if state.reviewsVisible {
                ReviewsPage(reviews: reviews, open: actions.openReview)
            } else {
                sessionBrowser
            }
        }
    }

    @ViewBuilder private var sessionBrowser: some View {
        if !showsSidebar && !state.searchVisible {
            HStack {
                statusSummary
                Spacer(minLength: 4)
                tasksButton
                reviewsButton
                attentionButton
            }
            .padding(.horizontal, BellLayout.inset)
            .padding(.top, 8)
        }
        sessionScroll {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                if state.needsAttentionOnly && !state.searchVisible {
                    attentionPage(now: context.date)
                } else if showsSidebar && !state.searchVisible {
                    if let picked = state.pickedEntry(store) {
                        projectPage(picked, now: context.date)
                    } else {
                        emptySessions
                    }
                } else {
                    listContent(now: context.date)
                }
            }
            .padding(BellLayout.inset)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
        .id(browserID)
    }

    private func attentionPage(now: Date) -> some View {
        let sessions = state.attentionSessions(store)
        return VStack(alignment: .leading, spacing: 10) {
            if sessions.isEmpty {
                ContentUnavailableView("没有待处理会话", systemImage: "checkmark.circle")
            } else {
                sessionRows(sessions, now: now, showProject: true)
                    .modifier(SessionGroupSurface())
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            searchBox
            Button("取消") { state.closeSearch() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("关闭搜索（Esc）")
        }
    }

    /// The field itself. In the sidebar it is always there, as in System Settings: typing
    /// starts the search, Esc or the clear button ends it.
    var searchBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索项目、会话或分支", text: Bindable(state).query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel("搜索所有项目、会话或分支")
                .onChange(of: state.query) { _, query in
                    if showsSidebar && !query.isEmpty { state.showSearch() }
                    if state.searchVisible { state.selectedID = nil }
                }
            if !state.query.isEmpty {
                Button {
                    if showsSidebar {
                        state.closeSearch()
                    } else {
                        state.query = ""
                        searchFocused = true
                    }
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

    var statusSummary: some View {
        let sessions = store.liveSessions
        let waiting = sessions.count { $0.state == .waiting }
        let working = sessions.count { $0.state == .working || $0.state == .background }
        let failed = sessions.count { $0.state == .failed }
        return HStack(spacing: 14) {
            if waiting > 0 { status("\(waiting) 个待确认", kind: .waiting) }
            if working > 0 { status("\(working) 个在工作", kind: .working) }
            if failed > 0 { status("\(failed) 个出错", kind: .failed) }
            if waiting == 0 && working == 0 && failed == 0 {
                Text(sessions.isEmpty ? "没有打开的会话" : "\(sessions.count) 个会话")
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
            }
        }
    }

    func status(_ title: String, kind: LampKind) -> some View {
        HStack(spacing: 6) {
            LampView(kind: kind)
            Text(title).font(.rowDetail).monospacedDigit()
        }
    }

    @ViewBuilder private var notice: some View {
        let connection = store.hooks.connection
        if store.listFailed {
            let message = store.liveSessions.isEmpty ? "无法读取当前会话" : "会话刷新失败，正在显示上次结果"
            noticeRow(message, actionTitle: "重试", action: actions.refreshSessions)
        } else if store.listIncomplete {
            noticeRow("部分会话数据无法识别", actionTitle: "重试", action: actions.refreshSessions)
        } else if !store.hooks.isReady {
            let stale = connection == .stale
            noticeRow(
                store.hooks.problem ?? store.hooks.listenerProblem
                    ?? (stale ? "Claude Code 连接已失效" : "连接 Claude Code 以接收会话提醒"),
                actionTitle: connection == .notConnected ? "连接" : "重试",
                action: actions.connectHooks
            )
        } else if let outdated = state.outdatedTerminal, let page = outdated.app.downloadPage {
            // New sessions cannot open and jumps lose the exact pane until it is updated.
            noticeRow(outdated.app.outdatedNote(outdated.version), actionTitle: "更新", symbol: "arrow.down.circle") {
                NSWorkspace.shared.open(page)
            }
        } else {
            switch store.notifier.permission {
            case .allowed, .unknown:
                if let release = store.updates.available {
                    noticeRow("AgentBell \(release.version) 已发布", actionTitle: "下载", symbol: "arrow.down.circle") {
                        NSWorkspace.shared.open(release.page)
                    }
                }
            case .notAsked:
                noticeRow("允许通知后可接收待确认和完成提醒", actionTitle: "允许通知") {
                    Task { await store.notifier.requestPermission() }
                }
            case .denied:
                noticeRow("通知已关闭", actionTitle: "打开系统设置") {
                    if let url = Notifier.settingsURL { NSWorkspace.shared.open(url) }
                }
            }
        }
    }

    private func noticeRow(
        _ message: String,
        actionTitle: String,
        symbol: String = "exclamationmark.circle",
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 7) {
            PanelSymbol(name: symbol)
            Text(message)
                .font(.rowDetail)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            Button(actionTitle, action: action).buttonStyle(.link).fixedSize()
        }
        .padding(10)
        .modifier(SessionGroupSurface())
        .padding([.horizontal, .top], BellLayout.inset)
    }

    func sessionScroll<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let rows = content()
        return ScrollViewReader { proxy in
            ScrollView { rows }
                .onAppear {
                    if let id = state.selectedID { proxy.scrollTo(id) }
                }
                .onChange(of: state.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
                .onChange(of: store.pinnedProjects) { previous, current in
                    guard (!showsSidebar || state.searchVisible),
                          let id = current.first, !previous.contains(id) else { return }
                    proxy.scrollTo(id, anchor: .top)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func listContent(now: Date) -> some View {
        let groups = PanelLayout.groups(store.liveSessions.filter { state.matches($0) }, pinned: store.pinnedProjects)
        let recent = store.tracker.recent.filter { state.matches($0) }
        return VStack(spacing: 10) {
            if groups.isEmpty && recent.isEmpty {
                emptySessions
            }
            ForEach(groups) { group in
                let expanded = state.isExpanded(group.id)
                VStack(spacing: 0) {
                    let pinned = store.pinnedProjects.contains(group.id)
                    ProjectPinRow(name: group.name, pinned: pinned,
                                  toggle: { store.toggleProjectPin(group.id) },
                                  newSession: { actions.launchInProject(group.id) },
                                  newReview: reviewAction(for: group.id),
                                  reveal: { actions.revealProject(group.id) }) { hovering in
                        let heading = projectHeading(group.name, root: group.id,
                                                     count: hovering ? nil : group.sessions.count,
                                                     expanded: state.searchVisible ? nil : expanded)
                        if state.searchVisible {
                            heading
                        } else {
                            Button { state.toggle(group.id) } label: { heading }
                                .buttonStyle(BellButtonStyle(hovers: false))
                                .accessibilityValue(expanded ? "已展开" : "已折叠")
                        }
                    }
                    if expanded {
                        CardDivider()
                        sessionRows(group.sessions, now: now)
                    }
                }
                .modifier(SessionGroupSurface())
                .id(group.id)
            }
            if !recent.isEmpty {
                historySection(recent, now: now, expanded: state.recentExpanded || state.searchVisible,
                               onToggle: state.searchVisible ? nil : { state.recentExpanded.toggle() })
                    .modifier(SessionGroupSurface())
            }
        }
        .frame(maxWidth: .infinity)
    }

    var emptySessions: some View {
        VStack(spacing: 8) {
            Image(systemName: state.isFiltering ? "magnifyingglass" : "terminal")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(state.isFiltering ? "没有匹配的会话" : "在终端运行 Claude Code 后，会话会显示在这里")
                .font(.rowDetail)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 128)
    }

    private func projectHeading(_ name: String, root: String, count: Int?, expanded: Bool?) -> some View {
        HStack(spacing: 8) {
            IconTile(symbol: "folder.fill", color: .project(root))
            Text(name).font(.groupName).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            if let count { CountBadge(count: count).accessibilityLabel("\(count) 个会话") }
            disclosure(expanded)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .contentShape(Rectangle())
        .help(name)
    }

    private func historyHeading(count: Int, expanded: Bool?) -> some View {
        HStack(spacing: 8) {
            PanelSymbol(name: "clock")
            Text("已关闭").font(.groupName)
            Spacer(minLength: 4)
            CountBadge(count: count).accessibilityLabel("\(count) 个会话")
            disclosure(expanded)
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .contentShape(Rectangle())
    }

    @ViewBuilder private func disclosure(_ expanded: Bool?) -> some View {
        if let expanded {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .frame(width: 16)
                .accessibilityHidden(true)
        }
    }

    func historySection(_ sessions: [Session], now: Date, expanded: Bool, onToggle: (() -> Void)?) -> some View {
        VStack(spacing: 0) {
            if let onToggle {
                Button(action: onToggle) {
                    historyHeading(count: sessions.count, expanded: expanded)
                }
                .buttonStyle(BellButtonStyle())
                .accessibilityValue(expanded ? "已展开" : "已折叠")
            } else {
                historyHeading(count: sessions.count, expanded: nil)
            }
            if expanded {
                CardDivider()
                sessionRows(sessions, now: now, compact: true)
            }
        }
    }

    func sessionRows(_ sessions: [Session], now: Date, compact: Bool = false,
                     showProject: Bool = false) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(sessions) { session in
                if session.id != sessions.first?.id {
                    CardDivider(leading: BellLayout.rowTextLeading)
                }
                row(session, now: now, compact: compact, showProject: showProject)
            }
        }
        .padding(.vertical, BellLayout.rowInset)
        // A row that changes place moves there, as UI_DESIGN.md §9 asks.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: sessions.map(\.id))
    }

    private func row(_ session: Session, now: Date, compact: Bool, showProject: Bool) -> some View {
        SessionRowView(
            session: session,
            now: now,
            showProject: showProject,
            compact: compact,
            wide: listWidth >= BellLayout.wideRowWidth,
            selected: state.selectionShown && state.selectedID == session.id,
            feedback: state.feedbackText(for: session.id),
            statusPending: store.tracker.isPendingClosure(session.id),
            onActivate: {
                state.selectedID = session.id
                actions.activate(session)
            },
            onCopy: { actions.copyResume(session) },
            onReveal: { actions.reveal(session) },
            onClose: session.isEnded ? nil : { state.closingID = session.id },
            onDetail: {
                state.selectedID = session.id
                state.detailID = session.id
            },
            // In the row while the list shows; the hidden list under a detail never edits.
            renaming: Binding(
                get: { state.renamingID == session.id && state.detailID == nil },
                set: {
                    if $0 { state.selectedID = session.id }
                    state.renamingID = $0 ? session.id : nil
                }
            ),
            onRename: { try store.rename(session, to: $0) },
            tasks: store.tasks,
            taskActions: actions.tasks
        )
        .id(session.id)
    }

    private func detail(_ session: Session) -> some View {
        let fallback = state.terminalFallback.flatMap { $0.sessionID == session.id ? $0 : nil }
        return ScrollView {
            TimelineView(.periodic(from: .now, by: 15)) { context in
                SessionDetailView(
                    session: session,
                    now: context.date,
                    feedback: state.feedbackText(for: session.id),
                    statusPending: store.tracker.isPendingClosure(session.id),
                    terminalUnavailable: fallback != nil && !session.isEnded,
                    openTerminalApp: fallback?.pid == nil ? nil : { actions.openTerminalApp(session) },
                    loadWorkspace: { cwd, force in await store.workspaceSnapshot(cwd: cwd, force: force) },
                    onActivate: { actions.activate(session) },
                    onCopy: { actions.copyResume(session) },
                    onReveal: { actions.reveal(session) },
                    onClose: session.isEnded ? nil : { state.closingID = session.id },
                    renaming: Binding(
                        get: { state.renamingID == session.id },
                        set: { state.renamingID = $0 ? session.id : nil }
                    ),
                    onRename: { try store.rename(session, to: $0) },
                    tasks: store.tasks,
                    taskActions: actions.tasks
                )
                .padding(.horizontal, BellLayout.inset + 6)
                .padding(.top, 12)
                .padding(.bottom, BellLayout.inset + 6)
            }
        }
        .id(session.id)
    }

    @ViewBuilder private var setup: some View {
        switch store.claude {
        case .locating:
            ProgressView("正在查找 Claude Code…").controlSize(.small)
        case .notFound:
            setupMessage("找不到 Claude Code", symbol: "terminal",
                         description: "请选择 Claude Code 的可执行文件。") {
                Button("选择文件…", action: actions.chooseClaude).buttonStyle(.bordered)
            }
        case .ready:
            if store.listFailed {
                setupMessage("无法读取会话", symbol: "exclamationmark.circle",
                             description: "请确认 Claude Code 支持 claude agents --json。") {
                    Button("重试", action: actions.refreshSessions).buttonStyle(.bordered)
                }
            } else {
                setupMessage("连接 Claude Code", symbol: "bell",
                             description: "连接后，AgentBell 可在会话需要确认、完成或出错时提醒你。") {
                    HStack {
                        Button("连接", action: actions.connectHooks).buttonStyle(.bordered)
                        Button("查看连接说明", action: actions.explainHooks).buttonStyle(.link)
                    }
                    if let problem = store.hooks.problem ?? store.hooks.listenerProblem {
                        Text(problem).font(.rowDetail).foregroundStyle(Color.bellRed)
                    }
                }
            }
        }
    }

    private func setupMessage<Actions: View>(_ title: String, symbol: String, description: String,
                                              @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(description).font(.rowDetail).foregroundStyle(.secondary)
            actions()
        }
        .multilineTextAlignment(.center)
        .padding(20)
        .frame(maxWidth: 340)
        .modifier(SessionGroupSurface())
        .padding(BellLayout.inset)
    }

    private var footer: some View {
        HStack {
            Button(action: actions.openSettings) {
                Label("设置…", systemImage: "gearshape")
                    .padding(.horizontal, 6)
                    .frame(height: BellLayout.controlHeight)
            }
            .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
            .help("设置（⌘,）")
            Spacer()
            Button(action: actions.quit) {
                Label("退出", systemImage: "power")
                    .padding(.horizontal, 6)
                    .frame(height: BellLayout.controlHeight)
            }
            .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
            .help("退出 AgentBell（⌘Q）")
        }
        .font(.rowDetail)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 40)
    }

    func toolButton(_ title: String, symbol: String, note: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: BellLayout.controlHeight, height: BellLayout.controlHeight)
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
        .accessibilityLabel(title)
        .help(note ?? title)
    }
}

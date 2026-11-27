import BellCore
import Foundation
import Observation

/// View state of the panel that is not session data: selection, the open detail, the
/// project picked in the sidebar, and the fold of closed sessions.
@MainActor
@Observable
final class PanelState {
    var isVisible = false
    /// The picked terminal when it is too old for AgentBell, with its version; checked
    /// each time the panel opens, so updating it clears the notice.
    var outdatedTerminal: (app: TerminalApp, version: String)?
    var selectedID: String?
    /// The selection is drawn only once the arrow keys moved it, as in a menu; until
    /// then it only tells ⌘C and ⌘I which row they act on.
    private(set) var selectionShown = false
    var recentExpanded = false
    private(set) var needsAttentionOnly = false
    var collapsedProjects: Set<String> = []
    private(set) var searchVisible = false
    private(set) var searchFocusRequest = 0
    private var selectionBeforeSearch: String?
    private var expandedSidebarHistory: Set<String> = []
    var query = ""
    /// The 开发任务 page shows instead of sessions.
    private(set) var tasksVisible = false
    /// The task open on that page. Where the page is too narrow for two columns, the
    /// detail shows only while this is set.
    var taskID: UUID?
    var taskQuery = ""
    /// The quick-add field above the task list.
    var addingTask = false
    /// Set by the page: one column, the list or a detail.
    var tasksNarrow = false
    /// Its title takes the focus when its detail shows.
    var taskToRename: UUID?
    /// The 代码审查 or 周报 page, shown instead of sessions.
    private(set) var reportPage: ReportPage?

    var isFiltering: Bool { !searchTerm.isEmpty }

    private var searchTerm: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func matches(_ session: Session) -> Bool {
        let term = searchTerm
        guard !term.isEmpty else { return true }
        return [session.title, session.project.name, session.project.branch].contains {
            $0?.localizedStandardContains(term) == true
        }
    }

    func isExpanded(_ project: String) -> Bool {
        searchVisible || !collapsedProjects.contains(project)
    }

    func toggle(_ project: String) {
        if collapsedProjects.remove(project) == nil {
            collapsedProjects.insert(project)
        }
    }

    func showSearch() {
        if searchVisible {
            searchFocusRequest &+= 1
            return
        }
        selectionBeforeSearch = selectedID
        tasksVisible = false
        reportPage = nil
        searchVisible = true
        selectedID = nil
    }

    func closeSearch() {
        guard searchVisible else { return }
        searchVisible = false
        query = ""
        selectedID = selectionBeforeSearch
        selectionBeforeSearch = nil
    }

    func canBrowse(_ store: SessionStore) -> Bool {
        guard case .ready = store.claude else { return false }
        return !store.liveSessions.isEmpty || !store.tracker.recent.isEmpty
            || (!store.listFailed && store.hooks.connection != .notConnected)
    }
    /// The session whose detail is showing instead of the list.
    var detailID: String?
    /// The session whose detail has its title open for editing.
    var renamingID: String?
    /// The session waiting for "关闭会话" to be confirmed.
    var closingID: String?
    var terminalFallback: (sessionID: String, pid: pid_t?)?
    /// The project the sidebar shows; the first one when nil or gone.
    var pickedProject: String?
    /// A row whose second line temporarily reads a message, like "已复制恢复命令".
    private(set) var feedback: (id: String, text: String)?

    @ObservationIgnored private var feedbackReset: Task<Void, Never>?

    func detailSession(_ store: SessionStore) -> Session? {
        guard let detailID else { return nil }
        return store.tracker.live[detailID] ?? store.tracker.recent.first { $0.id == detailID }
    }

    func attentionSessions(_ store: SessionStore) -> [Session] {
        let sessions = store.liveSessions.filter { $0.state == .waiting || $0.state == .failed }
        return PanelLayout.attentionOrder(sessions)
    }

    func showAttention(_ show: Bool, _ store: SessionStore) {
        detailID = nil
        closeSearch()
        tasksVisible = false
        reportPage = nil
        needsAttentionOnly = show
        selectFirst(store)
    }

    func showTasks(_ show: Bool) {
        detailID = nil
        closeSearch()
        needsAttentionOnly = false
        reportPage = nil
        tasksVisible = show
        addingTask = false
    }

    /// Opens 代码审查 or 周报, or with nil goes back to the sessions.
    func showReportPage(_ page: ReportPage?) {
        detailID = nil
        closeSearch()
        needsAttentionOnly = false
        tasksVisible = false
        reportPage = page
    }

    /// Opens one task, its title ready to edit when it was just made from a session.
    func openTask(_ id: UUID, focusTitle: Bool = false) {
        showTasks(true)
        taskQuery = ""
        taskID = id
        taskToRename = focusTitle ? id : nil
    }

    func projects(_ store: SessionStore) -> [ProjectEntry] {
        PanelLayout.projects(live: store.liveSessions, recent: store.tracker.recent, pinned: store.pinnedProjects)
    }

    func pickedEntry(_ store: SessionStore) -> ProjectEntry? {
        let projects = projects(store)
        return projects.first { $0.id == pickedProject } ?? projects.first
    }

    /// A project with nothing open shows its closed sessions without a click.
    func showsClosed(_ entry: ProjectEntry) -> Bool {
        entry.live.isEmpty || expandedSidebarHistory.contains(entry.id)
    }

    func toggleHistory(for project: String) {
        if expandedSidebarHistory.remove(project) == nil {
            expandedSidebarHistory.insert(project)
        }
    }

    func preserveSelection(afterSwitchTo style: PanelStyle, _ store: SessionStore) {
        guard !searchVisible, let selectedID,
              let session = store.tracker.live[selectedID] ?? store.tracker.recent.first(where: { $0.id == selectedID })
        else { return }
        switch style {
        case .list:
            if session.isEnded {
                recentExpanded = true
            } else {
                collapsedProjects.remove(session.project.root)
            }
        case .sidebar:
            pickedProject = session.project.root
            if session.isEnded { expandedSidebarHistory.insert(session.project.root) }
        }
    }

    /// Rows in display order, which is also keyboard order.
    func selectableSessions(_ store: SessionStore) -> [Session] {
        if tasksVisible || reportPage != nil { return [] }
        if searchVisible {
            return PanelLayout.groups(store.liveSessions.filter { matches($0) }, pinned: store.pinnedProjects).flatMap(\.sessions)
                + PanelLayout.listed(store.tracker.recent).filter { matches($0) }
        }
        if needsAttentionOnly { return attentionSessions(store) }
        switch PanelStyle.current {
        case .list:
            let live = PanelLayout.groups(store.liveSessions, pinned: store.pinnedProjects).filter { isExpanded($0.id) }.flatMap(\.sessions)
            return recentExpanded ? live + PanelLayout.listed(store.tracker.recent) : live
        case .sidebar:
            guard let entry = pickedEntry(store) else { return [] }
            return showsClosed(entry) ? entry.live + entry.closed : entry.live
        }
    }

    /// The panel opens on the list, on the project someone waits in, with focus on the
    /// first waiting session, otherwise the first row.
    func resetSelection(_ store: SessionStore) {
        detailID = nil
        terminalFallback = nil
        selectionShown = false
        closeSearch()
        tasksVisible = false
        reportPage = nil
        addingTask = false
        let projects = projects(store)
        if let waiting = projects.first(where: { $0.live.contains { $0.state == .waiting } }) {
            pickedProject = waiting.id
        } else if !projects.contains(where: { $0.id == pickedProject }) {
            pickedProject = projects.first?.id
        }
        selectFirst(store)
    }

    /// A click in the sidebar always lands on that project's sessions, also from a
    /// session's detail or from search.
    func pick(project: String, _ store: SessionStore) {
        detailID = nil
        closeSearch()
        needsAttentionOnly = false
        tasksVisible = false
        reportPage = nil
        pickedProject = project
        selectFirst(store)
    }

    /// ← and → in the sidebar.
    func moveProject(by offset: Int, _ store: SessionStore) {
        let projects = projects(store)
        guard let current = projects.firstIndex(where: { $0.id == pickedEntry(store)?.id }) else { return }
        let next = min(max(current + offset, 0), projects.count - 1)
        pick(project: projects[next].id, store)
    }

    private func selectFirst(_ store: SessionStore) {
        let rows = selectableSessions(store)
        selectedID = (rows.first { $0.state == .waiting && !$0.isEnded } ?? rows.first)?.id
    }

    func moveSelection(by offset: Int, _ store: SessionStore) {
        let rows = selectableSessions(store)
        guard !rows.isEmpty else { return }
        // The first press shows where the selection already is.
        if !selectionShown && rows.contains(where: { $0.id == selectedID }) {
            selectionShown = true
            return
        }
        selectionShown = true
        let current = rows.firstIndex { $0.id == selectedID }
        let next = current.map { min(max($0 + offset, 0), rows.count - 1) } ?? 0
        selectedID = rows[next].id
    }

    func feedbackText(for id: String) -> String? {
        feedback?.id == id ? feedback?.text : nil
    }

    func showFeedback(_ text: String, for id: String) {
        feedback = (id, text)
        feedbackReset?.cancel()
        feedbackReset = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            feedback = nil
        }
    }
}

/// The pages listing what AgentBell ran in the background; reading one is in its window.
enum ReportPage {
    case reviews
    case weekly

    var title: String {
        switch self {
        case .reviews: "代码审查"
        case .weekly: "周报"
        }
    }

    var symbol: String {
        switch self {
        case .reviews: "text.magnifyingglass"
        case .weekly: "calendar"
        }
    }

    /// What the page holds, for its button's help.
    var note: String {
        switch self {
        case .reviews: "代码审查：进行中的审查和已保存的报告"
        case .weekly: "周报：整理本周或上周的会话，写好的周报可以修改"
        }
    }
}

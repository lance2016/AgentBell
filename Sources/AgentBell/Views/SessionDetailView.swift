import AppKit
import BellCore
import SwiftUI

/// A session up close. On top, what it is, where it stands and the way back to it; under
/// that, an overview (latest round, tasks, workspace, session facts), the conversation,
/// and the workspace's changed files.
struct SessionDetailView: View {
    let session: Session
    let now: Date
    let feedback: String?
    let statusPending: Bool
    let terminalUnavailable: Bool
    let openTerminalApp: (() -> Void)?
    let loadWorkspace: (String, Bool) async -> GitSnapshot?
    let onActivate: () -> Void
    let onCopy: () -> Void
    let onReveal: () -> Void
    /// The title is open for editing, from the pencil beside it.
    @Binding var renaming: Bool
    let onRename: (String) throws -> Void
    let tasks: TaskStore
    let taskActions: TaskActions

    private enum GitState {
        case loading
        case loaded(GitSnapshot)
        case unavailable
    }

    private enum Tab: Hashable, CaseIterable {
        case overview, conversation, changes
    }

    @ViewState private var git = GitState.loading
    @ViewState private var conversationWindow: Transcript.ConversationWindow?
    @ViewState private var tab = Tab.overview
    @ViewState private var visibleRounds = Self.recentRounds
    @ViewState private var loadingConversation = false
    @ViewState private var conversationRequest = 0
    @ViewState private var workspaceRequest = 0
    @ViewState private var completedWorkspaceRequest = 0
    @ViewState private var completedConversationRequest = 0
    /// "已复制会话 ID" and the like, from the ··· menu.
    @ViewState private var copied: String?
    @Environment(\.colorScheme) private var colorScheme

    /// Conversation cards added on each load.
    private static let recentRounds = 6
    /// More than this and the list is a wall no one reads.
    private static let maxFiles = 200

    var body: some View {
        // The heading and its buttons read as one block, the tabs start the next.
        VStack(alignment: .leading, spacing: 0) {
            heading
            actionBar.padding(.top, 12)
            tabRow.padding(.top, 20)
            Group {
                switch tab {
                case .overview: overview
                case .conversation: conversation
                case .changes: workspaceChanges
                }
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: conversationKey) {
            guard tab == .conversation else { return }
            await loadConversation()
        }
        .task(id: workspaceKey) {
            guard tab != .conversation else { return }
            git = .loading
            let request = workspaceRequest
            let result = await loadWorkspace(session.cwd, request != completedWorkspaceRequest)
            guard !Task.isCancelled else { return }
            completedWorkspaceRequest = request
            git = result.map(GitState.loaded) ?? .unavailable
        }
    }

    private var conversationKey: String? {
        guard tab == .conversation else { return nil }
        return "\(session.cwd)|\(session.transcript?.modifiedAt.timeIntervalSinceReferenceDate ?? 0)|\(conversationRequest)"
    }

    private var workspaceKey: String? {
        guard tab != .conversation else { return nil }
        return "\(session.cwd)|\(session.stateSince.timeIntervalSinceReferenceDate)|\(workspaceRequest)"
    }

    private func loadConversation() async {
        loadingConversation = true
        let (id, cwd) = (session.id, session.cwd)
        let previous = conversationWindow
        let request = conversationRequest
        let loadEarlier = request != completedConversationRequest
        let read = await Task.detached(priority: .userInitiated) {
            Transcript.locate(sessionID: id, cwd: cwd).flatMap {
                Transcript.conversationWindow($0, previous: previous, loadEarlier: loadEarlier)
            }
        }.value
        guard !Task.isCancelled else { return }
        if let read { conversationWindow = read }
        completedConversationRequest = request
        loadingConversation = false
    }

    // MARK: - Heading

    private var heading: some View {
        let kind = LampKind(session)
        return VStack(alignment: .leading, spacing: 6) {
            if renaming {
                RenameField(title: session.title, size: .heading,
                            onSave: { try onRename($0); renaming = false },
                            onCancel: { renaming = false })
            } else {
                HStack(alignment: .center, spacing: 6) {
                    Text(session.title)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .accessibilityAddTraits(.isHeader)
                    RenameButton(title: session.title) { renaming = true }
                }
            }
            HStack(spacing: 6) {
                LampView(kind: kind)
                Text(statusPending ? "会话状态待确认" : Copy.statusWord(session))
                    .foregroundStyle(kind == .faint || kind == .interrupted ? Color.secondary : kind.color)
                    .fontWeight(.medium)
                Text("·").foregroundStyle(.tertiary)
                Text(now.relativeLabel(since: Copy.since(session)))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .lineLimit(1)
            if let note = statusNote {
                Text(note)
                    .font(.system(size: 13))
                    .foregroundStyle(kind == .waiting ? Color.amberText : .secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What it is doing, waiting for, or why it failed. Otherwise the standing line is
    /// the last reply, which 最近一轮 already shows in full.
    private var statusNote: String? {
        switch LampKind(session) {
        case .waiting, .working, .background, .failed:
            let standing = Copy.standing(session)
            return standing == Copy.statusWord(session) ? nil : standing
        case .completed, .interrupted, .faint:
            return nil
        }
    }

    // MARK: - Actions

    /// One way back to the session, then everything else in two menus.
    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                primaryButton
                taskMenu
                moreMenu
            }
            .controlSize(.large)
            .fixedSize()
            if terminalUnavailable {
                HStack(spacing: 4) {
                    Label(openTerminalApp == nil ? "找不到会话所在的终端" : "无法定位到会话窗口或分屏", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                    if let openTerminalApp {
                        quietButton("打开终端应用", action: openTerminalApp)
                    }
                }
                .font(.rowDetail)
            }
        }
    }

    /// Return presses it, except while renaming. A default button is drawn in the accent colour even when only
    /// bordered, so it is prominent with a neutral tint instead.
    private var primaryButton: some View {
        Button(session.isEnded ? "复制恢复命令" : "回到终端",
               systemImage: session.isEnded ? "doc.on.doc" : "terminal",
               action: session.isEnded ? onCopy : onActivate)
            .buttonStyle(.borderedProminent)
            .tint(.mainButton(colorScheme))
            // While the title is being edited, Return keeps the name instead.
            .keyboardShortcut(renaming ? nil : .defaultAction)
    }

    /// Takes this session's project, directory, branch and id into a new or open task.
    private var taskMenu: some View {
        Menu {
            TaskMenuItems(session: session, tasks: tasks, actions: taskActions)
        } label: {
            Label("加入任务", systemImage: "checklist")
        }
        .menuStyle(.button)
        // The pull-down arrow is a block in the accent colour, louder than the main button.
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .help("新建任务或加入已有任务")
    }

    /// Things to paste elsewhere and the folder: rarely needed, so out of the way.
    private var moreMenu: some View {
        Menu {
            if !session.isEnded {
                Button("复制恢复命令", systemImage: "doc.on.doc", action: onCopy)
            }
            Button("复制恢复命令（先进入目录）") {
                copy(session.resumeInDirectoryCommand, note: "已复制恢复命令（先进入目录）")
            }
            Divider()
            Button("复制会话 ID") { copy(session.id, note: "已复制会话 ID") }
            Button("复制目录路径") { copy(session.cwd, note: "已复制目录路径") }
            Divider()
            Button("在访达中显示", systemImage: "folder", action: onReveal)
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.bordered)
        .help("更多")
        .accessibilityLabel("更多操作")
    }

    /// A text action in secondary grey, for refresh-and-load-more kinds of things: the
    /// system's link style would paint them in the accent colour.
    private func quietButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.rowDetail)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .frame(height: 24)
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
    }

    private func copy(_ text: String, note: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = note
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == note { copied = nil }
        }
    }

    // MARK: - Tabs

    private var changedFiles: [GitSnapshot.FileChange]? {
        if case .loaded(let snapshot) = git { return snapshot.changes }
        return nil
    }

    private var tabPicker: some View {
        Picker("查看", selection: $tab) {
            ForEach(Tab.allCases, id: \.self) { item in
                Text(title(item)).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.large)
        .fixedSize()
    }

    /// The tabs, and at their right the note for a copy or a link: the room there is
    /// free at any width, and nothing moves when the note comes and goes.
    private var tabRow: some View {
        HStack(spacing: 8) {
            tabPicker
            Spacer(minLength: 8)
            if let note = feedback ?? copied {
                Label(note, systemImage: "checkmark")
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(note)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
    }

    private func title(_ item: Tab) -> String {
        switch item {
        case .overview: return "概览"
        case .conversation: return "对话"
        case .changes: return "改动"
        }
    }

    // MARK: - Overview

    @ViewBuilder private var overview: some View {
        VStack(spacing: 12) {
            latestRound
            tasksCard
            workspaceCard
            sessionCard
        }
    }

    /// The newest round: what you asked, and Claude's answer. Where the session stands is
    /// in the heading, so the answer sits on a neutral fill.
    private var latestRound: some View {
        let turn = rounds.first
        return DetailCard(title: "最近一轮", trailing: turn?.at.map { SessionDetailView.clock($0, now: now) }) {
            if let turn {
                VStack(alignment: .leading, spacing: 10) {
                    (Text("你：").foregroundStyle(.tertiary) + Text(turn.prompt))
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    answer(turn)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                CardDivider(leading: 14)
                linkRow("查看全部对话") { tab = .conversation }
            } else {
                placeholder("还没有对话记录")
            }
        }
    }

    private func answer(_ turn: ConversationTurn) -> some View {
        Group {
            if turn.reply.isEmpty {
                Text("Claude 还没有回复").foregroundStyle(.secondary)
            } else {
                Text(TurnCard.markdown(turn.reply))
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: 13))
        .lineSpacing(2)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// The tasks this session is in, so that shows without opening 加入任务.
    private var tasksCard: some View {
        let linked = tasks.tasks(containing: session.id)
        return DetailCard(title: "开发任务") {
            if linked.isEmpty {
                placeholder("还没有加入任务")
            } else {
                ForEach(Array(linked.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { CardDivider(leading: 14) }
                    taskRow(task)
                }
            }
        }
    }

    private func taskRow(_ task: DevTask) -> some View {
        Button { taskActions.open(task.id) } label: {
            HStack(spacing: 8) {
                Text(task.title.isEmpty ? "未命名任务" : task.title)
                    .lineLimit(1)
                Spacer(minLength: 12)
                Text(task.status.title).foregroundStyle(.secondary).fixedSize()
                chevron
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("打开任务")
    }

    /// Where the session works: which checkout, on which branch, and what is uncommitted.
    private var workspaceCard: some View {
        DetailCard(title: "工作区") {
            if let checkout = checkoutLabel {
                infoRow("位置") {
                    Text(checkout).help("主仓库在 \(session.project.root)")
                }
                CardDivider(leading: 14)
            }
            infoRow("目录") {
                Text((session.cwd as NSString).abbreviatingWithTildeInPath)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                    .help(session.cwd)
            }
            gitRows
        }
    }

    /// A linked worktree, or the repository's own checkout; nil outside a repository.
    private var checkoutLabel: String? {
        if session.project.worktree != nil { return "worktree" }
        return session.project.branch == nil ? nil : "主仓库"
    }

    /// The count opens 改动, where the files are.
    private func changesRow(_ count: Int) -> some View {
        Button { tab = .changes } label: {
            HStack(spacing: 8) {
                Text("改动").foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 12)
                Text(count == 0 ? "没有未提交的改动" : "\(count) 个文件")
                    .foregroundStyle(count == 0 ? .secondary : .primary)
                    .monospacedDigit()
                chevron
            }
            .font(.system(size: 13))
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("查看改动的文件")
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    private func linkRow(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .accessibilityHidden(true)
            }
            .font(.rowDetail)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Conversation

    /// Newest first. Before the transcript is read, or when it has none, the rounds the
    /// tracker heard will do.
    private var rounds: ReversedCollection<[ConversationTurn]> {
        if tab == .conversation, let turns = conversationWindow?.turns, !turns.isEmpty { return turns.reversed() }
        return session.recentTurns.map {
            ConversationTurn(prompt: $0.prompt ?? "没有记录这轮提问", reply: $0.reply ?? "", at: $0.at)
        }.reversed()
    }

    /// Where the newest round stands, when that says more than its reply: what it is
    /// doing, what it waits for, or why it failed.
    private var standing: TurnCard.Standing? {
        let kind = LampKind(session)
        switch kind {
        case .faint: return nil
        case .completed: return TurnCard.Standing(kind: kind, text: nil)
        case .waiting, .working, .background, .failed, .interrupted:
            return TurnCard.Standing(kind: kind, text: Copy.standing(session))
        }
    }

    private var conversation: some View {
        let rounds = rounds
        let shown = Array(rounds.prefix(visibleRounds))
        return LazyVStack(alignment: .leading, spacing: 8) {
            if rounds.isEmpty {
                Group {
                    if loadingConversation {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(conversationWindow?.hasEarlier == true ? "这段记录里没有对话" : "还没有对话记录")
                            .font(.rowDetail).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 56)
                .modifier(SessionGroupSurface())
            }
            let entries = shown.enumerated().map { index, turn in
                (id: turn.sourceOffset.map { "offset-\($0)" } ?? "summary-\(index)", turn: turn, newest: index == 0)
            }
            ForEach(entries, id: \.id) { entry in
                TurnCard(turn: entry.turn, now: now, standing: entry.newest ? standing : nil)
            }
            if shown.count < rounds.count || conversationWindow?.hasEarlier == true {
                quietButton(loadingConversation ? "正在读取…" : "加载更早的对话") {
                    visibleRounds += Self.recentRounds
                    if visibleRounds > rounds.count, conversationWindow?.hasEarlier == true {
                        conversationRequest += 1
                    }
                }
                .disabled(loadingConversation)
            }
        }
    }

    // MARK: - Changes

    private var workspaceChanges: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(session.cwd)
                    .font(.rowDetail).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .help(session.cwd)
                Spacer()
                if case .loaded(let snapshot) = git {
                    BranchTag(branch: snapshot.branch ?? "游离 HEAD")
                        .frame(maxWidth: 130, alignment: .trailing)
                }
                quietButton("刷新") { workspaceRequest += 1 }
            }
            changesCard
        }
    }

    private var changesCard: some View {
        let files = changedFiles ?? []
        return DetailCard(title: "改动文件", count: files.isEmpty ? nil : files.count) {
            switch git {
            case .loading:
                placeholder("正在读取…")
            case .unavailable:
                placeholder("无法读取工作区改动")
            case .loaded:
                if files.isEmpty {
                    placeholder("没有未提交的改动")
                } else {
                    ForEach(Array(files.prefix(Self.maxFiles).enumerated()), id: \.offset) { index, file in
                        if index > 0 { CardDivider(leading: 38) }
                        fileRow(file)
                    }
                    if files.count > Self.maxFiles {
                        CardDivider(leading: 14)
                        placeholder("还有 \(files.count - Self.maxFiles) 个文件")
                    }
                }
            }
        }
    }

    private func fileRow(_ file: GitSnapshot.FileChange) -> some View {
        let (letter, label, color) = Self.badge(file.kind)
        let name = (file.path as NSString).lastPathComponent
        let folder = (file.path as NSString).deletingLastPathComponent
        return HStack(spacing: 8) {
            Text(letter)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .frame(width: 16)
                .accessibilityLabel(label)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1).truncationMode(.middle)
                if !folder.isEmpty {
                    Text(folder).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 4)
            if let added = file.added, let deleted = file.deleted {
                HStack(spacing: 4) {
                    Text("+\(added)").foregroundStyle(Color.greenLamp)
                    Text("−\(deleted)").foregroundStyle(Color.bellRed)
                }
                .font(.system(size: 11).monospacedDigit())
                .fixedSize()
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(minHeight: 34)
        .help(file.path)
        .accessibilityElement(children: .combine)
    }

    private static func badge(_ kind: GitSnapshot.FileChange.Kind) -> (String, String, Color) {
        switch kind {
        case .modified: ("M", "已修改", .amberText)
        case .added: ("A", "新增", .greenLamp)
        case .deleted: ("D", "已删除", .bellRed)
        case .renamed: ("R", "已重命名", .blueLamp)
        case .conflicted: ("U", "有冲突", .bellRed)
        case .untracked: ("?", "未跟踪", .secondary)
        }
    }

    // MARK: - Session facts

    private var sessionCard: some View {
        DetailCard(title: "会话信息") {
            infoRow("会话 ID") {
                Text(session.id)
                    .font(.system(size: 12).monospacedDigit())
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(session.id)
            }
            CardDivider(leading: 14)
            infoRow("开始于") {
                Text(Self.clock(session.startedAt, now: now))
            }
            CardDivider(leading: 14)
            infoRow("时长") {
                Text(Copy.roundLength((session.endedAt ?? now).timeIntervalSince(session.startedAt)))
            }
        }
    }

    @ViewBuilder private var gitRows: some View {
        CardDivider(leading: 14)
        switch git {
        case .loading:
            infoRow("分支") { Text(session.project.branch ?? "正在读取…") }
        case .unavailable:
            infoRow("分支") { Text(session.project.branch ?? "无法读取").foregroundStyle(.secondary) }
        case .loaded(let snapshot):
            infoRow("分支") {
                if let sync = Self.syncLabel(snapshot) {
                    Text(sync).foregroundStyle(.secondary).monospacedDigit()
                }
                Text(snapshot.branch ?? "游离 HEAD").truncationMode(.middle)
            }
            CardDivider(leading: 14)
            changesRow(snapshot.changes.count)
            if let commit = snapshot.lastCommit {
                CardDivider(leading: 14)
                infoRow("最近提交") {
                    Text(commit.subject).truncationMode(.tail).help(commit.subject)
                }
            }
        }
    }

    /// "↑2 ↓1" against the upstream; nil when in step or there is none.
    private static func syncLabel(_ snapshot: GitSnapshot) -> String? {
        guard snapshot.upstream != nil else { return nil }
        let parts = [snapshot.ahead > 0 ? "↑\(snapshot.ahead)" : nil, snapshot.behind > 0 ? "↓\(snapshot.behind)" : nil]
        let text = parts.compactMap { $0 }.joined(separator: " ")
        return text.isEmpty ? nil : text
    }

    /// "今天 14:32" or "11月25日 14:32".
    fileprivate static func clock(_ date: Date, now: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "今天 \(time)" }
        return "\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日 \(time)"
    }

    /// Key on the left, value on the right.
    private func infoRow<Value: View>(_ title: String, @ViewBuilder value: () -> Value) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 12)
            HStack(spacing: 6) { value() }.lineLimit(1)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(minHeight: 34)
        .accessibilityElement(children: .combine)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.rowDetail)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A white card with its title inside, an optional count beside it and a note at the
/// right, such as the time of the round it shows.
private struct DetailCard<Content: View>: View {
    let title: String
    var count: Int?
    var trailing: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title).font(.groupName)
                if let count {
                    Text("\(count)").font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing).font(.rowTime).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 42)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SessionGroupSurface())
    }
}

/// One round, a card of its own: what you asked, when, and how it came out in a line or
/// two. The whole question and Claude's closing answer open in place on request.
private struct TurnCard: View {
    /// Where the session stands, shown on its newest round only.
    struct Standing {
        let kind: LampKind
        /// Nil when the reply itself is the news.
        let text: String?
    }

    let turn: ConversationTurn
    let now: Date
    let standing: Standing?

    @ViewState private var expanded = false

    private static let promptLines = 3

    /// The reply in a line: past a short heading, without Markdown marks.
    private var outcome: String? {
        standing?.text ?? Transcript.replyLine(turn.reply)
    }

    /// A cheap guess at whether there is more than the card shows; the button costs
    /// little if wrong.
    private var hasMore: Bool {
        turn.prompt.count > 110 || turn.prompt.contains("\n")
            || turn.reply.count > 120 || turn.reply.contains("\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(turn.prompt)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(expanded ? nil : Self.promptLines)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                if let at = turn.at {
                    Text(SessionDetailView.clock(at, now: now))
                        .font(.rowTime)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                disclosure
            }
            if let outcome, !expanded || standing?.text != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let standing {
                        LampView(kind: standing.kind).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                    }
                    Text(outcome)
                        .font(.rowDetail)
                        .foregroundStyle(standing?.kind == .waiting ? Color.amberText : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if expanded && !turn.reply.isEmpty {
                Text(Self.markdown(turn.reply))
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(SessionGroupSurface())
    }

    /// Opens the whole question and answer in place. Its room is kept on a card with
    /// nothing more to show, so the times line up down the page.
    private var disclosure: some View {
        Button { expanded.toggle() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(expanded ? 180 : 0))
                // No taller than a line of the question, or a one-line card grows a gap.
                .frame(width: 22, height: 16)
        }
        .buttonStyle(BellButtonStyle(radius: 8))
        .help(expanded ? "收起" : "展开全文")
        .accessibilityLabel(expanded ? "收起这一轮" : "展开这一轮的全文")
        .opacity(hasMore ? 1 : 0)
        .disabled(!hasMore)
        .accessibilityHidden(!hasMore)
        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
    }

    /// Bold, code and links render; block syntax such as headings stays as typed.
    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}


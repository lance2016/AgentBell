import BellCore
import SwiftUI

/// One session. A click does the one thing you came for: back to its terminal, or, once
/// the session has ended, copy `claude --resume`. The pencil renames it in place and the
/// trailing button opens the detail; everything else lives in the context menu.
struct SessionRowView: View {
    let session: Session
    let now: Date
    let showProject: Bool
    let compact: Bool
    /// The list has room for the question and where it stands, each on its own line.
    let wide: Bool
    let selected: Bool
    let feedback: String?
    let statusPending: Bool
    let onActivate: () -> Void
    let onCopy: () -> Void
    let onReveal: () -> Void
    /// Nil once the session has ended: there is no process left to close.
    let onClose: (() -> Void)?
    let onDetail: () -> Void
    /// The name is open for editing in the row.
    @Binding var renaming: Bool
    let onRename: (String) throws -> Void
    let tasks: TaskStore
    let taskActions: TaskActions

    @ViewState private var hovered = false

    private var kind: LampKind { LampKind(session) }

    private var primaryTitle: String { session.isEnded ? "复制恢复命令" : "回到终端" }

    /// The unfinished task this session was added to, if any: the row's one real tag.
    private var task: DevTask? {
        compact ? nil : tasks.tasks(containing: session.id).first { $0.status != .done }
    }

    private var review: ReviewCheckout? { session.project.review }

    /// A review's checkout is a detached commit: what it compares says more.
    private var branch: String? { review == nil ? session.project.branch : review?.range }

    /// A worktree of the user's own; a review's checkout is told by its icon instead.
    private var worktreeName: String? {
        guard review == nil, let worktree = session.project.worktree else { return nil }
        return (worktree as NSString).lastPathComponent
    }

    private var weekly: WeeklyCheckout? { session.project.weekly }

    /// The icon is hidden from VoiceOver, so the kind of session is said here.
    private var kindDescription: String? {
        if let weekly { return weekly.title }
        guard review != nil else { return branch.map { "分支 \($0)" } }
        return review?.range.map { "代码审查 \($0)" } ?? "代码审查"
    }

    private var accessibilityValue: String {
        let parts: [String?] = [
            statusPending ? "会话状态待确认" : nil,
            kindDescription,
            worktreeName.map { "worktree \($0)" },
            task.map { "任务 \($0.title)" }
        ]
        return parts.compactMap { $0 }.joined(separator: "，")
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BellLayout.rowRadius + 2, style: .continuous)
        HStack(alignment: .top, spacing: 0) {
            if renaming {
                // Not inside the row's button: clicks in the field must not go to the terminal.
                rowContent {
                    RenameField(title: session.title, size: .row,
                                onSave: { try onRename($0); renaming = false },
                                onCancel: { renaming = false })
                }
                .padding(.trailing, 6)
            } else {
                Button(action: onActivate) {
                    rowContent {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let kind = review != nil ? ("text.magnifyingglass", "代码审查")
                                : weekly != nil ? ("calendar", "周报") : nil {
                                // A kind of session, not a state: quiet beside the lamp.
                                Image(systemName: kind.0)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                    .padding(.trailing, -4)
                                    .help(kind.1)
                                    .accessibilityHidden(true)
                            }
                            Text(session.title)
                                .font(session.isEnded ? .rowTitle : .sessionTitle)
                                .foregroundStyle(session.isEnded ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(now.relativeLabel(since: Copy.since(session)))
                                .font(.rowTime)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(primaryTitle)
                .accessibilityLabel(Copy.accessibilityLabel(session, now: now))
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityHint(primaryTitle)
                .accessibilityValue(accessibilityValue)
                .accessibilityAction(named: "查看详情", onDetail)
                .accessibilityAction(named: "复制恢复命令", onCopy)
                .accessibilityAction(named: "在访达中显示", onReveal)
                .accessibilityAction(named: "重命名") { renaming = true }
                .accessibilityActions {
                    if let onClose { Button("关闭会话", action: onClose) }
                }

                // Both level with the title, however many lines stand under it.
                RenameButton(title: session.title) { renaming = true }
                    .padding(.leading, 4)
                    .padding(.top, compact ? 4 : 6)
                // Faint until the row is pointed at or picked, so the lamp stays the loudest thing.
                Button(action: onDetail) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 13))
                        .foregroundStyle(hovered || selected ? .secondary : .tertiary)
                        .frame(width: BellLayout.inlineControlSize, height: BellLayout.inlineControlSize)
                }
                .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
                .padding(.horizontal, 6)
                .padding(.top, compact ? 4 : 6)
                .help("查看详情（⌘I）")
                .accessibilityLabel("查看详情：\(session.title)")
                if let onClose {
                    // Shown on the row being pointed at or picked, so a stray click near
                    // the details button does not end a session. It still asks first.
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .frame(width: BellLayout.inlineControlSize, height: BellLayout.inlineControlSize)
                    }
                    .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
                    .padding(.trailing, 6)
                    .padding(.top, compact ? 4 : 6)
                    .opacity(hovered || selected ? 1 : 0)
                    .allowsHitTesting(hovered || selected)
                    .help("关闭会话")
                    .accessibilityHidden(true)
                }
            }
        }
        .background(selected ? BellLayout.selectionFill : hovered ? BellLayout.controlFill : .clear, in: shape)
        .background(kind == .waiting ? BellLayout.waitingFill : .clear, in: shape)
        .padding(.horizontal, BellLayout.rowInset)
        .onHover { hovered = $0 }
        .contextMenu {
            SessionCommands(onDetail: onDetail, onActivate: session.isEnded ? nil : onActivate,
                            onCopy: onCopy, onReveal: onReveal, onRename: { renaming = true },
                            onClose: onClose)
            Menu("加入任务", systemImage: "checklist") {
                TaskMenuItems(session: session, tasks: tasks, actions: taskActions)
            }
        }
    }

    /// Lamp, then the title line, summary and meta. The field is 6 pt taller than the
    /// title, so the padding gives those back and the row keeps its height while renaming.
    private func rowContent<Title: View>(@ViewBuilder title: () -> Title) -> some View {
        let padding: CGFloat = (compact ? 8 : 10) - (renaming ? 3 : 0)
        return HStack(alignment: .top, spacing: BellLayout.rowGap) {
            // Centred on the title's line, whatever stands under it.
            LampView(kind: kind).padding(.top, renaming ? 5 : 2)
            VStack(alignment: .leading, spacing: 3) {
                title()
                summary
                meta
            }
        }
        .padding(.leading, BellLayout.rowLeading)
        .padding(.vertical, padding)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// Under the title, one line: how the latest round stands, or what was asked when
    /// that says more. A closed session keeps to its name; its last round is old news.
    @ViewBuilder private var summary: some View {
        if let feedback {
            Label(feedback, systemImage: "checkmark")
                .labelStyle(TightLabelStyle())
                .font(.rowDetail)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if statusPending {
            Text("会话状态待确认")
                .font(.rowDetail)
                .foregroundStyle(.secondary)
        } else if !compact {
            let lines = wide ? Copy.summaryLines(session) : [Copy.summary(session)]
            ForEach(lines.indices, id: \.self) { index in
                let line = lines[index]
                Group {
                    if line.asked {
                        Text("你：").foregroundStyle(.tertiary) + Text(line.text)
                    } else {
                        Text(line.text)
                    }
                }
                .font(.rowDetail)
                // The question stays quiet; only what it waits for takes the amber.
                .foregroundStyle(kind == .waiting && !line.asked ? Color.amberText : .secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
    }

    /// Project, branch, worktree and task, each only when there is one; no line at all
    /// otherwise. Closed rows keep to their name.
    @ViewBuilder private var meta: some View {
        let project = showProject ? session.project.name : nil
        if !compact, project != nil || branch != nil || worktreeName != nil || task != nil {
            HStack(spacing: 6) {
                if let project {
                    MetaChip(text: project, symbol: "folder")
                }
                if let branch {
                    MetaChip(text: branch, symbol: "arrow.triangle.branch", monospaced: true)
                        .layoutPriority(1)
                }
                if let worktreeName {
                    MetaChip(text: "worktree \(worktreeName)", symbol: "rectangle.stack")
                }
                if let task {
                    MetaChip(text: task.title, symbol: "checklist", tint: .bellAccent)
                }
            }
            .padding(.top, 2)
            .accessibilityHidden(true)
        }
    }
}

/// A small tag in the row's meta line. Neutral unless it is the task, the one tag in the
/// accent; never the lamps' colours.
private struct MetaChip: View {
    let text: String
    let symbol: String
    var tint: Color?
    var monospaced = false

    var body: some View {
        Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: symbol).font(.system(size: 9.5))
        }
        .labelStyle(TightLabelStyle())
        .font(monospaced ? .system(size: 11, design: .monospaced) : .rowMeta)
        .foregroundStyle(tint ?? .secondary)
        .padding(.horizontal, 6)
        .frame(height: 18)
        .background((tint ?? .primary).opacity(tint == nil ? 0.05 : 0.1),
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .help(text)
    }
}

struct SessionCommands: View {
    var onDetail: (() -> Void)? = nil
    var onActivate: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    let onReveal: () -> Void
    var onRename: (() -> Void)? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        if let onActivate {
            Button("回到终端", systemImage: "terminal", action: onActivate)
        }
        if let onCopy {
            Button("复制恢复命令", systemImage: "doc.on.doc", action: onCopy)
        }
        Button("在访达中显示", systemImage: "folder", action: onReveal)
        if let onRename {
            Button("重命名…", systemImage: "pencil", action: onRename)
        }
        if let onDetail {
            Divider()
            Button("查看详情", systemImage: "info.circle", action: onDetail)
        }
        if let onClose {
            Divider()
            Button("关闭会话…", systemImage: "xmark.circle", role: .destructive, action: onClose)
        }
    }
}

extension Date {
    /// "刚刚", "5 分钟前", "2 小时前", "3 天前": how long ago, as the rows show it.
    func relativeLabel(since earlier: Date) -> String {
        let minutes = Int(max(timeIntervalSince(earlier), 0) / 60)
        if minutes < 1 { return "刚刚" }
        if minutes < 60 { return "\(minutes) 分钟前" }
        if minutes < 24 * 60 { return "\(minutes / 60) 小时前" }
        return "\(minutes / (24 * 60)) 天前"
    }
}

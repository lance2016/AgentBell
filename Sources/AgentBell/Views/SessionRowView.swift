import BellCore
import SwiftUI

/// One session. A click does the one thing you came for: back to its terminal, or, once
/// the session has ended, copy `claude --resume`. The trailing button opens the detail;
/// everything else lives in the context menu.
struct SessionRowView: View {
    let session: Session
    let now: Date
    let rowBranch: String?
    let showProject: Bool
    let compact: Bool
    /// Another open session works in the same directory.
    let sharesDirectory: Bool
    let selected: Bool
    let feedback: String?
    let statusPending: Bool
    let onActivate: () -> Void
    let onCopy: () -> Void
    let onReveal: () -> Void
    let onDetail: () -> Void
    let tasks: TaskStore
    let taskActions: TaskActions

    @ViewState private var hovered = false

    private var kind: LampKind { LampKind(session) }

    private var primaryTitle: String { session.isEnded ? "复制恢复命令" : "回到终端" }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BellLayout.rowRadius + 2, style: .continuous)
        HStack(alignment: .center, spacing: 0) {
            Button(action: onActivate) {
                HStack(alignment: .top, spacing: BellLayout.rowGap) {
                    // Centred on the title's line, whatever stands under it.
                    LampView(kind: kind).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(session.title)
                                .font(.rowTitle)
                                .foregroundStyle(session.isEnded ? .secondary : .primary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if sharesDirectory {
                                Text("同目录")
                                    .font(.rowDetail)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .fixedSize()
                                    .help("另一个会话也在这个目录里工作，改动可能互相覆盖。分开做可以从「新建会话」选别的 worktree")
                            }
                            if showProject {
                                Text(session.project.name)
                                    .font(.rowDetail)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 100)
                            } else if let rowBranch {
                                BranchTag(branch: rowBranch)
                                    .frame(maxWidth: 72, alignment: .trailing)
                            }
                            Text(now.relativeLabel(since: Copy.since(session)))
                                .font(.rowTime)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        lines
                    }
                }
                .padding(.leading, BellLayout.rowLeading)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(primaryTitle)
            .accessibilityLabel(Copy.accessibilityLabel(session, now: now))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityHint(primaryTitle)
            .accessibilityValue(statusPending ? "会话状态待确认" : sharesDirectory ? "和另一个会话在同一目录" : "")
            .accessibilityAction(named: "查看详情", onDetail)
            .accessibilityAction(named: "复制恢复命令", onCopy)
            .accessibilityAction(named: "在访达中显示", onReveal)

            // Faint until the row is pointed at or picked, so the lamp stays the loudest thing.
            Button(action: onDetail) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(hovered || selected ? .secondary : .tertiary)
                    .frame(width: BellLayout.inlineControlSize, height: BellLayout.inlineControlSize)
            }
            .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
            .padding(.horizontal, 6)
            .help("查看详情（⌘I）")
            .accessibilityLabel("查看详情：\(session.title)")
        }
        .background(selected ? BellLayout.selectionFill : hovered ? BellLayout.controlFill : .clear, in: shape)
        .background(kind == .waiting ? BellLayout.waitingFill : .clear, in: shape)
        .padding(.horizontal, BellLayout.rowInset)
        .onHover { hovered = $0 }
        .contextMenu {
            SessionCommands(onDetail: onDetail, onActivate: session.isEnded ? nil : onActivate,
                            onCopy: onCopy, onReveal: onReveal)
            Menu("加入任务", systemImage: "checklist") {
                TaskMenuItems(session: session, tasks: tasks, actions: taskActions)
            }
        }
    }

    /// Under the title: what was asked, then where that stands. A closed session keeps
    /// to its name; its last round is old news.
    @ViewBuilder private var lines: some View {
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
            if let asked = Copy.asked(session) {
                (Text("你：").foregroundStyle(.tertiary) + Text(asked))
                    .font(.rowDetail)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(Copy.standing(session))
                .font(.rowDetail)
                .foregroundStyle(kind == .waiting ? Color.amberText : .secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SessionCommands: View {
    var onDetail: (() -> Void)? = nil
    var onActivate: (() -> Void)? = nil
    var onCopy: (() -> Void)? = nil
    let onReveal: () -> Void

    var body: some View {
        if let onActivate {
            Button("回到终端", systemImage: "terminal", action: onActivate)
        }
        if let onCopy {
            Button("复制恢复命令", systemImage: "doc.on.doc", action: onCopy)
        }
        Button("在访达中显示", systemImage: "folder", action: onReveal)
        if let onDetail {
            Divider()
            Button("查看详情", systemImage: "info.circle", action: onDetail)
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

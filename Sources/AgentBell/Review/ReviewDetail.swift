import AppKit
import BellCore
import SwiftUI

/// What can be done with a saved review, from its page, the toolbar or the list's menu.
@MainActor
enum ReviewActions {
    static func open(_ record: ReviewRecord) {
        NSWorkspace.shared.open(record.reportURL)
    }

    static func reveal(_ record: ReviewRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([record.reportURL])
    }

    /// Copies the report as it is on disk, edits made elsewhere included.
    static func copy(_ record: ReviewRecord, from archive: ReviewArchive) -> Bool {
        guard let report = archive.report(record) else { return false }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setString(report, forType: .string)
    }

    /// The checkout the session ran in is pruned after a few days.
    static func canResume(_ record: ReviewRecord) -> Bool {
        record.sessionID != nil && FileManager.default.fileExists(atPath: record.checkout)
    }

    /// Opens the review's own session in the terminal, in the checkout it ran in.
    static func resume(_ record: ReviewRecord, store: SessionStore) {
        guard let sessionID = record.sessionID, canResume(record) else { return }
        guard case .ready(let executable) = store.claude else {
            alert("找不到 Claude Code", "请先在 AgentBell 通用设置选择可用的 Claude。")
            return
        }
        Task {
            do {
                try await TerminalJumper.launchClaude(
                    in: .current, executable: executable, directory: record.checkout, resumeSessionID: sessionID
                ) {}
                store.pollNow()
            } catch {
                alert("无法在终端继续", error.localizedDescription)
            }
        }
    }

    static func elapsed(since start: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// A review still running, or one that failed in this run.
struct JobDetail: View {
    let job: ReviewStore.Job
    let reviews: ReviewStore

    @ViewState private var confirmingStop = false

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            switch job.stage {
            case .preparing, .reviewing:
                ProgressView().controlSize(.large)
                TimelineView(.periodic(from: job.startedAt, by: 1)) { context in
                    Text("\(job.stage == .preparing ? "正在拉取审查范围" : "Claude 正在审查")（\(ReviewActions.elapsed(since: job.startedAt, now: context.date))）")
                        .font(.title3)
                }
                Text("可以关闭窗口或开始其他审查，完成后会通知你。")
                    .foregroundStyle(.secondary)
                Button("停止审查") { confirmingStop = true }
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                Text("审查失败").font(.title3)
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
                    .frame(maxWidth: 440)
                HStack {
                    Button("移除") { reviews.delete([job.id]) }
                    Button("重试") { reviews.retry(job.id) }
                        .buttonStyle(.borderedProminent)
                }
            }
            Spacer()
            summary
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(job.repositoryName)
        .navigationSubtitle(job.range ?? "")
        .confirmationDialog("停止这次审查？", isPresented: $confirmingStop) {
            Button("停止审查", role: .destructive) { reviews.cancel(job.id) }
        } message: {
            Text("已经花掉的用量不会退回，也不会保存报告。")
        }
    }

    private var summary: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            GridRow { Text("仓库").foregroundStyle(.secondary); Text(job.directory.path).textSelection(.enabled) }
            if let plan = job.plan {
                GridRow { Text("范围").foregroundStyle(.secondary); Text("\(plan.sourceBranch) → \(plan.targetBranch)") }
                GridRow { Text("源提交").foregroundStyle(.secondary); Text(String(plan.head.prefix(12))).monospaced() }
            }
            GridRow { Text("模型").foregroundStyle(.secondary); Text(job.model.title) }
            if !job.focus.isEmpty {
                GridRow { Text("关注点").foregroundStyle(.secondary); Text(job.focus) }
            }
        }
        .font(.callout)
    }
}

/// A saved report, read from its file each time it is shown.
struct ReportDetail: View {
    let record: ReviewRecord
    let archive: ReviewArchive
    let store: SessionStore
    let delete: () -> Void

    @ViewState private var report: String?
    @ViewState private var loaded = false
    @ViewState private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()
                if let report {
                    MarkdownReport(report)
                } else if loaded {
                    ContentUnavailableView("找不到报告文件", systemImage: "doc.questionmark",
                                           description: Text(record.reportURL.path))
                }
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(record.repositoryName)
        .navigationSubtitle(record.range)
        .task(id: record.id) {
            copied = false
            report = archive.report(record)
            loaded = true
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    copied = ReviewActions.copy(record, from: archive)
                } label: {
                    Label(copied ? "已复制" : "复制报告", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .help("复制报告的 Markdown 内容")
                Button { ReviewActions.reveal(record) } label: { Label("在访达中显示", systemImage: "folder") }
                    .help("在访达中显示 report.md")
                Button { ReviewActions.open(record) } label: { Label("用默认应用打开", systemImage: "arrow.up.forward.app") }
                    .help("用默认应用打开 report.md，可以在那里编辑")
                Button { ReviewActions.resume(record, store: store) } label: { Label("在终端继续", systemImage: "terminal") }
                    .help(ReviewActions.canResume(record)
                          ? "在终端里接着这次审查的会话追问"
                          : "审查用的检出代码已清理，无法继续这个会话")
                    .disabled(!ReviewActions.canResume(record))
                Button(role: .destructive, action: delete) { Label("删除", systemImage: "trash") }
                    .help("删除这条审查记录")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(record.repositoryName) · \(record.range)").font(.title2.weight(.semibold))
            HStack(spacing: 6) {
                Text(record.finishedAt.formatted(date: .abbreviated, time: .shortened))
                Text("·")
                Text(record.model.title)
                if let link = record.mergeRequest, let url = URL(string: link) {
                    Text("·")
                    Link("打开 MR", destination: url)
                }
            }
            .foregroundStyle(.secondary)
            if !record.focus.isEmpty {
                Text("关注点：\(record.focus)").foregroundStyle(.secondary)
            }
            Text((record.reportURL.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }
}

/// A read-only rendering of the report's Markdown: headings, paragraphs, lists, code
/// blocks and tables, with inline styles. The file stays the source.
struct MarkdownReport: View {
    private enum Block {
        case heading(Int, String)
        case text(String)
        case code(String)
    }

    private let blocks: [Block]

    init(_ source: String) {
        blocks = Self.parse(source)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in
                switch blocks[index] {
                case .heading(let level, let text):
                    Text(Self.inline(text))
                        .font(level <= 2 ? .title3.weight(.semibold) : .headline)
                        .padding(.top, 8)
                case .text(let text):
                    Text(Self.inline(text))
                case .code(let text):
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }

    private static func parse(_ source: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        var table: [String] = []

        func flush() {
            if !paragraph.isEmpty { blocks.append(.text(paragraph.joined(separator: "\n"))) }
            if !table.isEmpty { blocks.append(.code(table.joined(separator: "\n"))) }
            paragraph = []
            table = []
        }

        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
            } else if code != nil {
                code?.append(line)
            } else if trimmed.isEmpty {
                flush()
            } else if trimmed.hasPrefix("|") {
                if !paragraph.isEmpty { flush() }
                table.append(trimmed)
            } else if let hashes = trimmed.firstIndex(where: { $0 != "#" }), hashes != trimmed.startIndex,
                      trimmed[hashes] == " " {
                flush()
                let level = trimmed.distance(from: trimmed.startIndex, to: hashes)
                blocks.append(.heading(level, String(trimmed[hashes...]).trimmingCharacters(in: .whitespaces)))
            } else if let item = listItem(line) {
                flush()
                blocks.append(.text(item))
            } else {
                if !table.isEmpty { flush() }
                paragraph.append(trimmed)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    /// "- x" and "* x" become bullets; numbered items keep their number. Indented
    /// items keep their indent.
    private static func listItem(_ line: String) -> String? {
        let indent = String(repeating: "    ", count: line.prefix(while: { $0 == " " }).count / 2)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            return indent + "• " + trimmed.dropFirst(2)
        }
        if let dot = trimmed.firstIndex(of: "."), dot != trimmed.startIndex,
           trimmed[..<dot].allSatisfy(\.isNumber), trimmed[dot...].hasPrefix(". ") {
            return indent + trimmed
        }
        return nil
    }
}

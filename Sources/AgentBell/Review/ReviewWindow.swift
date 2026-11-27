import AppKit
import BellCore
import SwiftUI

@MainActor
final class ReviewWindowController {
    private let store: SessionStore
    private lazy var window: NSWindow = {
        let view = NSHostingController(rootView: ReviewView(store: store))
        let window = NSWindow(contentViewController: view)
        window.title = "代码审查"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }()

    init(store: SessionStore) { self.store = store }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ReviewView: View {
    let store: SessionStore

    @AppStorage("review.repository") private var repository = ""
    @AppStorage("review.baseBranch") private var baseBranch = "main"
    @AppStorage("review.promptTemplate") private var template = ReviewRunner.defaultTemplate
    @AppStorage("review.requireCurrentTarget") private var requireCurrentTarget = true
    @ViewState private var message = ""
    @ViewState private var focus = ""
    @ViewState private var plan: ReviewPlan?
    @ViewState private var result = ""
    @ViewState private var busy: String?
    @ViewState private var problem: String?
    @ViewState private var templateShown = false
    @ViewState private var copied = false

    private var input: ReviewRequest? { try? ReviewRequest.parse(message) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("审查目标") {
                    LabeledContent {
                        Button("选择仓库…", action: chooseRepository)
                    } label: {
                        Text("本地仓库")
                        if !repository.isEmpty { Text((repository as NSString).abbreviatingWithTildeInPath) }
                    }
                    TextField("粘贴团队消息、MR 链接、!编号或分支名", text: $message, axis: .vertical)
                        .lineLimit(2...4)
                    if case .branch = input {
                        TextField("目标分支", text: $baseBranch)
                    }
                    TextField("关注点（可选）", text: $focus)
                }
                .disabled(busy != nil)

                if let plan {
                    Section("审查范围") {
                        LabeledContent("分支", value: "\(plan.sourceBranch) → \(plan.targetBranch)")
                        LabeledContent("源提交", value: String(plan.head.prefix(12)))
                        LabeledContent("目标提交", value: String(plan.target.prefix(12)))
                        if plan.behind > 0 {
                            Text(requireCurrentTarget
                                 ? "源分支落后目标分支 \(plan.behind) 个提交，请作者更新分支后重新检查。"
                                 : "源分支落后目标分支 \(plan.behind) 个提交，本次审查从共同提交计算差异。")
                                .foregroundStyle(.orange)
                        }
                        DisclosureGroup("查看本次 Review 指令") {
                            Text(ReviewRunner.prompt(for: plan, template: template, focus: focus))
                                .font(.system(.callout, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        Text("开始后，所选代码差异会交给当前 Claude Code 配置的模型。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if !result.isEmpty {
                    Section {
                        TextEditor(text: $result)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 180)
                        Button(copied ? "已复制" : "复制 Markdown") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(result, forType: .string)
                        }
                    } header: {
                        Text("审查结果")
                    }
                }

                if let problem {
                    Text(problem)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("Review 模板…") { templateShown = true }
                    .disabled(busy != nil)
                Spacer()
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                } else {
                    Button("检查范围", action: prepare)
                        .disabled(repository.isEmpty || message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let plan {
                        Button("开始 Review") { run(plan) }
                            .buttonStyle(.borderedProminent)
                            .disabled(requireCurrentTarget && plan.behind > 0)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 580, height: 620)
        .sheet(isPresented: $templateShown) {
            ReviewTemplateView(template: $template, requireCurrentTarget: $requireCurrentTarget)
        }
        .onChange(of: repository) { _, _ in reset() }
        .onChange(of: message) { _, _ in reset() }
        .onChange(of: baseBranch) { _, _ in reset() }
        .onChange(of: result) { _, _ in copied = false }
    }

    private func chooseRepository() {
        let panel = NSOpenPanel()
        panel.title = "选择要审查的本地 Git 仓库"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        repository = directory.path
    }

    private func reset() {
        plan = nil
        result = ""
        problem = nil
    }

    private func prepare() {
        reset()
        do {
            let request = try ReviewRequest.parse(message)
            let directory = URL(fileURLWithPath: repository, isDirectory: true)
            let base = baseBranch
            busy = "正在检查范围…"
            Task {
                defer { busy = nil }
                do {
                    plan = try await ReviewRunner.prepare(request, directory: directory, base: base)
                } catch {
                    problem = error.localizedDescription
                }
            }
        } catch {
            problem = error.localizedDescription
        }
    }

    private func run(_ plan: ReviewPlan) {
        guard case .ready(let executable) = store.claude else {
            problem = "找不到 Claude Code。请先到 AgentBell 通用设置选择可用的 Claude。"
            return
        }
        let promptTemplate = template
        let reviewFocus = focus
        busy = "Claude 正在审查…"
        result = ""
        problem = nil
        Task {
            defer { busy = nil }
            do {
                result = try await ReviewRunner.run(plan, claude: executable, template: promptTemplate, focus: reviewFocus)
            } catch {
                problem = error.localizedDescription
            }
        }
    }
}

private struct ReviewTemplateView: View {
    @Binding var template: String
    @Binding var requireCurrentTarget: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Review 模板").font(.title2.weight(.semibold))
            TextEditor(text: $template)
                .font(.system(.body, design: .monospaced))
                .border(Color.secondary.opacity(0.25))
            Text("可用变量：{{source_branch}}、{{target_branch}}、{{head_sha}}、{{target_sha}}、{{mr_url}}、{{focus}}")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Toggle("要求源分支基于最新目标分支", isOn: $requireCurrentTarget)
            HStack {
                Button("恢复默认") { template = ReviewRunner.defaultTemplate }
                Spacer()
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 500, height: 355)
    }
}

import AppKit
import BellCore
import SwiftUI

@MainActor
final class ReviewWindowController {
    private let store: SessionStore
    private let openSettings: () -> Void
    private lazy var window: NSWindow = {
        let view = NSHostingController(rootView: ReviewView(store: store, openSettings: openSettings))
        let window = NSWindow(contentViewController: view)
        window.title = "代码审查"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }()

    init(store: SessionStore, openSettings: @escaping () -> Void) {
        self.store = store
        self.openSettings = openSettings
    }

    func show() {
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }
}

private struct ReviewView: View {
    let store: SessionStore
    let openSettings: () -> Void

    @AppStorage(ReviewPreference.repository) private var repository = ""
    @AppStorage(ReviewPreference.baseBranch) private var baseBranch = "main"
    @AppStorage(ReviewPreference.template) private var template = ReviewRunner.defaultTemplate
    @AppStorage(ReviewPreference.requireCurrentTarget) private var requireCurrentTarget = true
    @FocusState private var messageFocused: Bool
    @ViewState private var message = ""
    @ViewState private var focus = ""
    @ViewState private var plan: ReviewPlan?
    @ViewState private var result = ""
    @ViewState private var busy: String?
    @ViewState private var problem: String?
    @ViewState private var repositoryChoices: [URL]?
    @ViewState private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("粘贴团队消息、MR 链接、!编号或分支名", text: $message, axis: .vertical)
                        .lineLimit(2...4)
                        .focused($messageFocused)
                    if case .mergeRequest(let project?, _) = try? ReviewRequest.parse(message) {
                        Text("自动匹配 \(project.path)").foregroundStyle(.secondary)
                    } else {
                        Text(repository.isEmpty ? "从已有项目中选择仓库" : "默认仓库 · \(ReviewPreference.displayName(repository))")
                            .foregroundStyle(.secondary)
                    }
                    DisclosureGroup("补充审查关注点") {
                        TextField("例如：重试是否会重复写入", text: $focus)
                    }
                }
                .disabled(busy != nil)

                if let choices = repositoryChoices {
                    Section("选择本次审查的仓库") {
                        ForEach(choices, id: \.path) { directory in
                            Button((directory.path as NSString).abbreviatingWithTildeInPath) {
                                start(using: directory)
                            }
                        }
                        Button("选择文件夹…") {
                            if let path = ReviewPreference.chooseRepository() {
                                ReviewPreference.remember(path)
                                start(using: URL(fileURLWithPath: path, isDirectory: true))
                            }
                        }
                    }
                }

                if let problem {
                    Text(problem).foregroundStyle(.red).textSelection(.enabled)
                }

                if let plan {
                    DisclosureGroup("审查范围 · \(plan.sourceBranch) → \(plan.targetBranch)") {
                        LabeledContent("源提交", value: String(plan.head.prefix(12)))
                        LabeledContent("目标提交", value: String(plan.target.prefix(12)))
                        if plan.behind > 0 {
                            Text("源分支落后目标分支 \(plan.behind) 个提交。")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !result.isEmpty {
                    Section("审查结果") {
                        TextEditor(text: $result)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 180)
                        Button(copied ? "已复制" : "复制 Markdown") {
                            NSPasteboard.general.clearContents()
                            copied = NSPasteboard.general.setString(result, forType: .string)
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("审查设置…", action: openSettings)
                Spacer()
                if let busy {
                    ProgressView().controlSize(.small)
                    Text(busy).foregroundStyle(.secondary)
                } else {
                    Button("开始 Review") { start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(16)
        }
        .frame(width: 540, height: plan == nil && repositoryChoices == nil ? 295 : 520)
        .onAppear { messageFocused = true }
        .onChange(of: message) { _, _ in reset() }
        .onChange(of: result) { _, _ in copied = false }
    }

    private func reset() {
        plan = nil
        result = ""
        problem = nil
        repositoryChoices = nil
    }

    private func start(using selected: URL? = nil) {
        guard busy == nil else { return }
        reset()
        guard case .ready(let executable) = store.claude else {
            problem = "找不到 Claude Code。请先在 AgentBell 通用设置选择可用的 Claude。"
            return
        }
        do {
            let request = try ReviewRequest.parse(message)
            let preferred = repository.isEmpty ? nil : URL(fileURLWithPath: repository, isDirectory: true)
            let candidates = ReviewPreference.projects(in: store).map { URL(fileURLWithPath: $0, isDirectory: true) }
            let base = baseBranch
            let promptTemplate = template
            let reviewFocus = focus
            let requireFreshBase = requireCurrentTarget
            busy = "正在解析仓库和提交…"
            Task {
                defer { busy = nil }
                do {
                    let choice: ReviewRunner.RepositoryChoice
                    if let selected {
                        choice = .use(selected)
                    } else {
                        choice = try await ReviewRunner.chooseRepository(for: request, preferred: preferred, candidates: candidates)
                    }
                    switch choice {
                    case .choose(let available):
                        repositoryChoices = available
                        problem = available.isEmpty ? "找不到对应的本地仓库，请选择项目文件夹。" : nil
                    case .use(let directory):
                        let review = try await ReviewRunner.prepare(request, directory: directory, base: base)
                        plan = review
                        if requireFreshBase && review.behind > 0 {
                            problem = "源分支落后目标分支 \(review.behind) 个提交。请作者更新分支后重试，或在「审查设置」调整此规则。"
                            return
                        }
                        busy = "Claude 正在审查…"
                        result = try await ReviewRunner.run(review, claude: executable, template: promptTemplate, focus: reviewFocus)
                    }
                } catch {
                    problem = error.localizedDescription
                }
            }
        } catch {
            problem = error.localizedDescription
        }
    }
}

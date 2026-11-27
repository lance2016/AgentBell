import BellCore
import SwiftUI

/// Starts a review. Once it starts the form empties for the next one, and the window
/// turns to the review's progress.
struct NewReviewForm: View {
    let store: SessionStore
    let reviews: ReviewStore
    @Bindable var state: ReviewWindowState
    let openSettings: () -> Void

    @AppStorage(ReviewPreference.repository) private var repository = ""
    @AppStorage(ReviewPreference.model) private var defaultModel = ReviewModel.recommended
    @FocusState private var messageFocused: Bool
    @ViewState private var problem: String?
    @ViewState private var repositoryChoices: [URL]?
    @ViewState private var resolving = false

    private var model: Binding<ReviewModel> {
        Binding(get: { state.model ?? defaultModel }, set: { state.model = $0 })
    }

    private var canStart: Bool {
        !resolving && !state.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField("审查内容", text: $state.message,
                              prompt: Text("粘贴团队消息、MR 链接、!编号或分支名"), axis: .vertical)
                        .labelsHidden()
                        .lineLimit(3...6)
                        .focused($messageFocused)
                    Text(repositoryHint).foregroundStyle(.secondary)
                } header: {
                    Text("新建审查")
                }
                Section {
                    Picker("模型", selection: model) {
                        ForEach(ReviewModel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("关注点", text: $state.focus, prompt: Text("可选，例如：重试是否会重复写入"), axis: .vertical)
                        .lineLimit(1...3)
                }
                if let choices = repositoryChoices {
                    Section("选择本次审查的仓库") {
                        ForEach(choices, id: \.path) { directory in
                            Button((directory.path as NSString).abbreviatingWithTildeInPath) { start(using: directory) }
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
            }
            .formStyle(.grouped)
            .disabled(resolving)

            Divider()
            HStack {
                Button("审查设置…", action: openSettings)
                Spacer()
                if resolving {
                    ProgressView().controlSize(.small)
                    Text("正在匹配仓库…").foregroundStyle(.secondary)
                }
                Button("开始审查") { start() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!canStart)
            }
            .padding(16)
        }
        .navigationTitle("新建审查")
        .onAppear { messageFocused = true }
        .onChange(of: state.message) { _, _ in
            problem = nil
            repositoryChoices = nil
        }
    }

    private var repositoryHint: String {
        if case .mergeRequest(let project?, _) = try? ReviewRequest.parse(state.message) {
            return "自动匹配 \(project.path)"
        }
        return repository.isEmpty ? "从已有项目中选择仓库" : "默认仓库 · \(ReviewPreference.displayName(repository))"
    }

    private func start(using selected: URL? = nil) {
        guard !resolving else { return }
        problem = nil
        guard case .ready = store.claude else {
            problem = "找不到 Claude Code。请先在 AgentBell 通用设置选择可用的 Claude。"
            return
        }
        let request: ReviewRequest
        do {
            request = try ReviewRequest.parse(state.message)
        } catch {
            problem = error.localizedDescription
            return
        }
        if let selected {
            begin(request, in: selected)
            return
        }
        let preferred = repository.isEmpty ? nil : URL(fileURLWithPath: repository, isDirectory: true)
        let candidates = ReviewPreference.projects(in: store).map { URL(fileURLWithPath: $0, isDirectory: true) }
        resolving = true
        Task {
            defer { resolving = false }
            do {
                switch try await ReviewRunner.chooseRepository(for: request, preferred: preferred, candidates: candidates) {
                case .use(let directory):
                    begin(request, in: directory)
                case .choose(let available):
                    repositoryChoices = available
                    problem = available.isEmpty ? "找不到对应的本地仓库，请选择项目文件夹。" : nil
                }
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func begin(_ request: ReviewRequest, in directory: URL) {
        let id = reviews.start(request, message: state.message, directory: directory,
                               model: model.wrappedValue, focus: state.focus)
        state.message = ""
        state.focus = ""
        state.model = nil
        repositoryChoices = nil
        state.selection = [id]
    }
}

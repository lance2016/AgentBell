import BellCore
import SwiftUI

/// Starts a review. Once it starts the form empties for the next one, and the window
/// turns to the review's progress.
struct NewReviewForm: View {
    let store: SessionStore
    let reviews: ReviewStore
    @Bindable var state: ReviewWindowState
    let openSettings: () -> Void

    /// The repository found for what is reviewed, while 仓库 is left on 自动.
    private enum Match: Equatable {
        case matching
        case found(URL)
        /// None or several fit: the user picks one.
        case ambiguous([URL])
        /// Starting reports why, such as a message that names nothing to review.
        case failed(String)
    }

    /// Typing pauses this long before the repositories are matched: an MR link asks Git.
    private static let matchDelay: Duration = .milliseconds(400)
    private static let chooseFolderTag = "\u{0}choose"

    @AppStorage(ReviewPreference.repository) private var repository = ""
    @AppStorage(ReviewPreference.model) private var defaultModel = ReviewModel.recommended
    @FocusState private var messageFocused: Bool
    @ViewState private var problem: String?
    @ViewState private var match: Match = .matching

    private var model: Binding<ReviewModel> {
        Binding(get: { state.model ?? defaultModel }, set: { state.model = $0 })
    }

    private var message: String { state.message.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// 自动 must have settled on one repository, or on why starting would fail.
    private var canStart: Bool {
        guard !message.isEmpty else { return false }
        if state.repository != nil { return true }
        switch match {
        case .found, .failed: return true
        case .matching, .ambiguous: return false
        }
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
                } header: {
                    Text("新建审查")
                }
                Section {
                    repositoryPicker
                    Picker("模型", selection: model) {
                        ForEach(ReviewModel.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("关注点", text: $state.focus, prompt: Text("可选，例如：重试是否会重复写入"), axis: .vertical)
                        .lineLimit(1...3)
                }
                if let problem {
                    Text(problem).foregroundStyle(.red).textSelection(.enabled)
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Button("审查设置…", action: openSettings)
                Spacer()
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
            match = .matching
        }
        .task(id: state.message) { await matchRepository() }
    }

    // MARK: - Repository

    /// 自动 says what it found; the projects follow, the ones that fit first.
    private var repositoryPicker: some View {
        let projects = projectChoices
        let fitting = if case .ambiguous(let urls) = match { urls.map(\.path) } else { [String]() }
        let others = projects.filter { !fitting.contains($0) }
        return Picker(selection: repositorySelection) {
            Text(automaticTitle).tag("")
            if !fitting.isEmpty {
                Section("匹配的仓库") { projectItems(fitting, among: projects) }
            }
            Section(fitting.isEmpty ? "项目" : "其他项目") { projectItems(others, among: projects) }
            Divider()
            Text("选择文件夹…").tag(Self.chooseFolderTag)
        } label: {
            Text("仓库")
            if state.repository == nil, let note = automaticNote {
                Text(note)
            }
        }
    }

    private var repositorySelection: Binding<String> {
        Binding(get: { state.repository ?? "" }, set: { picked in
            if picked == Self.chooseFolderTag {
                // The open panel runs after the menu has closed.
                Task { @MainActor in
                    guard let path = ReviewPreference.chooseRepository() else { return }
                    ReviewPreference.remember(path)
                    state.repository = path
                }
            } else {
                state.repository = picked.isEmpty ? nil : picked
            }
        })
    }

    /// The saved projects, and the one picked for this review when it is not among them.
    private var projectChoices: [String] {
        let projects = ReviewPreference.projects(in: store)
        guard let picked = state.repository, !projects.contains(picked) else { return projects }
        return [picked] + projects
    }

    /// Projects with the same folder name show their paths.
    private func projectItems(_ paths: [String], among all: [String]) -> some View {
        ForEach(paths, id: \.self) { path in
            let name = ReviewPreference.displayName(path)
            let duplicated = all.contains { $0 != path && ReviewPreference.displayName($0) == name }
            Text(duplicated ? (path as NSString).abbreviatingWithTildeInPath : name).tag(path)
        }
    }

    private var automaticTitle: String {
        switch match {
        case .found(let url): "自动 · \(url.lastPathComponent)"
        case .matching where !message.isEmpty: "自动 · 正在匹配…"
        case .ambiguous: "自动 · 请选择"
        default: "自动"
        }
    }

    /// Why 自动 needs a hand, under 仓库.
    private var automaticNote: String? {
        switch match {
        case .ambiguous(let urls) where urls.isEmpty: "找不到对应的本地仓库，请选择项目文件夹"
        case .ambiguous: "多个仓库都可能是，请选择一个"
        default: nil
        }
    }

    private func matchRepository() async {
        guard !message.isEmpty else { return }
        do {
            try await Task.sleep(for: Self.matchDelay)
        } catch {
            return
        }
        let request: ReviewRequest
        do {
            request = try ReviewRequest.parse(state.message)
        } catch {
            match = .failed(error.localizedDescription)
            return
        }
        let preferred = repository.isEmpty ? nil : URL(fileURLWithPath: repository, isDirectory: true)
        let candidates = ReviewPreference.projects(in: store).map { URL(fileURLWithPath: $0, isDirectory: true) }
        do {
            let choice = try await ReviewRunner.chooseRepository(for: request, preferred: preferred, candidates: candidates)
            guard !Task.isCancelled else { return }
            switch choice {
            case .use(let directory): match = .found(directory)
            case .choose(let available): match = .ambiguous(available)
            }
        } catch {
            guard !Task.isCancelled else { return }
            match = .failed(error.localizedDescription)
        }
    }

    // MARK: - Start

    private func start() {
        guard canStart else { return }
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
        if let picked = state.repository {
            begin(request, in: URL(fileURLWithPath: picked, isDirectory: true))
            return
        }
        switch match {
        case .found(let directory): begin(request, in: directory)
        case .failed(let reason): problem = reason
        case .matching, .ambiguous: break
        }
    }

    private func begin(_ request: ReviewRequest, in directory: URL) {
        let id = reviews.start(request, message: state.message, directory: directory,
                               model: model.wrappedValue, focus: state.focus)
        state.message = ""
        state.focus = ""
        state.model = nil
        state.repository = nil
        state.selection = [id]
    }
}

import AppKit
import BellCore
import SwiftUI

enum ReviewPreference {
    static let repository = "review.repository"
    static let baseBranch = "review.baseBranch"
    static let template = "review.promptTemplate"
    static let requireCurrentTarget = "review.requireCurrentTarget"
    static let model = "review.model"
    /// Where reports are saved; empty for `ReviewArchive.defaultRoot`.
    static let reportsFolder = "review.reportsFolder"
    private static let additionalRepositories = "review.additionalRepositories"

    static var reportsRoot: URL {
        let path = UserDefaults.standard.string(forKey: reportsFolder) ?? ""
        return path.isEmpty ? ReviewArchive.defaultRoot : URL(fileURLWithPath: path, isDirectory: true)
    }

    @MainActor static func chooseReportsFolder() -> String? {
        let panel = NSOpenPanel()
        panel.title = "选择审查报告的保存位置"
        panel.prompt = "选择"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = reportsRoot
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    /// Opens the folder, made first so Finder has something to show.
    @MainActor static func revealReportsFolder() {
        try? FileManager.default.createDirectory(at: reportsRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(reportsRoot)
    }

    @MainActor static func projects(in store: SessionStore) -> [String] {
        let sessions = PanelLayout.projects(live: store.liveSessions, recent: store.tracker.recent,
                                           pinned: store.pinnedProjects)
        let extra = UserDefaults.standard.stringArray(forKey: additionalRepositories) ?? []
        let tasks = store.tasks.tasks.flatMap { $0.workspaces.map(\.projectRoot) }
        var seen: Set<String> = []
        return (store.pinnedProjects + sessions.map(\.id) + tasks + extra).filter {
            seen.insert($0).inserted && canReview($0)
        }
    }

    /// A Git repository of the user's own, not a checkout a review made.
    static func canReview(_ path: String) -> Bool {
        !ReviewRunner.isReviewCheckout(path)
            && FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    @MainActor static func chooseRepository() -> String? {
        let panel = NSOpenPanel()
        panel.title = "选择本地 Git 仓库"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let root = ProjectInfo.lookup(cwd: url.resolvingSymlinksInPath().path).root
        guard FileManager.default.fileExists(atPath: (root as NSString).appendingPathComponent(".git")) else {
            let alert = NSAlert()
            alert.messageText = "请选择一个 Git 仓库"
            alert.runModal()
            return nil
        }
        return root
    }

    static func remember(_ path: String) {
        let previous = UserDefaults.standard.stringArray(forKey: additionalRepositories) ?? []
        guard !previous.contains(path) else { return }
        UserDefaults.standard.set(previous + [path], forKey: additionalRepositories)
    }

    static func displayName(_ path: String) -> String { (path as NSString).lastPathComponent }
}

struct ReviewSettings: View {
    let store: SessionStore

    @AppStorage(ReviewPreference.repository) private var repository = ""
    @AppStorage(ReviewPreference.baseBranch) private var baseBranch = "main"
    @AppStorage(ReviewPreference.template) private var template = ReviewRunner.defaultTemplate
    @AppStorage(ReviewPreference.requireCurrentTarget) private var requireCurrentTarget = true
    @AppStorage(ReviewPreference.model) private var model = ReviewModel.recommended
    @AppStorage(ReviewPreference.reportsFolder) private var reportsFolder = ""

    private var projects: [String] {
        let existing = ReviewPreference.projects(in: store)
        return repository.isEmpty || existing.contains(repository) ? existing : [repository] + existing
    }

    var body: some View {
        Form {
            Section("默认项目") {
                LabeledContent {
                    HStack(spacing: 8) {
                        Picker("默认仓库", selection: $repository) {
                            Text("自动选择").tag("")
                            ForEach(projects, id: \.self) { path in
                                Text(ReviewPreference.displayName(path)).tag(path)
                                    .help((path as NSString).abbreviatingWithTildeInPath)
                            }
                        }
                        .labelsHidden()
                        Button("选择文件夹…") {
                            if let path = ReviewPreference.chooseRepository() {
                                ReviewPreference.remember(path)
                                repository = path
                            }
                        }
                    }
                } label: {
                    Text("默认仓库")
                    Text(repository.isEmpty
                         ? "完整 MR 链接会匹配已有项目。"
                         : (repository as NSString).abbreviatingWithTildeInPath)
                }
                TextField("仅输入分支时的目标分支", text: $baseBranch)
                Toggle("要求源分支基于最新目标分支", isOn: $requireCurrentTarget)
            }
            Section("审查结果") {
                Picker("默认模型", selection: $model) {
                    ForEach(ReviewModel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent {
                    HStack(spacing: 8) {
                        Button("更改…") {
                            if let path = ReviewPreference.chooseReportsFolder() { reportsFolder = path }
                        }
                        Button("在访达中显示") { ReviewPreference.revealReportsFolder() }
                        if !reportsFolder.isEmpty {
                            Button("恢复默认") { reportsFolder = "" }
                        }
                    }
                } label: {
                    Text("保存位置")
                    Text((ReviewPreference.reportsRoot.path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                        .help("每次审查保存为一个文件夹，内含 report.md。更改位置后，已有报告仍留在原文件夹。")
                }
            }
            Section("Review 模板") {
                TextEditor(text: $template)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 155)
                    .accessibilityLabel("Review 模板")
                Text("可用变量：{{source_branch}}、{{target_branch}}、{{head_sha}}、{{target_sha}}、{{mr_url}}、{{focus}}")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("恢复默认模板") { template = ReviewRunner.defaultTemplate }
            }
        }
    }
}

import AppKit
import BellCore
import SwiftUI

/// The weekly report's prompt and model, and where reports are kept.
struct WeeklySettings: View {
    @AppStorage(WeeklyPreference.template) private var template = WeeklyRunner.defaultTemplate
    @AppStorage(WeeklyPreference.model) private var model = ReviewModel.recommended

    var body: some View {
        Form {
            Section("周报") {
                Picker("默认模型", selection: $model) {
                    ForEach(ReviewModel.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                LabeledContent {
                    Button("在访达中显示") {
                        let root = WeeklyArchive.defaultRoot
                        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(root)
                    }
                } label: {
                    Text("保存位置")
                    Text((WeeklyArchive.defaultRoot.path as NSString).abbreviatingWithTildeInPath)
                        .textSelection(.enabled)
                        .help("每份周报保存为一个文件夹，内含 report.md。")
                }
            }
            Section("周报模板") {
                TextEditor(text: $template)
                    .font(.system(.callout, design: .monospaced))
                    .frame(height: 175)
                    .accessibilityLabel("周报模板")
                Text("可用变量：{{period}}（本周或上周）、{{next_period}}（它的下一周：下周或本周）、{{days}}（如 11月23日 – 11月29日）。会话记录会附在模板后面。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("恢复默认模板") { template = WeeklyRunner.defaultTemplate }
            }
        }
    }
}

import AppKit
import SwiftUI

/// What this version adds, opened from Settings › About. Update `items` with each release,
/// and add the same version to CHANGELOG.md.
enum ReleaseNotes {
    /// Every version's notes, kept in the repository.
    static let changelogURL = URL(string: "https://github.com/lance2016/AgentBell/blob/main/CHANGELOG.md")!

    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    static let items = [
        Item(symbol: "checkmark.bubble",
             title: "代码审查在后台跑，还有记录",
             detail: "开始审查后可以关掉窗口，也能同时审几个。结束时发通知，报告存成 report.md；想追问就点「在终端继续」。"),
        Item(symbol: "arrow.triangle.branch",
             title: "每一行都写分支",
             detail: "会话行写自己的分支和 worktree；代码审查会话有放大镜图标，写「源分支 → 目标分支」。"),
        Item(symbol: "xmark.circle",
             title: "关闭会话",
             detail: "行尾的 ⊗ 或右键菜单可以结束开着的会话。对话保留，之后可以 claude --resume。"),
        Item(symbol: "folder.fill",
             title: "项目有颜色",
             detail: "侧栏每个项目前面一个固定颜色的图标方块；Ghostty 太旧时，设置里会提示更新。"),
        Item(symbol: "doc.text.magnifyingglass",
             title: "开发者模式",
             detail: "在「设置 › 关于」打开后，可以查看和导出这次运行的日志，排查问题时用。"),
    ]
}

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss

    private static let donationCode = Bundle.main.url(forResource: "alipay-qr", withExtension: "png", subdirectory: "Donate")
        .flatMap { NSImage(contentsOf: $0) }

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "开发版"
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 6) {
                BellAppIcon(size: 56)
                Text("这一版的新变化").font(.title2.weight(.semibold))
                Text("AgentBell \(version)").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 16) {
                ForEach(ReleaseNotes.items) { item in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: item.symbol)
                            .font(.system(size: 18))
                            .foregroundStyle(Color.accentColor)
                            .frame(width: 28)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.system(size: 13, weight: .semibold))
                            Text(item.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
                Link("查看全部版本的更新记录", destination: ReleaseNotes.changelogURL)
                    .font(.system(size: 12))
            }
            if let code = Self.donationCode {
                donation(code)
            }
            Button("好") { dismiss() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
        }
        .padding(28)
        .frame(width: 420)
    }

    /// A quiet thank-you jar under the notes: the code, and one line on how to use it.
    private func donation(_ code: NSImage) -> some View {
        HStack(spacing: 16) {
            Image(nsImage: code)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .padding(6)
                .background(.white, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityLabel("支付宝收款码")
            VStack(alignment: .leading, spacing: 4) {
                Text("请作者喝杯咖啡").font(.system(size: 13, weight: .semibold))
                Text("AgentBell 免费开源。觉得好用的话，用支付宝扫一扫就行。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

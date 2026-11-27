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
             title: "代码审查",
             detail: "「新建会话 → 代码审查」里粘贴团队消息或 GitLab MR 链接，核对分支和提交后在独立 worktree 里审查，完成后复制 Markdown。"),
        Item(symbol: "arrow.uturn.forward",
             title: "继续工作与连接诊断",
             detail: "任务关联的会话关掉后，点「继续工作」在原目录恢复；收不到提醒时，「设置 › 通用 › 连接诊断」帮你找原因。"),
        Item(symbol: "list.bullet.rectangle",
             title: "更好认的会话列表",
             detail: "每个会话一行标题、一行最近一轮的摘要，最近活动时间在右边；分支和加入的开发任务有才显示，不再标出「同目录」。"),
        Item(symbol: "pencil",
             title: "给会话改名",
             detail: "点会话行或详情标题旁的铅笔，就地改名，回车保存，Esc 取消。名字只在 AgentBell 里生效；Claude Code 里 /rename 的名字关掉后也照样显示。"),
        Item(symbol: "rectangle.righthalf.inset.filled.arrow.right",
             title: "桌面小终端贴边",
             detail: "拖到屏幕左侧或右侧松手，它会贴边收起，鼠标停留时探出来。"),
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

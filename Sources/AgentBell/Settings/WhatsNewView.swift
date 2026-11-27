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
        Item(symbol: "rectangle.grid.1x2",
             title: "详情一页看全",
             detail: "概览里有最近一轮、所在的开发任务、工作区和会话信息，不用再点开菜单才知道它在哪个任务里。"),
        Item(symbol: "arrow.triangle.branch",
             title: "认得出 worktree",
             detail: "会话在 worktree 里工作时，详情的工作区会标出来，连同分支、改动文件数和最近提交。"),
        Item(symbol: "circle.lefthalf.filled",
             title: "更安静的详情",
             detail: "按钮收成三个，不再用强调色；回复不再重复出现，页面上有颜色的只剩状态灯。"),
        Item(symbol: "clock.arrow.circlepath",
             title: "更新记录",
             detail: "这一页底部可以打开全部版本的更新记录。"),
        Item(symbol: "wrench.and.screwdriver",
             title: "细节修正",
             detail: "用 Xcode 16.1 也能编译；请求通知权限更稳。"),
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

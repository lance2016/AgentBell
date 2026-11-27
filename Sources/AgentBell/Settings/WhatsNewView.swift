import AppKit
import SwiftUI

/// What this version adds, opened from Settings › About. Update `items` with each release.
enum ReleaseNotes {
    struct Item: Identifiable {
        let symbol: String
        let title: String
        let detail: String
        var id: String { title }
    }

    static let items = [
        Item(symbol: "rectangle.stack",
             title: "所有会话，一屏看全",
             detail: "Claude Code 会话按项目归在一起，谁在跑、谁在等你，一眼就知道。"),
        Item(symbol: "arrow.uturn.backward",
             title: "一键回到现场",
             detail: "点一下就跳回会话所在的终端窗口，支持 Ghostty、iTerm2 和「终端」。"),
        Item(symbol: "bell.badge",
             title: "该你出手时提醒你",
             detail: "等你确认、出错或长任务完成时，用通知或桌面气泡告诉你。"),
        Item(symbol: "face.smiling",
             title: "桌面小终端",
             detail: "灯光和表情实时显示状态，大小可以在「设置 › 桌面」调整。"),
        Item(symbol: "checklist",
             title: "开发任务",
             detail: "记下每件事做到哪、下一步做什么，回来就能接着干。"),
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

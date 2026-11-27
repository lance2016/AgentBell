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
        Item(symbol: "keyboard",
             title: "全局快捷键",
             detail: "在任何地方按 ⌃⌥⌘J 回到等你最久的会话，⌃⌥⌘B 打开面板。可以在「设置 › 通用」里改。"),
        Item(symbol: "bell.slash",
             title: "正看着就不打扰",
             detail: "会话停下来时，你正盯着它所在的终端，就不再弹通知和气泡。"),
        Item(symbol: "square.on.square",
             title: "同目录提醒",
             detail: "两个会话在同一个目录里工作时，会话行会标出「同目录」，免得改动互相覆盖。"),
        Item(symbol: "wrench.and.screwdriver",
             title: "细节修正",
             detail: "跳回「终端」时的高亮框不再超出窗口；置顶项目左边保留文件夹，图钉移到行尾。"),
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

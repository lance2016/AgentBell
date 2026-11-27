import SwiftUI

struct DesktopSettings: View {
    @AppStorage(Entry.menuBarKey) private var menuBarIcon = true
    @AppStorage(Entry.desktopKey) private var desktopIcon = true
    @AppStorage(Entry.desktopSizeKey) private var desktopSize = Entry.defaultDesktopSize

    var body: some View {
        Form {
            Section("桌面图标") {
                Toggle(isOn: $desktopIcon) {
                    Text("显示桌面图标")
                    Text("拖到屏幕左右边缘可贴边，点一下打开会话窗口")
                }
                .disabled(desktopIcon && !menuBarIcon)
                desktopSizeRow
            }

            Section("状态说明") {
                ForEach(DesktopMascotAppearance.allCases) { appearance in
                    HStack(spacing: 12) {
                        if let artwork = DesktopMascotArtwork.bundled {
                            DesktopMascotDrawing(artwork: artwork, appearance: appearance, size: 44)
                        }
                        Text(appearance.title)
                            .fontWeight(.medium)
                            .frame(width: 68, alignment: .leading)
                        Text(appearance.explanation)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var desktopSizeRow: some View {
        let range = Entry.desktopSizeRange
        let value = Entry.desktopSize(desktopSize)
        return LabeledContent("桌面图标大小") {
            HStack(spacing: 8) {
                Slider(
                    value: Binding(get: { Double(Entry.desktopSize(desktopSize)) }, set: { desktopSize = Int($0) }),
                    in: Double(range.lowerBound)...Double(range.upperBound),
                    step: 8
                ) {
                    Text("桌面图标大小")
                }
                .labelsHidden()
                .frame(width: 128)
                .accessibilityValue("\(value) 点")
                Text("\(value) pt")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .trailing)
                    .accessibilityHidden(true)
            }
        }
    }
}

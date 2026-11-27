import AppKit
import SwiftUI

/// A session's name edited in place, in a row or the detail: the field, then save and
/// cancel. Return saves, Esc cancels (the panel's key handler turns it into `onCancel`).
/// A blank name cannot be saved, and an unchanged one closes without saving.
struct RenameField: View {
    enum Size {
        case row, heading

        var font: Font { self == .row ? .sessionTitle : .system(size: 17, weight: .semibold) }
        var height: CGFloat { self == .row ? 22 : 30 }
    }

    let title: String
    let size: Size
    /// Throws when the name could not be saved; the field then stays open with the error.
    let onSave: (String) throws -> Void
    let onCancel: () -> Void

    @State private var draft = ""
    @State private var error: String?
    /// Set once a save went through, so a second Return or click does nothing.
    @State private var saved = false
    @FocusState private var focused: Bool

    private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                field
                SaveButton(size: size.height, enabled: !trimmed.isEmpty, action: save)
                CancelButton(size: size.height, action: onCancel)
            }
            if let error {
                Text(error)
                    .font(.rowDetail)
                    .foregroundStyle(Color.bellRed)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            draft = title
            focused = true
            // Once the field holds the focus, select the old name so typing replaces it.
            Task { @MainActor in
                NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private var field: some View {
        TextField("会话名称", text: $draft)
            .textFieldStyle(.plain)
            .font(size.font)
            .focused($focused)
            .onSubmit(save)
            .padding(.horizontal, size == .row ? 6 : 8)
            .frame(height: size.height)
            .background(Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: BellLayout.controlRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: BellLayout.controlRadius, style: .continuous)
                    .strokeBorder(Color.bellAccent, lineWidth: 1.5)
            }
            .help("只改 AgentBell 里显示的名字，Claude Code 里的会话名不变")
            .accessibilityLabel("会话名称")
    }

    private func save() {
        guard !saved, !trimmed.isEmpty else { return }
        guard trimmed != title else { onCancel(); return }
        do {
            try onSave(trimmed)
            saved = true
        } catch {
            self.error = "名字没保存：\(error.localizedDescription)"
        }
    }
}

/// The accent square with a tick: the field's one prominent control.
private struct SaveButton: View {
    let size: CGFloat
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "checkmark")
                .font(.system(size: size > 24 ? 13 : 11, weight: .semibold))
                .foregroundStyle(Color(nsColor: .textBackgroundColor))
                .frame(width: size, height: size)
                .background(Color.bellAccent, in: RoundedRectangle(cornerRadius: BellLayout.controlRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help("保存（↩）")
        .accessibilityLabel("保存名称")
    }
}

/// A plain square with a cross, as quiet as the row's other controls.
private struct CancelButton: View {
    let size: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: size > 24 ? 12 : 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: size, height: size)
                .background(BellLayout.controlFill, in: RoundedRectangle(cornerRadius: BellLayout.controlRadius, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
        .help("取消（Esc）")
        .accessibilityLabel("取消重命名")
    }
}

/// The always-there pencil beside a session's name: faint, darker with a fill on hover.
struct RenameButton: View {
    let title: String
    let action: () -> Void

    @ViewState private var hovered = false

    var body: some View {
        Button(action: action) {
            // Medium: at regular weight the pencil's single stroke reads thinner than ⓘ.
            Image(systemName: "pencil")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(hovered ? .secondary : .tertiary)
                .frame(width: BellLayout.inlineControlSize, height: BellLayout.inlineControlSize)
        }
        .buttonStyle(BellButtonStyle(radius: BellLayout.controlRadius))
        .onHover { hovered = $0 }
        .help("重命名")
        .accessibilityLabel("重命名：\(title)")
    }
}

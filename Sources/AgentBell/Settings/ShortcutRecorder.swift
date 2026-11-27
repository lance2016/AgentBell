import AppKit
import BellCore
import Carbon.HIToolbox
import SwiftUI

/// Settings › 通用 › 快捷键: one row per shortcut. Click the key, then press the new
/// combination; Esc keeps the old one, Delete turns the shortcut off.
struct ShortcutRow: View {
    let shortcut: Shortcut
    let hotKeys: GlobalHotKeys

    @AppStorage private var stored: Data?
    @State private var recording = false
    @State private var monitor: Any?

    init(shortcut: Shortcut, hotKeys: GlobalHotKeys) {
        self.shortcut = shortcut
        self.hotKeys = hotKeys
        _stored = AppStorage(shortcut.defaultsKey)
    }

    private var key: HotKey? { HotKey.stored(stored, default: shortcut.defaultKey) }

    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if key != shortcut.defaultKey && !recording {
                    Button("恢复默认") { stored = nil }
                        .buttonStyle(.link)
                }
                Button(recording ? "按下快捷键…" : key?.label ?? "未设置") {
                    recording ? stop() : start()
                }
                .font(.system(size: 12, design: key == nil || recording ? .default : .monospaced))
                .frame(minWidth: 96)
            }
        } label: {
            Text(shortcut.title)
            Text(caption)
        }
        .onDisappear(perform: stop)
    }

    private var caption: String {
        if recording { return "Esc 取消，Delete 关闭这个快捷键" }
        if hotKeys.taken.contains(shortcut) { return "被其他应用占用了，换一个吧" }
        return shortcut.caption
    }

    private func start() {
        recording = true
        hotKeys.setPaused(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_Escape:
                stop()
            case kVK_Delete, kVK_ForwardDelete:
                GlobalHotKeys.set(nil, for: shortcut)
                stop()
            default:
                let key = HotKey(event: event)
                // Needs ⌘, ⌥ or ⌃; anything else keeps listening.
                guard key.isUsable else { return nil }
                GlobalHotKeys.set(key, for: shortcut)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        hotKeys.setPaused(false)
    }
}

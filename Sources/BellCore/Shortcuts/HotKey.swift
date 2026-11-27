import Foundation

/// A system-wide shortcut, as Carbon registers it and Settings writes it.
public struct HotKey: Sendable, Equatable, Codable {
    /// Carbon's modifier masks (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    public static let command: UInt32 = 0x0100
    public static let shift: UInt32 = 0x0200
    public static let option: UInt32 = 0x0800
    public static let control: UInt32 = 0x1000

    /// A virtual key code, the same on every keyboard layout.
    public let keyCode: UInt32
    public let modifiers: UInt32
    /// The key's own name as it was typed, such as "J".
    public let key: String

    public init(keyCode: UInt32, modifiers: UInt32, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.key = key
    }

    /// Modifiers in the order macOS menus write them.
    public var label: String {
        var text = ""
        if modifiers & Self.control != 0 { text += "⌃" }
        if modifiers & Self.option != 0 { text += "⌥" }
        if modifiers & Self.shift != 0 { text += "⇧" }
        if modifiers & Self.command != 0 { text += "⌘" }
        return text + key
    }

    /// How a key is written in a shortcut: keys that type nothing by name, others by the
    /// character they type, upper-cased.
    public static func keyName(keyCode: UInt32, characters: String?) -> String {
        if let name = namedKeys[keyCode] { return name }
        let text = (characters ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let printable = text.count == 1 && text.unicodeScalars.allSatisfy { !$0.properties.isNoncharacterCodePoint && $0.value < 0xF700 }
        return printable ? text : "键 \(keyCode)"
    }

    private static let namedKeys: [UInt32: String] = [
        0x31: "空格", 0x24: "↩", 0x30: "⇥", 0x7B: "←", 0x7C: "→", 0x7D: "↓", 0x7E: "↑",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4", 0x60: "F5", 0x61: "F6",
        0x62: "F7", 0x64: "F8", 0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
    ]

    /// Shift alone would take a capital letter away from every app.
    public var isUsable: Bool { modifiers & (Self.command | Self.option | Self.control) != 0 }

    /// What Settings keeps: no value means the default, an empty one means switched off.
    public static func stored(_ data: Data?, default fallback: HotKey) -> HotKey? {
        guard let data else { return fallback }
        guard !data.isEmpty else { return nil }
        return (try? JSONDecoder().decode(HotKey.self, from: data)) ?? fallback
    }

    public static func encoded(_ key: HotKey?) -> Data {
        guard let key else { return Data() }
        return (try? JSONEncoder().encode(key)) ?? Data()
    }
}

/// The shortcuts AgentBell offers. Three modifiers, so they stay clear of the shortcuts
/// apps and window managers already use.
public enum Shortcut: String, CaseIterable, Sendable, Identifiable {
    case openPanel
    case jumpToWaiting

    public var id: String { rawValue }

    public var defaultsKey: String { "shortcut.\(rawValue)" }

    public var title: String {
        switch self {
        case .openPanel: "打开面板"
        case .jumpToWaiting: "回到等你的会话"
        }
    }

    public var caption: String {
        switch self {
        case .openPanel: "再按一次收起"
        case .jumpToWaiting: "等你最久的先去；没有在等的就打开面板"
        }
    }

    public var defaultKey: HotKey {
        let all = HotKey.control | HotKey.option | HotKey.command
        switch self {
        case .openPanel: return HotKey(keyCode: 0x0B, modifiers: all, key: "B")
        case .jumpToWaiting: return HotKey(keyCode: 0x26, modifiers: all, key: "J")
        }
    }
}

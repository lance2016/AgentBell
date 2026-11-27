import Foundation

/// How the panel lays sessions out; chosen in Settings › 通用.
enum PanelStyle: String, CaseIterable, Identifiable {
    /// One column, grouped by project: best with a few sessions.
    case list
    /// Projects on the left, the picked project's sessions on the right: best with many.
    case sidebar

    static let key = "panel.style"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "列表"
        case .sidebar: return "侧栏"
        }
    }

    var caption: String {
        switch self {
        case .list: return "按项目分组，在一列中浏览所有会话"
        case .sidebar: return "左边选项目，右边查看该项目的会话"
        }
    }

    static var current: PanelStyle {
        UserDefaults.standard.string(forKey: key).flatMap(PanelStyle.init(rawValue:)) ?? .list
    }
}

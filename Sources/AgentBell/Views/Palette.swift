import AppKit
import BellCore
import SwiftUI

enum Palette {
    static let amberLamp = rgb(0xF5A524)
    static let amberText = dynamic(light: 0x995700, dark: 0xF0B34A)
    static let blueLamp = dynamic(light: 0x1769C5, dark: 0x68ACFF)
    static let greenLamp = dynamic(light: 0x237844, dark: 0x64D69A)
    static let red = dynamic(light: 0xAD373D, dark: 0xFF9092)
    static let graphite = rgb(0x3A3A3C)
    /// The one accent: a muted violet for what is picked and for a session's task tag.
    static let accent = dynamic(light: 0x6B5FC7, dark: 0xB2A8F2)

    /// Cards: white on the content pane, a faint lift in dark mode.
    static let card = dynamic(light: (0xFFFFFF, 1), dark: (0xFFFFFF, 0.06))
    /// The content pane, its header included: solid, so the translucent sidebar beside
    /// it reads as a separate layer.
    static let content = dynamic(light: (0xF5F5F7, 1), dark: (0x1F1F21, 1))

    private static func dynamic(light: (Int, CGFloat), dark: (Int, CGFloat)) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (hex, alpha) = isDark ? dark : light
            return rgb(hex).withAlphaComponent(alpha)
        }
    }

    private static func dynamic(light: Int, dark: Int) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return rgb(isDark ? dark : light)
        }
    }

    private static func rgb(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    static let amberLamp = Color(nsColor: Palette.amberLamp)
    static let amberText = Color(nsColor: Palette.amberText)
    static let blueLamp = Color(nsColor: Palette.blueLamp)
    static let greenLamp = Color(nsColor: Palette.greenLamp)
    static let bellRed = Color(nsColor: Palette.red)
    static let bellAccent = Color(nsColor: Palette.accent)

    /// The detail's main button: neutral, so the lamps stay the only colour. Picked per
    /// scheme because AppKit resolves a button's tint as light, and in dark mode draws the
    /// fill at about half strength: white lands one step above the plain buttons there.
    static func mainButton(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .white : Color(nsColor: Palette.graphite)
    }

    /// The sidebar's pages, each with its own tile colour as in System Settings.
    static let attentionTile = Color(nsColor: .systemBlue)
    static let tasksTile = Color(nsColor: .systemGray)

    /// Project tiles stay clear of the lamps' amber, blue, green and red, so a tile never
    /// reads as a state. System colours follow dark mode and increased contrast.
    private static let projectTiles: [NSColor] = [
        .systemIndigo, .systemPurple, .systemPink, .systemTeal, .systemBrown
    ]

    /// The same colour for a project in every launch and in every place it is shown.
    static func project(_ root: String) -> Color {
        Color(nsColor: projectTiles[ProjectInfo.colorIndex(root: root, count: projectTiles.count)])
    }
}

/// A white glyph on a small coloured square, as System Settings marks its panes. It says
/// what a row is, never how it stands: that is the lamps' job.
struct IconTile: View {
    let symbol: String
    let color: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(color, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A count on a filled capsule: the sidebar's picked item, or what asks for you.
struct FilledBadge: View {
    let count: Int
    let color: Color

    var body: some View {
        Text("\(count)")
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 18)
            .background(color, in: Capsule())
    }
}

extension Font {
    static let panelHeader = Font.system(size: 15, weight: .semibold)
    static let rowTitle = Font.system(size: 13, weight: .medium)
    /// A session's name: the loudest text in its row.
    static let sessionTitle = Font.system(size: 13, weight: .semibold)
    static let rowDetail = Font.system(size: 12)
    static let groupName = Font.system(size: 13, weight: .semibold)
    static let rowTime = Font.system(size: 11).monospacedDigit()
    static let rowMeta = Font.system(size: 11)
}

enum BellLayout {
    static let height: CGFloat = 520
    static func headerHeight(inWindow: Bool) -> CGFloat { inWindow ? 54 : 60 }
    /// Room the traffic lights take at the left of a window's title bar.
    static let trafficLightsWidth: CGFloat = 78
    static let inset: CGFloat = 14
    static func sidebarWidth(for width: CGFloat) -> CGFloat {
        min(264, max(180, width * 0.36))
    }
    static let groupRadius: CGFloat = 12
    static let rowRadius: CGFloat = 6
    /// Every small control in the header, footer and sidebar: one height, one radius.
    static let controlHeight: CGFloat = 28
    static let controlRadius: CGFloat = 6
    /// Buttons that appear inside a row on hover.
    static let inlineControlSize: CGFloat = 24
    /// A row's highlight stands in from the edges of its list, as in a menu.
    static let rowInset: CGFloat = 4
    static let rowLeading: CGFloat = 10
    static let rowGap: CGFloat = 10
    /// Where a row's text starts: past the inset, the padding, the lamp and the gap.
    static let rowTextLeading: CGFloat = rowInset + rowLeading + 12 + rowGap
    /// From this list width a row has room for both the question and where it stands:
    /// the session window, not the 600-wide panel's content pane.
    static let wideRowWidth: CGFloat = 520
    static let controlFill = Color.primary.opacity(0.065)
    static let cardFill = Color(nsColor: Palette.card)
    static let contentFill = Color(nsColor: Palette.content)
    static let hairline = Color(nsColor: .separatorColor)
    static let waitingFill = Color.amberLamp.opacity(0.14)
    /// The picked project and the keyboard's row: the muted accent, so green keeps
    /// meaning "done".
    static let selectionFill = Color.bellAccent.opacity(0.14)
    static let hoverOpacity = 0.075

    /// The sidebar needs room for its project column; the list reads best narrow.
    static func width(for style: PanelStyle) -> CGFloat {
        style == .sidebar ? 600 : 400
    }
}

/// A line icon in front of a label: one size and weight everywhere.
struct PanelSymbol: View {
    let name: String

    var body: some View {
        Image(systemName: name)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 20)
            .accessibilityHidden(true)
    }
}

/// The card that holds a project's sessions, history, and each detail section: a light
/// surface lifted by a soft shadow, outlined only when the user asked for more contrast.
struct SessionGroupSurface: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let outline = RoundedRectangle(cornerRadius: BellLayout.groupRadius, style: .continuous)
        content
            .background(BellLayout.cardFill, in: outline)
            .clipShape(outline)
            .shadow(color: .black.opacity(0.07), radius: 2.5, y: 1)
            .overlay {
                if contrast == .increased {
                    outline.strokeBorder(BellLayout.hairline).allowsHitTesting(false)
                }
            }
    }
}

/// A hairline between a card's heading and its rows, or between detail rows.
struct CardDivider: View {
    var leading: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(BellLayout.hairline.opacity(0.6))
            .frame(height: 1)
            .padding(.leading, leading)
            .accessibilityHidden(true)
    }
}

/// The quiet count next to a project name, drawn as in the sidebar.
struct CountBadge: View {
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.rowTime)
            .foregroundStyle(.secondary)
            .frame(minWidth: 22, alignment: .trailing)
    }
}

/// The branch as quiet meta text: no fill, so it never reads as a button.
struct BranchTag: View {
    let branch: String

    var body: some View {
        Label {
            Text(branch).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
        }
            .labelStyle(TightLabelStyle())
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
            .help(branch)
            .accessibilityLabel("分支 \(branch)")
    }
}

/// Icon and title with a small gap, for tags and meta lines.
struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

/// Shared pointer treatment for small controls, with native button and focus semantics.
struct BellButtonStyle: ButtonStyle {
    var radius = BellLayout.rowRadius
    /// Off when a surrounding row draws the hover itself, so the fill covers the whole row.
    var hovers = true

    func makeBody(configuration: Configuration) -> some View {
        Surface(label: configuration.label, pressed: configuration.isPressed, radius: radius, hovers: hovers)
    }

    private struct Surface<Label: View>: View {
        let label: Label
        let pressed: Bool
        let radius: CGFloat
        let hovers: Bool

        @ViewState private var hovered = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            label
                .background(Color.primary.opacity(pressed ? 0.13 : hovers && hovered ? BellLayout.hoverOpacity : 0), in: shape)
                .contentShape(shape)
                .onHover { hovered = $0 }
        }
    }
}

struct PanelHeaderSurface: ViewModifier {
    let inWindow: Bool

    func body(content: Content) -> some View {
        content
            .padding(.top, 4)
            .frame(height: BellLayout.headerHeight(inWindow: inWindow))
            .overlay(alignment: .bottom) { CardDivider() }
    }
}

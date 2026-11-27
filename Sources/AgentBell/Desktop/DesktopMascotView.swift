import AppKit
import BellCore
import Observation
import SwiftUI

@MainActor
@Observable
final class DesktopMascotState {
    var status = OverallStatus.idle
    var isVisible = false
    var mirrored = false
    var size = CGFloat(Entry.defaultDesktopSize)
    var gaze = CGSize.zero
    var watchingPointer = false
    var dragTilt: Double?
    var celebrating = false

    var needsAttention: Bool {
        switch status {
        case .waiting, .failed: true
        case .idle, .working: false
        }
    }

    var appearance: DesktopMascotAppearance {
        switch status {
        case .idle: celebrating ? .completed : .idle
        case .working: celebrating ? .completed : .working
        case .waiting: .waiting
        case .failed: .failed
        }
    }
}

enum DesktopMascotAppearance: String, CaseIterable, Identifiable {
    case idle, working, waiting, completed, failed

    var id: Self { self }

    var title: String {
        switch self {
        case .idle: "待机"
        case .working: "工作中"
        case .waiting: "等你确认"
        case .completed: "已完成"
        case .failed: "出错"
        }
    }

    var explanation: String {
        switch self {
        case .idle: "当前没有会话正在处理任务"
        case .working: "Claude 正在处理任务"
        case .waiting: "有操作等你确认"
        case .completed: "刚完成一轮任务"
        case .failed: "有会话需要检查"
        }
    }

    private var lampColors: (light: Int, dark: Int) {
        switch self {
        case .idle: (0xF6E9D5, 0xCDB494)
        case .working: (0x93DCFF, 0x2676CB)
        case .waiting: (0xFFDB82, 0xE78B24)
        case .completed: (0xAEECB6, 0x32905D)
        case .failed: (0xFFAB9F, 0xCF483D)
        }
    }

    var lampGradient: LinearGradient {
        LinearGradient(colors: [Self.color(lampColors.light), Self.color(lampColors.dark)],
                              startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    var lampGlow: Color {
        self == .idle ? .clear : Self.color(lampColors.dark).opacity(0.28)
    }

    private static func color(_ hex: Int) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }
}

/// The body and open eyes share a square canvas and align at every display scale.
struct DesktopMascotArtwork {
    let body: NSImage
    let leftEye: NSImage
    let rightEye: NSImage

    @MainActor static let bundled: Self? = {
        func image(_ name: String) -> NSImage? {
            Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "DesktopMascot")
                .flatMap { NSImage(contentsOf: $0) }
        }

        guard let body = image("Body"),
              let leftEye = image("EyeLeft"),
              let rightEye = image("EyeRight") else { return nil }

        return Self(body: body, leftEye: leftEye, rightEye: rightEye)
    }()
}

struct DesktopMascotView: View {
    let state: DesktopMascotState
    let artwork: DesktopMascotArtwork
    let size: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var blinking = false

    private var awake: Bool {
        state.isVisible && !reduceMotion && state.appearance == .idle && state.watchingPointer
    }

    var body: some View {
        DesktopMascotDrawing(
            artwork: artwork,
            appearance: state.appearance,
            size: size,
            animateRain: state.isVisible && !reduceMotion,
            openEyes: awake && !blinking,
            gaze: awake ? state.gaze : .zero,
            mirrored: state.mirrored
        )
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .rotationEffect(.degrees(reduceMotion ? 0 : state.dragTilt ?? 0))
        // The sprite nearly fills the window. Leave room at the edges while it tilts.
        .scaleEffect(reduceMotion || state.dragTilt == nil ? 1 : 0.94)
        .animation(reduceMotion ? nil : dragAnimation, value: state.dragTilt)
        .offset(y: !reduceMotion && state.appearance == .completed ? 0.8 : 0)
        .animation(reduceMotion ? nil : .spring(duration: 0.28, bounce: 0.25), value: state.appearance == .completed)
        .task(id: awake) {
            blinking = false
            guard awake else { return }
            do {
                while !Task.isCancelled {
                    try await Task.sleep(for: .milliseconds(Int.random(in: 4500...8500)))
                    blinking = true
                    try await Task.sleep(for: .milliseconds(100))
                    blinking = false
                }
            } catch {
                blinking = false
            }
        }
    }

    private var dragAnimation: Animation {
        state.dragTilt == nil ? .spring(duration: 0.32, bounce: 0.35) : .easeOut(duration: 0.12)
    }
}

/// Shared with the status guide. Only the live, visible desktop mascot animates.
struct DesktopMascotDrawing: View {
    let artwork: DesktopMascotArtwork
    let appearance: DesktopMascotAppearance
    let size: CGFloat
    var animateRain = false
    var openEyes = false
    var gaze = CGSize.zero
    var mirrored = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            sprite(artwork.body)
            Ellipse()
                .fill(appearance.lampGradient)
                .overlay { Ellipse().strokeBorder(.black.opacity(0.12), lineWidth: size * 0.009) }
                .frame(width: size * 0.191, height: size * 0.185)
                .shadow(color: appearance.lampGlow, radius: size * 0.038)
                .position(x: size * (mirrored ? 0.316 : 0.684), y: size * 0.108)
            if appearance == .idle && openEyes {
                ZStack {
                    sprite(artwork.leftEye)
                    sprite(artwork.rightEye)
                }
                .offset(gaze)
                .animation(.easeOut(duration: 0.15), value: gaze)
            } else {
                screen
                    .position(x: size * (mirrored ? 0.403 : 0.597), y: size * 0.608)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }

    private func sprite(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .scaleEffect(x: mirrored ? -1 : 1, y: 1)
    }

    private var screen: some View {
        Group {
            if appearance == .working {
                DesktopBinaryRain(animated: animateRain)
            } else {
                DesktopScreenSymbol(appearance: appearance)
            }
        }
        .frame(width: size * 0.48, height: size * 0.245)
    }
}

private struct DesktopScreenSymbol: View {
    let appearance: DesktopMascotAppearance

    var body: some View {
        Canvas { context, size in
            let phosphor = Color(red: 0.72, green: 0.89, blue: 0.51)
            if appearance == .idle {
                var eyes = Path()
                for center in [0.30, 0.70] {
                    let x = center * size.width
                    let y = size.height * 0.48
                    let radius = size.width * 0.10
                    eyes.move(to: CGPoint(x: x - radius, y: y))
                    eyes.addQuadCurve(to: CGPoint(x: x + radius, y: y),
                                      control: CGPoint(x: x, y: y + radius * 1.6))
                }
                context.stroke(eyes, with: .color(phosphor),
                               style: StrokeStyle(lineWidth: size.height * 0.14, lineCap: .round))
                return
            }

            let rows: [String] = switch appearance {
            case .waiting: ["011100000", "100010000", "000010000", "001100000", "001000000", "000000000", "001000111"]
            case .completed: ["00000001", "00000011", "00000110", "10001100", "11011000", "01110000", "00100000"]
            case .failed: ["11", "11", "11", "11", "00", "11"]
            case .idle, .working: []
            }
            guard let width = rows.first?.count else { return }
            let unit = min(size.width * 0.78 / CGFloat(width), size.height * 0.82 / CGFloat(rows.count))
            let x = (size.width - CGFloat(width) * unit) / 2
            let y = (size.height - CGFloat(rows.count) * unit) / 2
            var pixels = Path()
            for (row, line) in rows.enumerated() {
                for (column, pixel) in line.enumerated() where pixel == "1" {
                    pixels.addRect(CGRect(x: x + CGFloat(column) * unit, y: y + CGFloat(row) * unit,
                                          width: unit, height: unit))
                }
            }
            let ink = appearance == .failed ? Color(red: 0.94, green: 0.46, blue: 0.42) : phosphor
            context.fill(pixels, with: .color(ink))
        }
    }
}

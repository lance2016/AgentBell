import BellCore
import SwiftUI

enum LampKind: Equatable {
    case waiting, working, background, completed, failed, interrupted, faint

    init(_ session: Session) {
        if session.isEnded { self = .faint; return }
        switch session.state {
        case .waiting: self = .waiting
        case .working: self = .working
        case .background: self = .background
        case .completed: self = .completed
        case .failed: self = .failed
        case .interrupted: self = .interrupted
        case .idle: self = .faint
        }
    }

    var color: Color {
        switch self {
        case .waiting: return .amberLamp
        case .working, .background: return .blueLamp
        case .completed: return .greenLamp
        case .failed: return .bellRed
        case .interrupted, .faint: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

/// A session's state as a small dot; a round in progress spins instead. Colour alone must
/// not carry the state, so with "Differentiate without colour" on, each state gets its
/// own symbol instead.
struct LampView: View {
    let kind: LampKind

    @Environment(\.accessibilityDifferentiateWithoutColor) private var withoutColor

    var body: some View {
        Group {
            if withoutColor {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
            } else if kind == .working || kind == .background {
                SpinnerLamp(color: kind.color)
            } else {
                Circle()
                    .fill(kind == .faint || kind == .interrupted ? kind.color.opacity(0.55) : kind.color)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 12, height: 12)
        .foregroundStyle(kind.color)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch kind {
        case .waiting: "bell.fill"
        case .working: "waveform"
        case .background: "ellipsis"
        case .completed: "checkmark"
        case .failed: "exclamationmark"
        case .interrupted: "pause"
        case .faint: "minus"
        }
    }
}

extension EnvironmentValues {
    /// Off while the window holding the lamps is hidden. A timeline keeps ticking in a
    /// window that is ordered out, and the rows' spinners cost a quarter of a core.
    @Entry var lampsAnimate = true
}

/// A faint ring with a short arc going round it: busy, without asking for anything.
/// With Reduce Motion on, the arc stands still.
private struct SpinnerLamp: View {
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.lampsAnimate) private var animate

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion || !animate)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.1) / 1.1
            ZStack {
                Circle().stroke(color.opacity(0.22), lineWidth: 1.6)
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(reduceMotion ? -90 : turn * 360))
            }
            .frame(width: 9, height: 9)
        }
    }
}

import AppKit
import QuartzCore
import SwiftUI

/// Core Animation moves the digit columns without redrawing the SwiftUI desktop icon.
struct DesktopBinaryRain: NSViewRepresentable {
    let animated: Bool

    func makeNSView(context: Context) -> BinaryRainView { BinaryRainView() }

    func updateNSView(_ view: BinaryRainView, context: Context) {
        view.animated = animated
    }
}

final class BinaryRainView: NSView {
    private struct Stream {
        let digits: String
        let duration: CFTimeInterval
        let phase: Double
    }

    private static let streams = [
        Stream(digits: "01010", duration: 2.8, phase: 0.37),
        Stream(digits: "1011", duration: 2.4, phase: 0.59),
        Stream(digits: "10010", duration: 3.1, phase: 0.45),
        Stream(digits: "0110", duration: 2.6, phase: 0.69),
        Stream(digits: "10101", duration: 3.0, phase: 0.51),
    ]
    private static let zero = ["111", "101", "101", "101", "111"]
    private static let one = ["010", "110", "010", "010", "111"]

    private let display = CALayer()
    private var renderedSize = CGSize.zero
    private var renderedAnimated = false

    var animated = false {
        didSet {
            if animated != oldValue { rebuildIfNeeded() }
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        display.masksToBounds = true
        layer?.addSublayer(display)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        rebuildIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        rebuildIfNeeded()
    }

    private func rebuildIfNeeded() {
        let size = bounds.size
        let play = animated && window != nil
        guard size.width > 0, size.height > 0,
              size != renderedSize || play != renderedAnimated else { return }
        renderedSize = size
        renderedAnimated = play

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        display.frame = bounds
        display.sublayers = nil
        let columnWidth = size.width / CGFloat(Self.streams.count)
        let unit = min(columnWidth * 0.21, size.height * 0.047)
        for (index, stream) in Self.streams.enumerated() {
            let column = CAReplicatorLayer()
            column.anchorPoint = .zero
            let tailHeight = CGFloat(stream.digits.count * 6) * unit
            column.bounds = CGRect(x: 0, y: 0, width: 3 * unit, height: tailHeight)
            let x = (CGFloat(index) + 0.5) * columnWidth - 1.5 * unit
            // A second tail follows the first. Even at the loop boundary some digits stay on screen.
            let period = max(tailHeight + 4 * unit, size.height + 2 * unit)
            column.instanceCount = 2
            column.instanceTransform = CATransform3DMakeTranslation(0, period, 0)
            column.position = CGPoint(x: x, y: -period * stream.phase)

            for (row, digit) in stream.digits.enumerated() {
                let glyph = CAShapeLayer()
                glyph.frame = CGRect(x: 0, y: CGFloat(row * 6) * unit, width: 3 * unit, height: 5 * unit)
                glyph.path = Self.glyph(digit, unit: unit)
                let alpha = [1.0, 0.82, 0.68, 0.54, 0.43][row]
                glyph.fillColor = NSColor(srgbRed: 0.72, green: 0.98, blue: 0.45, alpha: alpha).cgColor
                column.addSublayer(glyph)
            }
            display.addSublayer(column)

            if play {
                let fall = CABasicAnimation(keyPath: "position.y")
                fall.fromValue = 0
                fall.toValue = -period
                fall.duration = stream.duration
                fall.beginTime = column.convertTime(CACurrentMediaTime(), from: nil) - stream.phase * stream.duration
                fall.repeatCount = .infinity
                column.add(fall, forKey: "fall")
            }
        }
        CATransaction.commit()
    }

    private static func glyph(_ digit: Character, unit: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let rows = digit == "0" ? zero : one
        for (row, line) in rows.enumerated() {
            for (column, pixel) in line.enumerated() where pixel == "1" {
                path.addRect(CGRect(x: CGFloat(column) * unit, y: CGFloat(4 - row) * unit,
                                    width: unit, height: unit))
            }
        }
        return path
    }
}

import AppKit
import BellCore
import SwiftUI

/// The bubbles beside the desktop icon. They say what the system notifications say; a
/// click goes back to the session's terminal. A question or a failure stays until the
/// session moves on; a finished round fades once you have had time to read it: the
/// clock stops while the pointer rests on the bubble or you are away from the computer.
@MainActor
final class BubbleController {
    var onOpen: ((String) -> Void)?
    /// Settings › 通知 can turn the bubbles off.
    var enabled = true { didSet { if !enabled { clear() } } }
    var iconVisible = false { didSet { if !iconVisible { clear() } } }

    private let icon: NSWindow
    private let panel: NSPanel
    private let hosting: FirstClickHostingView<BubbleStack>
    private var queue = BubbleQueue()
    private var expiry: [String: Task<Void, Never>] = [:]
    /// Seconds of attention each fading bubble still has.
    private var remaining: [String: TimeInterval] = [:]

    /// No key or pointer event for this long and the user counts as away.
    private static let awayAfter: TimeInterval = 30

    init(icon: NSWindow) {
        self.icon = icon
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        hosting = FirstClickHostingView(rootView: BubbleStack(items: [], open: { _ in }, close: { _ in }, hover: { _, _ in }))
        panel.contentView = hosting
    }

    func apply(_ changes: Notices.Changes) {
        guard enabled && iconVisible else { return }
        queue.apply(changes)
        for notice in changes.post where BubbleQueue.expires(notice) {
            schedule(notice.id, after: BubbleQueue.lifetime)
        }
        render()
    }

    /// Counts down only the seconds the user is at the computer.
    private func schedule(_ id: String, after seconds: TimeInterval) {
        expiry[id]?.cancel()
        remaining[id] = seconds
        expiry[id] = Task { [weak self] in
            while (self?.remaining[id] ?? 0) > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                if Self.userIsActive { self?.remaining[id]? -= 1 }
            }
            self?.remove(id)
        }
    }

    /// Reading a bubble stops its clock; leaving it gives a few more seconds.
    private func hover(_ notice: Notice, inside: Bool) {
        guard BubbleQueue.expires(notice), queue.items.contains(where: { $0.id == notice.id }) else { return }
        if inside {
            expiry.removeValue(forKey: notice.id)?.cancel()
        } else {
            schedule(notice.id, after: max(remaining[notice.id] ?? 0, BubbleQueue.lingerAfterHover))
        }
    }

    private static var userIsActive: Bool {
        // ~0 is kCGAnyInputEventType: any key, pointer or scroll event.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!) < awayAfter
    }

    func containsPointer(_ pointer: CGPoint) -> Bool {
        panel.isVisible && panel.frame.contains(pointer)
    }

    /// Follows the icon while it is dragged or changes shape.
    func reposition() {
        guard panel.isVisible else { return }
        place()
    }

    private func remove(_ id: String) {
        expiry.removeValue(forKey: id)?.cancel()
        remaining.removeValue(forKey: id)
        queue.remove(id)
        render()
    }

    private func clear() {
        expiry.values.forEach { $0.cancel() }
        expiry = [:]
        remaining = [:]
        queue = BubbleQueue()
        render()
    }

    private func render() {
        guard !queue.items.isEmpty else {
            hide()
            return
        }
        hosting.rootView = BubbleStack(
            items: queue.items,
            open: { [weak self] notice in
                self?.remove(notice.id)
                self?.onOpen?(notice.session)
            },
            close: { [weak self] notice in self?.remove(notice.id) },
            hover: { [weak self] notice, inside in self?.hover(notice, inside: inside) }
        )
        place()
        show()
    }

    /// Fades in, so a bubble arrives instead of popping up.
    private func show() {
        if !panel.isVisible { panel.alphaValue = 0 }
        panel.orderFrontRegardless()
        if panel.alphaValue < 1 { fade(to: 1, duration: 0.15) }
    }

    /// Fades out; a bubble that arrives meanwhile cancels the hiding.
    private func hide() {
        guard panel.isVisible else { return }
        fade(to: 0, duration: 0.2) { [weak self] in
            guard let self, self.queue.items.isEmpty else { return }
            self.panel.orderOut(nil)
        }
    }

    private func fade(to alpha: CGFloat, duration: TimeInterval, then done: (@MainActor @Sendable () -> Void)? = nil) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            panel.alphaValue = alpha
            done?()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = alpha
        } completionHandler: {
            MainActor.assumeIsolated { done?() }
        }
    }

    private func place() {
        guard let screen = icon.screen ?? NSScreen.main else { return }
        let size = hosting.fittingSize
        panel.setFrame(DesktopPlacement.bubbleFrame(size: size, icon: icon.frame, visible: screen.visibleFrame), display: true)
    }
}

private struct BubbleStack: View {
    let items: [Notice]
    let open: (Notice) -> Void
    let close: (Notice) -> Void
    let hover: (Notice, Bool) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(items, id: \.id) { notice in
                BubbleCard(notice: notice, open: { open(notice) }, close: { close(notice) },
                           hover: { hover(notice, $0) })
            }
        }
        // Room for the cards' shadow inside the transparent panel.
        .padding(8)
    }
}

private struct BubbleCard: View {
    let notice: Notice
    let open: () -> Void
    let close: () -> Void
    let hover: (Bool) -> Void

    @ViewState private var hovered = false

    private var lamp: LampKind {
        switch notice.kind {
        case .waiting: .waiting
        case .failed: .failed
        case .done: .completed
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            LampView(kind: lamp).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(notice.title)
                    .font(.rowTitle)
                    .lineLimit(1)
                if let subtitle = notice.subtitle {
                    Text(subtitle)
                        .font(.rowDetail)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let body = notice.body {
                    Text(body)
                        .font(.rowDetail)
                        .foregroundStyle(lamp == .waiting ? Color.amberText : .secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 280, alignment: .leading)
        // SwiftUI's materials blur only what is inside this transparent panel, which is
        // nothing: they come out a thin grey that the desktop shows through. This one
        // blurs what is behind the panel, like a notification banner.
        // A wash of the window colour on top keeps the text readable over a dark terminal
        // or a coloured wallpaper; pointing at the bubble deepens it a step, as on a row.
        .background(
            ZStack {
                BubbleMaterial()
                Color(nsColor: .windowBackgroundColor).opacity(0.75)
                Color.primary.opacity(hovered ? 0.04 : 0)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        )
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(BellLayout.hairline, lineWidth: 0.5))
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.regularMaterial))
                }
                .buttonStyle(.plain)
                .padding(6)
                .accessibilityLabel("关闭提醒")
            }
        }
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onTapGesture(perform: open)
        .animation(.easeOut(duration: 0.12), value: hovered)
        .onHover { inside in
            hovered = inside
            hover(inside)
        }
        .help("回到终端")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "回到终端", open)
    }
}

/// The notification-banner backdrop. Always active: the panel never becomes key, and an
/// inactive material turns flat grey.
private struct BubbleMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

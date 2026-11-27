import AppKit
import BellCore
import Carbon.HIToolbox
import Observation
import os

/// The system-wide shortcuts set in Settings › 通用. Carbon's hot keys need no
/// accessibility permission, unlike watching every key press.
@MainActor
@Observable
final class GlobalHotKeys {
    static let shared = GlobalHotKeys()

    /// Shortcuts macOS would not register, most likely held by another app.
    private(set) var taken: Set<Shortcut> = []

    @ObservationIgnored var onPress: ((Shortcut) -> Void)?
    @ObservationIgnored private var refs: [Shortcut: EventHotKeyRef] = [:]
    /// What was last asked of macOS for each shortcut, registered or not.
    @ObservationIgnored private var requested: [Shortcut: HotKey] = [:]
    @ObservationIgnored private var handler: EventHandlerRef?
    /// While Settings records a new shortcut, so the old one does not fire instead.
    @ObservationIgnored private var paused = false
    @ObservationIgnored private let log = Logger(subsystem: "com.agentbell.AgentBell", category: "shortcuts")

    private static let signature: OSType = 0x4167_426C // "AgBl"

    static func key(for shortcut: Shortcut) -> HotKey? {
        HotKey.stored(UserDefaults.standard.data(forKey: shortcut.defaultsKey), default: shortcut.defaultKey)
    }

    static func set(_ key: HotKey?, for shortcut: Shortcut) {
        UserDefaults.standard.set(HotKey.encoded(key), forKey: shortcut.defaultsKey)
    }

    /// Registers what Settings holds; a shortcut that did not change is left alone.
    func apply() {
        installHandler()
        for (index, shortcut) in Shortcut.allCases.enumerated() {
            let wanted = paused ? nil : Self.key(for: shortcut)
            guard wanted != requested[shortcut] else { continue }
            if let ref = refs.removeValue(forKey: shortcut) { UnregisterEventHotKey(ref) }
            requested[shortcut] = wanted
            taken.remove(shortcut)
            guard let wanted else { continue }
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(wanted.keyCode, wanted.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs[shortcut] = ref
            } else {
                taken.insert(shortcut)
                log.error("registering \(shortcut.rawValue, privacy: .public) failed: \(status)")
            }
        }
    }

    func setPaused(_ paused: Bool) {
        self.paused = paused
        apply()
    }

    private func installHandler() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id
            )
            guard status == noErr, id.signature == GlobalHotKeys.signature else { return OSStatus(eventNotHandledErr) }
            let index = Int(id.id) - 1
            // Carbon delivers hot keys on the main thread.
            MainActor.assumeIsolated {
                guard Shortcut.allCases.indices.contains(index) else { return }
                GlobalHotKeys.shared.onPress?(Shortcut.allCases[index])
            }
            return noErr
        }, 1, &spec, nil, &handler)
    }
}

extension HotKey {
    /// The key event Settings recorded, in Carbon's terms.
    init(event: NSEvent) {
        let flags = event.modifierFlags
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= HotKey.command }
        if flags.contains(.shift) { modifiers |= HotKey.shift }
        if flags.contains(.option) { modifiers |= HotKey.option }
        if flags.contains(.control) { modifiers |= HotKey.control }
        let code = UInt32(event.keyCode)
        self.init(keyCode: code, modifiers: modifiers,
                  key: HotKey.keyName(keyCode: code, characters: event.charactersIgnoringModifiers))
    }
}

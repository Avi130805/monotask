import Carbon.HIToolbox
import Foundation

/// A system-wide shortcut registered through Carbon, which needs no accessibility permission.
final class HotKey {
    struct Combo {
        let keyCode: Int
        let modifiers: Int
        let label: String
    }

    /// Tried in order until one is free.
    static let defaults: [Combo] = [
        Combo(keyCode: kVK_Space, modifiers: optionKey, label: "⌥Space"),
        Combo(keyCode: kVK_Space, modifiers: optionKey | controlKey, label: "⌃⌥Space"),
        Combo(keyCode: kVK_ANSI_N, modifiers: optionKey | controlKey, label: "⌃⌥N"),
    ]

    /// The prompter's toggle, tried the same way.
    static let prompterDefaults: [Combo] = [
        Combo(keyCode: kVK_ANSI_P, modifiers: optionKey, label: "⌥P"),
        Combo(keyCode: kVK_ANSI_P, modifiers: optionKey | controlKey, label: "⌃⌥P"),
    ]

    let label: String
    private let ref: EventHotKeyRef
    private let id: UInt32

    nonisolated(unsafe) private static var actions: [UInt32: () -> Void] = [:]
    nonisolated(unsafe) private static var nextID: UInt32 = 1
    nonisolated(unsafe) private static var handlerInstalled = false

    private init(ref: EventHotKeyRef, id: UInt32, label: String) {
        self.ref = ref
        self.id = id
        self.label = label
    }

    deinit {
        UnregisterEventHotKey(ref)
        HotKey.actions[id] = nil
    }

    static func registerFirstAvailable(_ combos: [Combo], action: @escaping () -> Void) -> HotKey? {
        for combo in combos {
            if let hotKey = register(combo, action: action) { return hotKey }
            NSLog("Monotask: \(combo.label) is taken, trying the next shortcut")
        }
        return nil
    }

    static func register(_ combo: Combo, action: @escaping () -> Void) -> HotKey? {
        installHandlerIfNeeded()
        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E58_5458), id: id) // "NXTX"
        let status = RegisterEventHotKey(UInt32(combo.keyCode), UInt32(combo.modifiers), hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        actions[id] = action
        return HotKey(ref: ref, id: id, label: combo.label)
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return status }
            DispatchQueue.main.async { HotKey.actions[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

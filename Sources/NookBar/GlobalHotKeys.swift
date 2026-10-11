import AppKit
import Carbon

@MainActor
final class GlobalHotKeys {
    private var handler: EventHandlerRef?
    private var registrations: [EventHotKeyRef] = []
    var onAction: ((Preferences.ShortcutAction) -> Void)?
    private let signature: OSType = 0x4E4F4F4B // NOOK

    func update(_ preferences: Preferences) -> String? {
        clear()
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let result = InstallEventHandler(GetEventDispatcherTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                               MemoryLayout<EventHotKeyID>.size, nil, &id)
                guard status == noErr else { return status }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<GlobalHotKeys>.fromOpaque(context).takeUnretainedValue()
                    guard id.signature == owner.signature, let action = Preferences.ShortcutAction(rawValue: Int(id.id)) else { return OSStatus(eventNotHandledErr) }
                    owner.onAction?(action); return noErr
                }
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard result == noErr else { return "Could not install keyboard shortcuts (\(result))." }
        }
        var failures: [String] = []
        for action in Preferences.ShortcutAction.allCases {
            guard let shortcut = preferences.shortcut(action) else { continue }
            guard shortcut.valid else { failures.append("\(action.title): invalid shortcut"); continue }
            var modifiers: UInt32 = 0
            if shortcut.flags.contains(.command) { modifiers |= UInt32(cmdKey) }
            if shortcut.flags.contains(.control) { modifiers |= UInt32(controlKey) }
            if shortcut.flags.contains(.option) { modifiers |= UInt32(optionKey) }
            if shortcut.flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
            var reference: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(action.rawValue))
            let result = RegisterEventHotKey(shortcut.keyCode, modifiers, id, GetEventDispatcherTarget(), 0, &reference)
            if result == noErr, let reference { registrations.append(reference) }
            else { failures.append("\(action.title): shortcut is unavailable (\(result))") }
        }
        return failures.isEmpty ? nil : failures.joined(separator: ". ")
    }
    func clear() { for reference in registrations { UnregisterEventHotKey(reference) }; registrations.removeAll() }
    func stop() { clear(); if let handler { RemoveEventHandler(handler) }; handler = nil }
}

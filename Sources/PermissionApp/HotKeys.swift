import Carbon.HIToolbox
import Foundation
import PermissionCore

/// Global ⌃⌥Return (allow) and ⌃⌥Escape (deny), through Carbon `RegisterEventHotKey`,
/// which needs no Accessibility permission. Handlers run on the main thread.
/// Each physical press fires once: a held key does nothing more until it is released.
final class HotKeys {
    private static let signature: OSType = 0x5050_4F50 // "PPOP"
    private static let allowID: UInt32 = 1
    private static let denyID: UInt32 = 2

    private let onAllow: () -> Void
    private let onDeny: () -> Void
    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var latch = HotKeyLatch()

    init(onAllow: @escaping () -> Void, onDeny: @escaping () -> Void) {
        self.onAllow = onAllow
        self.onDeny = onDeny
    }

    deinit { unregister() }

    /// Installs the handler and both hotkeys. A combination another app already holds is
    /// logged and skipped; the cards still work by click.
    func register() {
        guard handler == nil else { return }
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                        EventParamType(typeEventHotKeyID), nil,
                                        MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard got == noErr, id.signature == HotKeys.signature else {
                return OSStatus(eventNotHandledErr)
            }
            let hotKeys = Unmanaged<HotKeys>.fromOpaque(context).takeUnretainedValue()
            if GetEventKind(event) == UInt32(kEventHotKeyReleased) {
                hotKeys.released(id.id)
            } else {
                hotKeys.pressed(id.id)
            }
            return noErr
        }, eventTypes.count, &eventTypes, context, &handler)
        guard status == noErr else {
            NSLog("%@", "hotkeys: InstallEventHandler failed (\(status)); cards still work by click")
            return
        }

        let modifiers = UInt32(controlKey | optionKey)
        add(keyCode: UInt32(kVK_Return), modifiers: modifiers, id: Self.allowID, name: "⌃⌥Return")
        add(keyCode: UInt32(kVK_Escape), modifiers: modifiers, id: Self.denyID, name: "⌃⌥Escape")
    }

    func unregister() {
        for ref in hotKeys { UnregisterEventHotKey(ref) }
        hotKeys = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func add(keyCode: UInt32, modifiers: UInt32, id: UInt32, name: String) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            hotKeys.append(ref)
        } else {
            NSLog("%@", "hotkeys: \(name) unavailable (status \(status)); cards still work by click")
        }
    }

    private func released(_ id: UInt32) {
        latch.release(id)
    }

    private func pressed(_ id: UInt32) {
        guard latch.press(id) else { return } // still held since the last press
        switch id {
        case Self.allowID: onAllow()
        case Self.denyID: onDeny()
        default: break
        }
    }
}

import Carbon.HIToolbox
import Foundation

final class HotKeyManager {
    var onHoldPressed: (() -> Void)?
    var onHoldReleased: (() -> Void)?
    var onTogglePressed: (() -> Void)?

    private var holdRef: EventHotKeyRef?
    private var toggleRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init() {
        installHandlerIfNeeded()
    }

    deinit {
        unregisterAll()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
        }
    }

    func register(hold: HotkeyConfig, toggle: HotkeyConfig) {
        unregisterAll()

        Log.hotkeys.info("Registering hotkeys hold(keyCode=\(hold.keyCode), mods=\(hold.modifiers)) toggle(keyCode=\(toggle.keyCode), mods=\(toggle.modifiers))")

        var eventHotKeyID = EventHotKeyID(signature: OSType(0x57535052) /* 'WSPR' */, id: 1)
        RegisterEventHotKey(
            hold.keyCode,
            hold.modifiers,
            eventHotKeyID,
            GetApplicationEventTarget(),
            0,
            &holdRef
        )

        eventHotKeyID = EventHotKeyID(signature: OSType(0x57535052) /* 'WSPR' */, id: 2)
        RegisterEventHotKey(
            toggle.keyCode,
            toggle.modifiers,
            eventHotKeyID,
            GetApplicationEventTarget(),
            0,
            &toggleRef
        )
    }

    private func unregisterAll() {
        if let holdRef {
            UnregisterEventHotKey(holdRef)
            self.holdRef = nil
        }
        if let toggleRef {
            UnregisterEventHotKey(toggleRef)
            self.toggleRef = nil
        }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        InstallEventHandler(
            GetApplicationEventTarget(),
            HotKeyManager.eventHandler,
            eventTypes.count,
            &eventTypes,
            userData,
            &handlerRef
        )
    }

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()

        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr else { return noErr }

        let kind = GetEventKind(event)
        switch hotKeyID.id {
        case 1:
            if kind == UInt32(kEventHotKeyPressed) {
                manager.onHoldPressed?()
            } else if kind == UInt32(kEventHotKeyReleased) {
                manager.onHoldReleased?()
            }
        case 2:
            if kind == UInt32(kEventHotKeyPressed) {
                manager.onTogglePressed?()
            }
        default:
            break
        }

        return noErr
    }
}

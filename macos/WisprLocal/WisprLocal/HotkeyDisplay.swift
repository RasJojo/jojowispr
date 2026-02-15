import Carbon.HIToolbox
import AppKit
import Foundation

enum HotkeyDisplay {
    static func format(_ hotkey: HotkeyConfig) -> String {
        var parts: [String] = []
        if hotkey.modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }
        if hotkey.modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if hotkey.modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if hotkey.modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        parts.append(keyName(for: hotkey.keyCode))
        return parts.joined()
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        return modifiers
    }

    private static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        case kVK_Space: return "Space"
        case kVK_Return: return "Enter"
        case kVK_Escape: return "Esc"
        case kVK_Tab: return "Tab"
        case kVK_Delete: return "⌫"
        default:
            if let s = translateKeyCode(keyCode) { return s }
            return "Key\(keyCode)"
        }
    }

    private static func translateKeyCode(_ keyCode: UInt32) -> String? {
        guard
            let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = unsafeBitCast(raw, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return nil }

        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)

        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 8)
        var realLength: Int = 0
        let modifiers: UInt32 = 0
        let keyboardType = UInt32(LMGetKbdType())

        let status = UCKeyTranslate(
            layout,
            UInt16(keyCode),
            UInt16(kUCKeyActionDisplay),
            modifiers,
            keyboardType,
            UInt32(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &realLength,
            &chars
        )

        guard status == noErr, realLength > 0 else { return nil }
        return String(utf16CodeUnits: chars, count: realLength).uppercased()
    }
}

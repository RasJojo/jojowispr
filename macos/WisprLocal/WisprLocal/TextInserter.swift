import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

@MainActor
final class TextInserter {
    func insert(text: String, mode: InsertionMode) -> Bool {
        guard Permissions.requestAccessibilityIfNeeded() else {
            Log.paste.error("Insert blocked: Accessibility not granted")
            return false
        }

        switch mode {
        case .type:
            return typeText(text)
        case .paste:
            return pasteText(text)
        }
    }

    private func typeText(_ text: String) -> Bool {
        Log.paste.info("Type: inserting \(text.count, privacy: .public) chars")

        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            Log.paste.error("Type: failed to create CGEventSource")
            return false
        }

        // Chunk by grapheme clusters to avoid splitting emoji/surrogate pairs.
        let chars = Array(text)
        let chunkSize = 64
        var idx = 0
        while idx < chars.count {
            let end = min(idx + chunkSize, chars.count)
            let chunk = String(chars[idx..<end])
            postUnicodeString(chunk, source: source)
            idx = end
        }

        return true
    }

    private func postUnicodeString(_ chunk: String, source: CGEventSource) {
        let utf16 = Array(chunk.utf16)
        guard
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        else {
            Log.paste.error("Type: failed to create CGEvent")
            return
        }

        utf16.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
        }

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func pasteText(_ text: String) -> Bool {
        Log.paste.info("Paste: inserting \(text.count, privacy: .public) chars")

        let pb = NSPasteboard.general
        // Keep paste fast/reliable: copying full pasteboard items can block/hang (promised data, large items).
        // We overwrite the clipboard. (Optional later: add a safe restore mode.)
        _ = pb.clearContents()
        _ = pb.setString(text, forType: .string)

        sendPasteShortcut()
        return true
    }

    private func sendPasteShortcut() {
        Log.paste.info("Paste: sending Cmd+V CGEvent")
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}

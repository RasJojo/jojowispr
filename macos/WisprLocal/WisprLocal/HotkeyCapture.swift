import AppKit
import Carbon.HIToolbox
import SwiftUI

@MainActor
struct HotkeyCapture: NSViewRepresentable {
    @Binding var isRecording: Bool
    var onCaptured: (HotkeyConfig) -> Void
    var onCancelled: () -> Void
    var onHint: (String?) -> Void

    func makeNSView(context: Context) -> HotkeyCaptureView {
        let view = HotkeyCaptureView()
        view.onCaptured = onCaptured
        view.onCancelled = onCancelled
        view.onHint = onHint
        return view
    }

    func updateNSView(_ nsView: HotkeyCaptureView, context: Context) {
        nsView.isRecording = isRecording
        if isRecording {
            onHint(nil)
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

@MainActor
final class HotkeyCaptureView: NSView {
    var isRecording = false
    var onCaptured: ((HotkeyConfig) -> Void)?
    var onCancelled: (() -> Void)?
    var onHint: ((String?) -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        handle(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        handle(event)
        return true
    }

    private func handle(_ event: NSEvent) {
        guard isRecording else { return }

        // Escape cancels.
        if event.keyCode == 53 {
            onCancelled?()
            return
        }

        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift, .function])
        if flags.contains(.function) {
            // We can't register Fn as a modifier using Carbon hotkeys.
            onHint?("Fn isn't supported as a global hotkey modifier. Use ⌘/⌥/⌃/⇧ instead.")
        }

        let modifiers = HotkeyDisplay.carbonModifiers(from: flags)
        let keyCode = UInt32(event.keyCode)

        // Prevent accidental "Space" / letters with no modifiers.
        if modifiers == 0 && !Self.allowsNoModifier(keyCode) {
            NSSound.beep()
            onHint?("Add at least one modifier (⌘ ⌥ ⌃ ⇧), or use a function key.")
            return
        }

        onCaptured?(HotkeyConfig(keyCode: keyCode, modifiers: modifiers))
    }

    private static func allowsNoModifier(_ keyCode: UInt32) -> Bool {
        switch Int(keyCode) {
        case kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
             kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
             kVK_Escape, kVK_Return, kVK_Tab, kVK_Delete, kVK_ForwardDelete,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            return true
        default:
            return false
        }
    }
}


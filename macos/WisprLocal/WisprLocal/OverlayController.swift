import AppKit
import SwiftUI

@MainActor
final class OverlayController {
    enum Mode: Equatable {
        case listening
        case transcribing
    }

    private let model = OverlayUIModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(mode: Mode) {
        hideTask?.cancel()
        ensurePanel()
        model.mode = mode
        model.message = nil

        guard let panel else { return }
        if !panel.isVisible {
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1.0
            }
        }
    }

    func setLevel(_ level: Double) {
        model.level = level
    }

    func flash(message: String) {
        hideTask?.cancel()
        ensurePanel()
        model.message = message
        guard let panel else { return }
        if !panel.isVisible {
            panel.alphaValue = 0.0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1.0
            }
        }
    }

    func hideAfterDelay(seconds: Double) {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0.0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    private func ensurePanel() {
        if panel != nil { return }

        let content = OverlayView()
            .environmentObject(model)
        let hosting = NSHostingView(rootView: content)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 72),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.ignoresMouseEvents = true

        hosting.frame = panel.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        position(panel: panel)
        self.panel = panel
    }

    private func position(panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        let x = frame.midX - size.width / 2
        let y = frame.maxY - size.height - 24
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class OverlayUIModel: ObservableObject {
    @Published var mode: OverlayController.Mode = .listening
    @Published var message: String?
    @Published var level: Double = 0.0
}


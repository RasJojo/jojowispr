import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(settings: SettingsStore) {
        if window == nil {
            let view = SettingsView()
                .environmentObject(settings)

            let hosting = NSHostingController(rootView: view)
            hosting.view.frame = NSRect(x: 0, y: 0, width: 520, height: 560)

            let window = NSWindow(contentViewController: hosting)
            window.title = "WisprLocal Settings"
            window.setContentSize(NSSize(width: 560, height: 620))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }

        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}


import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory keeps the app out of the Dock (LSUIElement is also set).
        NSApp.setActivationPolicy(.accessory)
        AppModel.shared.start()
    }
}


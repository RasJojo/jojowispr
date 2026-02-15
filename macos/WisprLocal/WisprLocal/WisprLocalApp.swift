import SwiftUI

@main
struct WisprLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuView()
                .environmentObject(model)
        } label: {
            Image(systemName: model.dictation.isRecording ? "mic.fill" : "mic")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .frame(width: 520)
        }
    }
}

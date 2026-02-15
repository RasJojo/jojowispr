import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(model.dictation.isRecording ? "Stop Dictation" : "Start Dictation") {
                Task { @MainActor in
                    if model.dictation.isRecording {
                        await model.dictation.stopRecordingAndTranscribe(trigger: .menu)
                    } else {
                        model.dictation.startRecording(trigger: .menu)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Server: \(model.settings.serverURL)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if model.settings.language.isEmpty {
                    Text("Language: Auto")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Language: \(model.settings.language)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            Button("Settings...") {
                model.showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}

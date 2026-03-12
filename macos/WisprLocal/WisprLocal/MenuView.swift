import SwiftUI

struct MenuView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(model.dictation.isRecordingMicDictation ? "Stop Dictation" : "Start Dictation") {
                Task { @MainActor in
                    if model.dictation.isRecordingMicDictation {
                        await model.dictation.stopRecordingAndTranscribe(trigger: .menu)
                    } else if !model.dictation.isRecording {
                        model.dictation.startRecording(trigger: .menu)
                    }
                }
            }
            .disabled(model.dictation.isRecordingMeetingCapture)

            Button(model.dictation.isRecordingMeetingCapture ? "Stop Meeting Capture" : "Start Meeting Capture") {
                Task { @MainActor in
                    if model.dictation.isRecordingMeetingCapture {
                        await model.dictation.stopRecordingAndTranscribe(trigger: .meetingMenu)
                    } else if !model.dictation.isRecording {
                        model.dictation.startMeetingCapture(trigger: .meetingMenu)
                    }
                }
            }
            .disabled(model.dictation.isRecordingMicDictation)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                Text("Model: \(URL(fileURLWithPath: model.settings.modelPath).lastPathComponent)")
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

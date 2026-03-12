import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings = SettingsStore()
    let dictation = DictationController()

    private let hotkeys = HotKeyManager()
    private let settingsWindow = SettingsWindowController()
    private var cancellables = Set<AnyCancellable>()

    private init() {
        // Forward nested ObservableObject updates.
        settings.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        dictation.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func start() {
        dictation.configure(settings: settings)

        hotkeys.onHoldPressed = { [weak self] in
            Task { @MainActor in
                self?.dictation.startRecording(trigger: .holdHotkey)
            }
        }

        hotkeys.onHoldReleased = { [weak self] in
            Task { @MainActor in
                await self?.dictation.stopRecordingAndTranscribe(trigger: .holdHotkey)
            }
        }

        hotkeys.onTogglePressed = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.dictation.isRecordingMicDictation {
                    await self.dictation.stopRecordingAndTranscribe(trigger: .toggleHotkey)
                } else if !self.dictation.isRecording {
                    self.dictation.startRecording(trigger: .toggleHotkey)
                }
            }
        }

        hotkeys.onMeetingTogglePressed = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.dictation.isRecordingMeetingCapture {
                    await self.dictation.stopRecordingAndTranscribe(trigger: .meetingHotkey)
                } else if !self.dictation.isRecording {
                    self.dictation.startMeetingCapture(trigger: .meetingHotkey)
                }
            }
        }

        hotkeys.register(
            hold: settings.holdHotkey,
            toggle: settings.toggleHotkey,
            meeting: settings.meetingHotkey
        )

        settings.onHotkeysChanged = { [weak self] hold, toggle, meeting in
            self?.hotkeys.register(hold: hold, toggle: toggle, meeting: meeting)
        }

        // If a previously saved path is stale (e.g. after app updates), fall back to current preferred model.
        if !FileManager.default.fileExists(atPath: settings.modelPath) {
            let fallback = TranscriptionClient.preferredModelPath()
            if FileManager.default.fileExists(atPath: fallback) {
                settings.modelPath = fallback
            } else {
                // First-run: prompt settings if no model is available yet.
                showSettings()
            }
        }
    }

    func showSettings() {
        settingsWindow.show(settings: settings)
    }
}

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
                if self.dictation.isRecording {
                    await self.dictation.stopRecordingAndTranscribe(trigger: .toggleHotkey)
                } else {
                    self.dictation.startRecording(trigger: .toggleHotkey)
                }
            }
        }

        hotkeys.register(
            hold: settings.holdHotkey,
            toggle: settings.toggleHotkey
        )

        settings.onHotkeysChanged = { [weak self] hold, toggle in
            self?.hotkeys.register(hold: hold, toggle: toggle)
        }

        // First-run: prompt settings if the API key isn't set.
        if settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            showSettings()
        }
    }

    func showSettings() {
        settingsWindow.show(settings: settings)
    }
}

import Carbon.HIToolbox
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    var onHotkeysChanged: ((HotkeyConfig, HotkeyConfig, HotkeyConfig) -> Void)?

    // Updated by DictationController (not persisted).
    @Published var lastMetrics: DictationMetrics?
    @Published var debugStatus: String = ""

    @Published var modelPath: String {
        didSet { UserDefaults.standard.set(modelPath, forKey: Keys.modelPath) }
    }

    @Published var whisperBinaryPath: String {
        didSet { UserDefaults.standard.set(whisperBinaryPath, forKey: Keys.whisperBinaryPath) }
    }

    @Published var transcriptionTimeoutSeconds: Double {
        didSet { UserDefaults.standard.set(transcriptionTimeoutSeconds, forKey: Keys.transcriptionTimeoutSeconds) }
    }

    /// Empty string = auto
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: Keys.language) }
    }

    @Published var pauseMediaWhileDictating: Bool {
        didSet { UserDefaults.standard.set(pauseMediaWhileDictating, forKey: Keys.pauseMediaWhileDictating) }
    }

    @Published var includeMicrophoneInMeetingCapture: Bool {
        didSet { UserDefaults.standard.set(includeMicrophoneInMeetingCapture, forKey: Keys.includeMicrophoneInMeetingCapture) }
    }

    @Published var playSounds: Bool {
        didSet { UserDefaults.standard.set(playSounds, forKey: Keys.playSounds) }
    }

    @Published var smartFormatting: Bool {
        didSet { UserDefaults.standard.set(smartFormatting, forKey: Keys.smartFormatting) }
    }

    @Published var insertionMode: InsertionMode {
        didSet { UserDefaults.standard.set(insertionMode.rawValue, forKey: Keys.insertionMode) }
    }

    @Published var holdHotkey: HotkeyConfig {
        didSet {
            persist(hotkey: holdHotkey, prefix: Keys.holdPrefix)
            onHotkeysChanged?(holdHotkey, toggleHotkey, meetingHotkey)
        }
    }

    @Published var toggleHotkey: HotkeyConfig {
        didSet {
            persist(hotkey: toggleHotkey, prefix: Keys.togglePrefix)
            onHotkeysChanged?(holdHotkey, toggleHotkey, meetingHotkey)
        }
    }

    @Published var meetingHotkey: HotkeyConfig {
        didSet {
            persist(hotkey: meetingHotkey, prefix: Keys.meetingPrefix)
            onHotkeysChanged?(holdHotkey, toggleHotkey, meetingHotkey)
        }
    }

    init() {
        let defaults = UserDefaults.standard

        self.modelPath = defaults.string(forKey: Keys.modelPath) ?? TranscriptionClient.preferredModelPath()
        self.whisperBinaryPath = defaults.string(forKey: Keys.whisperBinaryPath) ?? ""
        self.transcriptionTimeoutSeconds = defaults.object(forKey: Keys.transcriptionTimeoutSeconds) as? Double ?? 90
        self.language = defaults.string(forKey: Keys.language) ?? ""
        self.pauseMediaWhileDictating = defaults.object(forKey: Keys.pauseMediaWhileDictating) as? Bool ?? true
        self.includeMicrophoneInMeetingCapture = defaults.object(forKey: Keys.includeMicrophoneInMeetingCapture) as? Bool ?? true
        self.playSounds = defaults.object(forKey: Keys.playSounds) as? Bool ?? true
        self.smartFormatting = defaults.object(forKey: Keys.smartFormatting) as? Bool ?? true
        if
            let raw = defaults.string(forKey: Keys.insertionMode),
            let mode = InsertionMode(rawValue: raw)
        {
            self.insertionMode = mode
        } else {
            self.insertionMode = .type
        }

        self.holdHotkey = SettingsStore.loadHotkey(
            prefix: Keys.holdPrefix,
            fallback: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))
        )
        self.toggleHotkey = SettingsStore.loadHotkey(
            prefix: Keys.togglePrefix,
            fallback: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | shiftKey))
        )
        self.meetingHotkey = SettingsStore.loadHotkey(
            prefix: Keys.meetingPrefix,
            fallback: .init(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey | controlKey))
        )
    }

    private func persist(hotkey: HotkeyConfig, prefix: String) {
        let defaults = UserDefaults.standard
        defaults.set(Int(hotkey.keyCode), forKey: prefix + "KeyCode")
        defaults.set(Int(hotkey.modifiers), forKey: prefix + "Modifiers")
    }

    private static func loadHotkey(prefix: String, fallback: HotkeyConfig) -> HotkeyConfig {
        let defaults = UserDefaults.standard
        guard
            let keyCode = defaults.object(forKey: prefix + "KeyCode") as? Int,
            let modifiers = defaults.object(forKey: prefix + "Modifiers") as? Int
        else {
            return fallback
        }
        return HotkeyConfig(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers))
    }

    private enum Keys {
        static let modelPath = "wispr.local_model_path"
        static let whisperBinaryPath = "wispr.whisper_binary_path"
        static let transcriptionTimeoutSeconds = "wispr.transcription_timeout_s"
        static let language = "wispr.language"
        static let pauseMediaWhileDictating = "wispr.pause_media"
        static let includeMicrophoneInMeetingCapture = "wispr.meeting.include_microphone"
        static let playSounds = "wispr.play_sounds"
        static let smartFormatting = "wispr.smart_formatting"
        static let insertionMode = "wispr.insertion_mode"

        static let holdPrefix = "wispr.hotkey.hold."
        static let togglePrefix = "wispr.hotkey.toggle."
        static let meetingPrefix = "wispr.hotkey.meeting."
    }
}

struct HotkeyConfig: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32
}

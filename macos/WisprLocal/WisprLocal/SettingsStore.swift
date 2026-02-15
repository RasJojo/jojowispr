import Carbon.HIToolbox
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    var onHotkeysChanged: ((HotkeyConfig, HotkeyConfig) -> Void)?

    // Updated by DictationController (not persisted).
    @Published var lastMetrics: DictationMetrics?
    @Published var debugStatus: String = ""

    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Keys.serverURL) }
    }

    /// Empty string = auto
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: Keys.language) }
    }

    @Published var pauseMediaWhileDictating: Bool {
        didSet { UserDefaults.standard.set(pauseMediaWhileDictating, forKey: Keys.pauseMediaWhileDictating) }
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
            onHotkeysChanged?(holdHotkey, toggleHotkey)
        }
    }

    @Published var toggleHotkey: HotkeyConfig {
        didSet {
            persist(hotkey: toggleHotkey, prefix: Keys.togglePrefix)
            onHotkeysChanged?(holdHotkey, toggleHotkey)
        }
    }

    var apiKey: String {
        get { (try? Keychain.getString(service: Keys.keychainService, account: Keys.keychainAccount)) ?? "" }
        set { try? Keychain.setString(newValue, service: Keys.keychainService, account: Keys.keychainAccount) }
    }

    init() {
        let defaults = UserDefaults.standard

        self.serverURL = defaults.string(forKey: Keys.serverURL) ?? "https://your-server.example.com/transcribe"
        self.language = defaults.string(forKey: Keys.language) ?? ""
        self.pauseMediaWhileDictating = defaults.object(forKey: Keys.pauseMediaWhileDictating) as? Bool ?? true
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
        static let serverURL = "wispr.server_url"
        static let language = "wispr.language"
        static let pauseMediaWhileDictating = "wispr.pause_media"
        static let playSounds = "wispr.play_sounds"
        static let smartFormatting = "wispr.smart_formatting"
        static let insertionMode = "wispr.insertion_mode"

        static let holdPrefix = "wispr.hotkey.hold."
        static let togglePrefix = "wispr.hotkey.toggle."

        static let keychainService = "WisprLocal"
        static let keychainAccount = "apiKey"
    }
}

struct HotkeyConfig: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32
}

import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @State private var apiKeyDraft: String = ""

    var body: some View {
        Form {
            Section("Backend") {
                TextField("Server URL", text: $settings.serverURL)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    SecureField("API key (Keychain)", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        settings.apiKey = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        apiKeyDraft = settings.apiKey
                    }
                    .keyboardShortcut(.defaultAction)
                }

                Picker("Language", selection: $settings.language) {
                    Text("Auto").tag("")
                    Text("fr").tag("fr")
                    Text("en").tag("en")
                    Text("es").tag("es")
                    Text("de").tag("de")
                    Text("it").tag("it")
                }
                .pickerStyle(.segmented)
            }

            Section("Hotkeys") {
                HotkeyRecorderRow(title: "Hold-to-talk", hotkey: $settings.holdHotkey)
                HotkeyRecorderRow(title: "Toggle dictation", hotkey: $settings.toggleHotkey)
                Text("Hold: press to start recording, release to transcribe.\nToggle: press once to start, press again to stop.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Behavior") {
                Toggle("Pause media while dictating (Now Playing)", isOn: $settings.pauseMediaWhileDictating)
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Smart formatting (best-effort)", isOn: $settings.smartFormatting)

                Picker("Insertion", selection: $settings.insertionMode) {
                    ForEach(InsertionMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(settings.insertionMode.help)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Permissions") {
                HStack {
                    Button("Request Microphone") {
                        Task { _ = await Permissions.requestMicrophoneIfNeeded() }
                    }
                    Button("Request Accessibility") {
                        _ = Permissions.requestAccessibilityIfNeeded()
                    }
                    Button("Open Privacy Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                }

                Text("Accessibility is required to insert text into other apps.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text("Accessibility status: \(Permissions.isAccessibilityTrusted() ? "Granted" : "Not granted")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section("Last Run (Debug)") {
                if !settings.debugStatus.isEmpty {
                    Text("Status: \(settings.debugStatus)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                if let m = settings.lastMetrics {
                    LabeledContent("Audio") {
                        Text(String(format: "%.1fs", m.audioDurationSeconds))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Size") {
                        Text(Self.formatBytes(m.audioBytes))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Stop recorder") {
                        Text("\(m.stopRecorderMs)ms")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Request") {
                        Text("\(m.requestMs)ms (srv \(m.serverElapsedMs ?? -1)ms)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Total") {
                        Text("\(m.totalMs)ms")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    LabeledContent("Language") {
                        let lang = m.detectedLanguage ?? "?"
                        let prob = m.languageProbability.map { String(format: "%.2f", $0) } ?? "?"
                        Text("\(lang) (\(prob))")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("No dictation yet.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .onAppear {
            apiKeyDraft = settings.apiKey
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024.0, idx < units.count - 1 {
            value /= 1024.0
            idx += 1
        }
        if idx == 0 { return "\(Int(value)) \(units[idx])" }
        return String(format: "%.1f %@", value, units[idx])
    }
}

private struct HotkeyRecorderRow: View {
    let title: String
    @Binding var hotkey: HotkeyConfig

    @State private var isRecording = false
    @State private var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(HotkeyDisplay.format(hotkey))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button(isRecording ? "Press keys..." : "Record") {
                    toggleRecording()
                }
                .buttonStyle(.bordered)
            }

            if let hint, !hint.isEmpty {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Hidden responder that captures key combos reliably (incl. modifiers).
            HotkeyCapture(
                isRecording: $isRecording,
                onCaptured: { newValue in
                    hotkey = newValue
                    hint = nil
                    isRecording = false
                },
                onCancelled: {
                    hint = nil
                    isRecording = false
                },
                onHint: { newHint in
                    hint = newHint
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
        .onDisappear {
            stopRecording()
        }
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        hint = "Press a key combo (Esc to cancel)."
    }

    private func stopRecording() {
        isRecording = false
        hint = nil
    }
}

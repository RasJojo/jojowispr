import AVFoundation
import Foundation

@MainActor
final class DictationController: ObservableObject {
    enum Trigger {
        case holdHotkey
        case toggleHotkey
        case menu
    }

    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Double = 0.0

    var isRecording: Bool { state == .recording }

    private weak var settings: SettingsStore?

    private let recorder = AudioRecorder()
    private let overlay = OverlayController()
    private let transcription = TranscriptionClient()
    private let inserter = TextInserter()
    private let media = MediaRemoteController.shared
    private let sounds = SoundPlayer()

    private var pausedMediaByUs = false
    private var lastStopRecorderMs = 0

    func configure(settings: SettingsStore) {
        self.settings = settings
    }

    func startRecording(trigger: Trigger) {
        guard case .idle = state else { return }
        Task { @MainActor in
            guard let settings else { return }
            settings.debugStatus = "Starting recording..."
            Log.dictation.info("startRecording trigger=\(String(describing: trigger), privacy: .public)")

            let micOK = await Permissions.requestMicrophoneIfNeeded()
            guard micOK else {
                showError("Microphone permission denied.")
                return
            }

            if settings.pauseMediaWhileDictating {
                Log.media.info("pauseMediaWhileDictating=on (checking Now Playing)")
                pausedMediaByUs = await media.pauseIfPlaying()
            } else {
                pausedMediaByUs = false
            }

            do {
                try recorder.start { [weak self] level in
                    Task { @MainActor in
                        self?.level = level
                        self?.overlay.setLevel(level)
                    }
                }
                overlay.show(mode: .listening)
                if settings.playSounds { sounds.play(.start) }
                state = .recording
                settings.debugStatus = "Recording..."
                Log.dictation.info("Recording started")
            } catch {
                showError("Failed to start recording: \(error.localizedDescription)")
            }
        }
    }

    func stopRecordingAndTranscribe(trigger: Trigger) async {
        guard case .recording = state else { return }
        guard let settings else { return }

        settings.debugStatus = "Stopping recorder..."
        if settings.playSounds { sounds.play(.stop) }

        Log.dictation.info("stopRecordingAndTranscribe trigger=\(String(describing: trigger), privacy: .public)")
        let audioURL: URL
        do {
            let stopStarted = CFAbsoluteTimeGetCurrent()
            audioURL = try recorder.stop()
            lastStopRecorderMs = Int((CFAbsoluteTimeGetCurrent() - stopStarted) * 1000)
            Log.dictation.info("Recorder stopped in \(self.lastStopRecorderMs, privacy: .public)ms url=\(audioURL.lastPathComponent, privacy: .public)")
        } catch {
            showError("Failed to stop recording: \(error.localizedDescription)")
            await maybeResumeMedia()
            return
        }

        do {
            let fileBytes: Int64 = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? NSNumber)?.int64Value ?? 0
            let audioDuration = AudioRecorder.durationSeconds(of: audioURL) ?? 0
            Log.dictation.info("Audio captured duration=\(String(format: "%.2f", audioDuration), privacy: .public)s bytes=\(fileBytes, privacy: .public)")

            settings.lastMetrics = DictationMetrics(
                audioDurationSeconds: audioDuration,
                audioBytes: fileBytes,
                stopRecorderMs: lastStopRecorderMs,
                requestMs: 0,
                totalMs: lastStopRecorderMs,
                serverElapsedMs: nil,
                detectedLanguage: nil,
                languageProbability: nil
            )

            state = .transcribing
            overlay.show(mode: .transcribing)
            settings.debugStatus = String(format: "Sending audio (%.1fs, %@)...", audioDuration, Self.formatBytes(fileBytes))

            Log.network.info("Transcribe request starting server=\(settings.serverURL, privacy: .public) language=\(settings.language, privacy: .public) apiKeySet=\(!settings.apiKey.isEmpty, privacy: .public)")
            let requestStarted = CFAbsoluteTimeGetCurrent()
            let result = try await transcription.transcribe(
                audioFileURL: audioURL,
                serverURLString: settings.serverURL,
                apiKey: settings.apiKey.isEmpty ? nil : settings.apiKey,
                language: settings.language.isEmpty ? nil : settings.language
            )
            let requestMs = Int((CFAbsoluteTimeGetCurrent() - requestStarted) * 1000)
            let totalMs = lastStopRecorderMs + requestMs

            settings.lastMetrics = DictationMetrics(
                audioDurationSeconds: audioDuration,
                audioBytes: fileBytes,
                stopRecorderMs: lastStopRecorderMs,
                requestMs: requestMs,
                totalMs: totalMs,
                serverElapsedMs: result.elapsed_ms,
                detectedLanguage: result.language,
                languageProbability: result.language_probability
            )
            settings.debugStatus = "Inserting text..."
            Log.network.info("Transcribe response ok requestMs=\(requestMs, privacy: .public) serverElapsedMs=\(result.elapsed_ms ?? -1, privacy: .public) lang=\(result.language ?? "?", privacy: .public) textChars=\(result.text.count, privacy: .public)")

            var text = result.text
            if settings.smartFormatting {
                text = TextPostProcessor.process(text)
            }

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                overlay.flash(message: "No speech detected")
            } else {
                let ok = inserter.insert(text: text, mode: settings.insertionMode)
                if ok {
                    if totalMs >= 2500 {
                        let audioS = String(format: "%.1fs", audioDuration)
                        let srv = result.elapsed_ms.map { "\($0)ms" } ?? "?"
                        overlay.flash(message: "Inserted • audio \(audioS) • total \(totalMs)ms • srv \(srv)")
                    } else {
                        overlay.flash(message: "Inserted")
                    }
                } else {
                    overlay.flash(message: "Enable Accessibility to insert")
                }
            }

            state = .idle
            settings.debugStatus = ""
            overlay.hideAfterDelay(seconds: 0.6)
            await maybeResumeMedia()
        } catch {
            Log.network.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            showError("Transcription failed: \(error.localizedDescription)")
            await maybeResumeMedia()
        }
    }

    private func showError(_ message: String) {
        state = .error(message)
        settings?.debugStatus = message
        overlay.flash(message: message)
        overlay.hideAfterDelay(seconds: 2.0)
    }

    private func maybeResumeMedia() async {
        if pausedMediaByUs {
            await media.resumeIfPaused()
            pausedMediaByUs = false
        }
    }
}

private extension DictationController {
    static func formatBytes(_ bytes: Int64) -> String {
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

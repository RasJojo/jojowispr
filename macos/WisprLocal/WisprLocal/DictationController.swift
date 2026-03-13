import AVFoundation
import Foundation

@MainActor
final class DictationController: ObservableObject {
    enum Trigger {
        case holdHotkey
        case toggleHotkey
        case meetingHotkey
        case menu
        case meetingMenu
    }

    enum CaptureKind: Equatable {
        case microphoneDictation
        case meetingCapture
    }

    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case error(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var level: Double = 0.0
    @Published private(set) var captureKind: CaptureKind?

    var isRecording: Bool { state == .recording }
    var isRecordingMicDictation: Bool { state == .recording && captureKind == .microphoneDictation }
    var isRecordingMeetingCapture: Bool { state == .recording && captureKind == .meetingCapture }

    private weak var settings: SettingsStore?

    private let recorder = AudioRecorder()
    private nonisolated(unsafe) let systemRecorder = SystemAudioRecorder()
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
            captureKind = .microphoneDictation
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
                captureKind = nil
                showError("Failed to start recording: \(error.localizedDescription)")
            }
        }
    }

    func startMeetingCapture(trigger: Trigger) {
        guard case .idle = state else { return }
        Task { @MainActor in
            guard let settings else { return }
            captureKind = .meetingCapture
            settings.debugStatus = "Starting meeting capture..."
            Log.dictation.info(
                "startMeetingCapture trigger=\(String(describing: trigger), privacy: .public) includeMic=\(settings.includeMicrophoneInMeetingCapture)"
            )

            let screenOK = Permissions.requestScreenRecordingIfNeeded()
            guard screenOK else {
                captureKind = nil
                showError("Screen Recording permission is required for meeting capture.")
                return
            }

            if settings.includeMicrophoneInMeetingCapture {
                let micOK = await Permissions.requestMicrophoneIfNeeded()
                guard micOK else {
                    captureKind = nil
                    showError("Microphone permission denied.")
                    return
                }
            }

            do {
                try await systemRecorder.start(includeMicrophone: settings.includeMicrophoneInMeetingCapture)
                overlay.show(mode: .listening)
                if settings.playSounds { sounds.play(.start) }
                state = .recording
                settings.debugStatus = "Meeting capture running..."
                Log.dictation.info("Meeting capture started")
            } catch {
                captureKind = nil
                showError("Failed to start meeting capture: \(error.localizedDescription)")
            }
        }
    }

    func stopRecordingAndTranscribe(trigger: Trigger) async {
        guard case .recording = state else { return }
        guard let settings else { return }
        guard let currentCaptureKind = captureKind else {
            showError("No active capture mode.")
            return
        }

        settings.debugStatus = currentCaptureKind == .meetingCapture ? "Stopping meeting capture..." : "Stopping recorder..."
        if settings.playSounds { sounds.play(.stop) }

        Log.dictation.info(
            "stopRecordingAndTranscribe trigger=\(String(describing: trigger), privacy: .public) mode=\(String(describing: currentCaptureKind), privacy: .public)"
        )
        let audioURL: URL
        do {
            let stopStarted = CFAbsoluteTimeGetCurrent()
            switch currentCaptureKind {
            case .microphoneDictation:
                audioURL = try recorder.stop()
            case .meetingCapture:
                audioURL = try await systemRecorder.stop()
            }
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
            let captureLabel = currentCaptureKind == .meetingCapture ? "meeting audio" : "dictation"
            settings.debugStatus = String(format: "Running local model (%@ %.1fs, %@)...", captureLabel, audioDuration, Self.formatBytes(fileBytes))

            Log.network.info(
                "Local transcribe request starting mode=\(captureLabel, privacy: .public) model=\(settings.modelPath, privacy: .public) language=\(settings.language, privacy: .public)"
            )
            let requestStarted = CFAbsoluteTimeGetCurrent()
            let result = try await transcription.transcribe(
                audioFileURL: audioURL,
                modelPath: settings.modelPath,
                whisperBinaryPath: settings.whisperBinaryPath,
                language: settings.language.isEmpty ? nil : settings.language,
                timeoutSeconds: settings.transcriptionTimeoutSeconds,
                keepModelWarmBetweenTranscriptions: settings.keepModelWarmBetweenTranscriptions,
                modelWarmIdleSleepSeconds: settings.modelWarmIdleSleepSeconds
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
            settings.debugStatus = currentCaptureKind == .meetingCapture ? "Saving transcript..." : "Inserting text..."
            Log.network.info("Local transcribe response ok requestMs=\(requestMs, privacy: .public) engineElapsedMs=\(result.elapsed_ms ?? -1, privacy: .public) lang=\(result.language ?? "?", privacy: .public) textChars=\(result.text.count, privacy: .public)")

            var text = result.text
            if settings.smartFormatting {
                text = TextPostProcessor.process(text)
            }

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if currentCaptureKind == .meetingCapture {
                    overlay.flash(message: "No speech detected (nothing saved)")
                } else {
                    overlay.flash(message: "No speech detected")
                }
            } else {
                switch currentCaptureKind {
                case .meetingCapture:
                    do {
                        let outputURL = try Self.saveMeetingTranscript(text)
                        Log.dictation.info("Meeting transcript saved to \(outputURL.path, privacy: .public)")
                        if totalMs >= 2500 {
                            let audioS = String(format: "%.1fs", audioDuration)
                            let engine = result.elapsed_ms.map { "\($0)ms" } ?? "?"
                            overlay.flash(message: "Saved \(outputURL.lastPathComponent) • audio \(audioS) • total \(totalMs)ms • local \(engine)")
                        } else {
                            overlay.flash(message: "Saved \(outputURL.lastPathComponent)")
                        }
                    } catch {
                        showError("Failed to save transcript: \(error.localizedDescription)")
                        captureKind = nil
                        await maybeResumeMedia()
                        return
                    }
                case .microphoneDictation:
                    let ok = inserter.insert(text: text, mode: settings.insertionMode)
                    if ok {
                        if totalMs >= 2500 {
                            let audioS = String(format: "%.1fs", audioDuration)
                            let engine = result.elapsed_ms.map { "\($0)ms" } ?? "?"
                            overlay.flash(message: "Inserted • audio \(audioS) • total \(totalMs)ms • local \(engine)")
                        } else {
                            overlay.flash(message: "Inserted")
                        }
                    } else {
                        overlay.flash(message: "Enable Accessibility to insert")
                    }
                }
            }

            state = .idle
            captureKind = nil
            settings.debugStatus = ""
            overlay.hideAfterDelay(seconds: 0.6)
            await maybeResumeMedia()
        } catch {
            Log.network.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
            showError("Transcription failed: \(error.localizedDescription)")
            captureKind = nil
            await maybeResumeMedia()
        }
    }

    private func showError(_ message: String) {
        state = .error(message)
        captureKind = nil
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
    static func saveMeetingTranscript(_ text: String) throws -> URL {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents", isDirectory: true)
        let folder = docs.appendingPathComponent("wispr", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let fileName = "meeting_\(formatter.string(from: Date())).txt"
        let outputURL = folder.appendingPathComponent(fileName)

        try text.write(to: outputURL, atomically: true, encoding: .utf8)
        return outputURL
    }

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

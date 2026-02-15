import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject, AVAudioRecorderDelegate {
    enum RecorderError: Error {
        case alreadyRecording
        case notRecording
        case failedToCreateRecorder
        case missingOutputURL
    }

    private var recorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var outputURL: URL?
    private var levelHandler: ((Double) -> Void)?

    static func durationSeconds(of url: URL) -> Double? {
        do {
            let file = try AVAudioFile(forReading: url)
            let frames = Double(file.length)
            let rate = file.processingFormat.sampleRate
            guard rate > 0 else { return nil }
            return frames / rate
        } catch {
            return nil
        }
    }

    func start(levelHandler: @escaping (Double) -> Void) throws {
        if recorder != nil { throw RecorderError.alreadyRecording }

        self.levelHandler = levelHandler

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr_recording_\(Int(Date().timeIntervalSince1970)).wav")
        self.outputURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            throw RecorderError.failedToCreateRecorder
        }
        recorder.isMeteringEnabled = true
        recorder.delegate = self
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw RecorderError.failedToCreateRecorder
        }

        self.recorder = recorder

        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.tickMeters()
        }
        RunLoop.main.add(levelTimer!, forMode: .common)
    }

    func stop() throws -> URL {
        guard let recorder else { throw RecorderError.notRecording }
        guard let outputURL else { throw RecorderError.missingOutputURL }

        recorder.stop()
        self.recorder = nil

        levelTimer?.invalidate()
        levelTimer = nil

        levelHandler = nil

        return outputURL
    }

    private func tickMeters() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0) // [-160..0]
        let level = Self.normalizedPowerLevel(power)
        levelHandler?(level)
    }

    private static func normalizedPowerLevel(_ power: Float) -> Double {
        // Convert dB to a 0..1-ish UI value.
        let clamped = max(-60.0, min(0.0, Double(power)))
        return pow((clamped + 60.0) / 60.0, 1.8)
    }
}

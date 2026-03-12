import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

final class SystemAudioRecorder: NSObject {
    enum RecorderError: Error, LocalizedError {
        case alreadyRecording
        case notRecording
        case noDisplayAvailable
        case outputNotReady
        case noAudioCaptured
        case microphoneCaptureUnsupported
        case streamFailed(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRecording:
                return "System audio capture is already running."
            case .notRecording:
                return "System audio capture is not running."
            case .noDisplayAvailable:
                return "No display available for system audio capture."
            case .outputNotReady:
                return "System audio output file is not ready."
            case .noAudioCaptured:
                return "No audio captured from the system output."
            case .microphoneCaptureUnsupported:
                return "Microphone + system audio capture requires macOS 15 or newer."
            case let .streamFailed(message):
                return "System audio capture failed: \(message)"
            }
        }
    }

    private let callbackQueue = DispatchQueue(label: "com.jojo.wisprlocal.systemaudio.callback")
    private let stateLock = NSLock()

    private var stream: SCStream?
    private var outputURL: URL?
    private var includeMicrophone = false
    private var isRunning = false

    private let targetFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }()

    // These are only touched on callbackQueue.
    private var systemConverter: AVAudioConverter?
    private var microphoneConverter: AVAudioConverter?
    private var sourceTimelineStartSeconds: Double?
    private var mixedSamples: [Float] = []

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    func start(includeMicrophone: Bool) async throws {
        let alreadyRunning = withStateLock { isRunning }
        if alreadyRunning {
            throw RecorderError.alreadyRecording
        }

        if includeMicrophone, #unavailable(macOS 15.0) {
            throw RecorderError.microphoneCaptureUnsupported
        }

        let tempOutput = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr_system_audio_\(Int(Date().timeIntervalSince1970)).wav")

        let shareable = try await SCShareableContent.current
        guard let display = shareable.displays.first else {
            throw RecorderError.noDisplayAvailable
        }

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(targetFormat.sampleRate)
        config.channelCount = Int(targetFormat.channelCount)
        config.excludesCurrentProcessAudio = true
        if #available(macOS 15.0, *), includeMicrophone {
            config.captureMicrophone = true
        }

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: callbackQueue)
        if #available(macOS 15.0, *), includeMicrophone {
            try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: callbackQueue)
        }

        withStateLock {
            self.stream = stream
            self.outputURL = tempOutput
            self.includeMicrophone = includeMicrophone
            self.isRunning = true
        }

        callbackQueue.sync {
            self.systemConverter = nil
            self.microphoneConverter = nil
            self.sourceTimelineStartSeconds = nil
            self.mixedSamples.removeAll(keepingCapacity: false)
        }

        do {
            try await stream.startCapture()
        } catch {
            resetStateAfterFailure()
            throw RecorderError.streamFailed(error.localizedDescription)
        }
    }

    func stop() async throws -> URL {
        let stream = withStateLock { isRunning ? self.stream : nil }
        guard let stream else {
            throw RecorderError.notRecording
        }

        do {
            try await stream.stopCapture()
        } catch {
            resetStateAfterFailure()
            throw RecorderError.streamFailed(error.localizedDescription)
        }

        let samples = callbackQueue.sync { mixedSamples }

        let output = withStateLock {
            let output = outputURL
            self.stream = nil
            self.outputURL = nil
            self.includeMicrophone = false
            self.isRunning = false
            return output
        }

        callbackQueue.sync {
            self.systemConverter = nil
            self.microphoneConverter = nil
            self.sourceTimelineStartSeconds = nil
        }

        guard let output else {
            throw RecorderError.outputNotReady
        }
        guard !samples.isEmpty else {
            throw RecorderError.noAudioCaptured
        }

        try Self.writeWav(samples: samples, to: output, sampleRate: targetFormat.sampleRate)
        return output
    }

    private func resetStateAfterFailure() {
        withStateLock {
            self.stream = nil
            self.outputURL = nil
            self.includeMicrophone = false
            self.isRunning = false
        }

        callbackQueue.sync {
            self.systemConverter = nil
            self.microphoneConverter = nil
            self.sourceTimelineStartSeconds = nil
            self.mixedSamples.removeAll(keepingCapacity: false)
        }
    }

    private func handleSampleBuffer(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let isMicrophoneOutput: Bool
        if #available(macOS 15.0, *) {
            isMicrophoneOutput = type == .microphone
        } else {
            isMicrophoneOutput = false
        }
        if type != .audio, !isMicrophoneOutput { return }

        let isRunning = withStateLock { self.isRunning }
        guard isRunning else { return }

        guard let normalized = normalizedBuffer(from: sampleBuffer, isMicrophone: isMicrophoneOutput) else {
            return
        }
        guard let channel = normalized.floatChannelData?[0] else { return }
        let count = Int(normalized.frameLength)
        guard count > 0 else { return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        var startSample = mixedSamples.count
        if CMTIME_IS_NUMERIC(pts), pts.seconds.isFinite {
            let seconds = pts.seconds
            if sourceTimelineStartSeconds == nil {
                sourceTimelineStartSeconds = seconds
            }
            if let base = sourceTimelineStartSeconds {
                startSample = max(0, Int(round((seconds - base) * targetFormat.sampleRate)))
            }
        }

        let neededCount = startSample + count
        if mixedSamples.count < neededCount {
            mixedSamples.append(contentsOf: repeatElement(0, count: neededCount - mixedSamples.count))
        }

        for i in 0..<count {
            let idx = startSample + i
            let mixed = mixedSamples[idx] + channel[i]
            mixedSamples[idx] = mixed
        }
    }

    private func normalizedBuffer(from sampleBuffer: CMSampleBuffer, isMicrophone: Bool) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0 else { return nil }
        guard let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: frameCount) else {
            return nil
        }
        sourceBuffer.frameLength = frameCount

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: sourceBuffer.mutableAudioBufferList
        )
        guard copyStatus == noErr else { return nil }

        let matchesTarget = sourceFormat.sampleRate == targetFormat.sampleRate
            && sourceFormat.channelCount == targetFormat.channelCount
            && sourceFormat.commonFormat == targetFormat.commonFormat
            && sourceFormat.isInterleaved == targetFormat.isInterleaved
        if matchesTarget {
            return sourceBuffer
        }

        let converter: AVAudioConverter
        if isMicrophone {
            if !Self.converter(microphoneConverter, matches: sourceFormat) {
                microphoneConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            }
            guard let microphoneConverter else { return nil }
            converter = microphoneConverter
        } else {
            if !Self.converter(systemConverter, matches: sourceFormat) {
                systemConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            }
            guard let systemConverter else { return nil }
            converter = systemConverter
        }

        let ratio = targetFormat.sampleRate / max(1, sourceFormat.sampleRate)
        let outputCapacity = max(AVAudioFrameCount(Double(frameCount) * ratio) + 64, 512)
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return nil
        }

        var didProvideInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if didProvideInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            didProvideInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if status == .error {
            Log.media.error("Audio conversion failed: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)")
            return nil
        }
        guard output.frameLength > 0 else { return nil }
        return output
    }

    private static func converter(_ converter: AVAudioConverter?, matches sourceFormat: AVAudioFormat) -> Bool {
        guard let converter else { return false }
        let inFmt = converter.inputFormat
        return inFmt.sampleRate == sourceFormat.sampleRate
            && inFmt.channelCount == sourceFormat.channelCount
            && inFmt.commonFormat == sourceFormat.commonFormat
            && inFmt.isInterleaved == sourceFormat.isInterleaved
    }

    private static func writeWav(samples: [Float], to url: URL, sampleRate: Double) throws {
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: outputFormat.settings, commonFormat: .pcmFormatInt16, interleaved: false)

        let chunkSize = 32_768
        var offset = 0
        while offset < samples.count {
            let count = min(chunkSize, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(count)) else {
                break
            }
            buffer.frameLength = AVAudioFrameCount(count)
            guard let dst = buffer.int16ChannelData?[0] else { break }
            for i in 0..<count {
                let clamped = max(-1.0, min(1.0, samples[offset + i]))
                dst[i] = Int16(clamped * Float(Int16.max))
            }
            try file.write(from: buffer)
            offset += count
        }
    }
}

extension SystemAudioRecorder: SCStreamOutput, SCStreamDelegate {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        handleSampleBuffer(sampleBuffer, type: outputType)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.media.error("ScreenCaptureKit stream stopped: \(error.localizedDescription, privacy: .public)")
    }
}

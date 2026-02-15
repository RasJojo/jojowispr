import Foundation

struct DictationMetrics: Equatable {
    let audioDurationSeconds: Double
    let audioBytes: Int64

    let stopRecorderMs: Int
    let requestMs: Int
    let totalMs: Int

    let serverElapsedMs: Int?
    let detectedLanguage: String?
    let languageProbability: Double?
}


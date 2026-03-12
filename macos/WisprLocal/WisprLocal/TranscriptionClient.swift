import Foundation

struct TranscriptionResult: Decodable, Sendable {
    let text: String
    let language: String?
    let language_probability: Double?
    let elapsed_ms: Int?
}

struct TranscriptionClient: Sendable {
    enum ClientError: Error, LocalizedError {
        case missingWhisperCLI
        case missingModel(String)
        case processFailed(String)
        case timeout

        var errorDescription: String? {
            switch self {
            case .missingWhisperCLI:
                return "whisper-cli not found. Set its path in Settings, or bundle whisper-cli in the app."
            case let .missingModel(path):
                return "Model not found at '\(path)'. Install/download a Whisper model first."
            case let .processFailed(message):
                return "Local transcription failed: \(message)"
            case .timeout:
                return "Local transcription timed out."
            }
        }
    }

    enum InstallError: Error, LocalizedError {
        case badResponse
        case httpError(Int)

        var errorDescription: String? {
            switch self {
            case .badResponse:
                return "Model download failed: invalid server response."
            case let .httpError(code):
                return "Model download failed with HTTP \(code)."
            }
        }
    }

    static let defaultModelFileName = "ggml-large-v3-turbo.bin"
    static let defaultModelDownloadURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    )!

    static func bundledModelPath() -> String? {
        guard let resources = Bundle.main.resourceURL else { return nil }

        let preferred = resources
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(defaultModelFileName)
        if FileManager.default.fileExists(atPath: preferred.path) {
            return preferred.path
        }

        let modelsDir = resources.appendingPathComponent("Models", isDirectory: true)
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: modelsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            if let firstModel = entries.first(where: { ["bin", "gguf"].contains($0.pathExtension.lowercased()) }) {
                return firstModel.path
            }
        }
        return nil
    }

    static func preferredModelPath() -> String {
        bundledModelPath() ?? defaultModelPath()
    }

    static func defaultModelPath() -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("WisprLocal", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent(defaultModelFileName)
            .path
    }

    static func installDefaultModel(at destinationPath: String) async throws -> URL {
        let requestedPath = destinationPath.isEmpty ? defaultModelPath() : destinationPath
        var finalPath = expandPath(requestedPath)
        // App bundle resources are read-only at runtime: redirect installs to Application Support.
        if finalPath.hasPrefix(Bundle.main.bundlePath) {
            finalPath = defaultModelPath()
        }
        let destination = URL(fileURLWithPath: finalPath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let (tempFile, response) = try await URLSession.shared.download(from: defaultModelDownloadURL)
        guard let http = response as? HTTPURLResponse else {
            throw InstallError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw InstallError.httpError(http.statusCode)
        }

        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tempFile, to: destination)

        return destination
    }

    func transcribe(
        audioFileURL: URL,
        modelPath: String,
        whisperBinaryPath: String,
        language: String?,
        timeoutSeconds: Double
    ) async throws -> TranscriptionResult {
        guard let executable = Self.resolveWhisperExecutable(configuredPath: whisperBinaryPath) else {
            throw ClientError.missingWhisperCLI
        }
        let resolvedModelPath = Self.expandPath(modelPath.isEmpty ? Self.preferredModelPath() : modelPath)
        guard FileManager.default.fileExists(atPath: resolvedModelPath) else {
            throw ClientError.missingModel(resolvedModelPath)
        }

        let languageArg = Self.normalizeLanguage(language)
        let outputPrefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr_transcript_\(UUID().uuidString)")
        let outputTextURL = URL(fileURLWithPath: outputPrefix.path + ".txt")

        let args = [
            "-m", resolvedModelPath,
            "-f", audioFileURL.path,
            "-l", languageArg,
            "-otxt",
            "-of", outputPrefix.path,
            "-np",
        ]

        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: audioFileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        Log.network.info(
            "Local transcribe starting binary=\(executable, privacy: .public) model=\(resolvedModelPath, privacy: .public) lang=\(languageArg, privacy: .public) bytes=\(fileBytes, privacy: .public)"
        )

        let started = CFAbsoluteTimeGetCurrent()
        let processOutput: ProcessOutput = try await Task.detached(priority: .userInitiated) {
            try Self.runWhisperProcess(
                executablePath: executable,
                arguments: args,
                timeoutSeconds: timeoutSeconds
            )
        }.value
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)

        if processOutput.exitCode != 0 {
            let stderrTrimmed = processOutput.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClientError.processFailed(
                stderrTrimmed.isEmpty ? "exit code \(processOutput.exitCode)" : stderrTrimmed
            )
        }

        let textRaw: String
        if FileManager.default.fileExists(atPath: outputTextURL.path) {
            textRaw = (try? String(contentsOf: outputTextURL, encoding: .utf8)) ?? ""
            try? FileManager.default.removeItem(at: outputTextURL)
        } else {
            textRaw = processOutput.stdout
        }

        let text = textRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLanguage = Self.detectedLanguage(from: processOutput.stdout + "\n" + processOutput.stderr) ?? (languageArg == "auto" ? nil : languageArg)

        Log.network.info(
            "Local transcribe ok ms=\(elapsedMs, privacy: .public) lang=\(detectedLanguage ?? "?", privacy: .public) chars=\(text.count, privacy: .public)"
        )

        return TranscriptionResult(
            text: text,
            language: detectedLanguage,
            language_probability: nil,
            elapsed_ms: elapsedMs
        )
    }
}

private extension TranscriptionClient {
    struct ProcessOutput {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    static func runWhisperProcess(
        executablePath: String,
        arguments: [String],
        timeoutSeconds: Double
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        try process.run()

        if timeoutSeconds > 0 {
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while process.isRunning {
                if Date() >= deadline {
                    process.terminate()
                    throw ClientError.timeout
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        process.waitUntilExit()

        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessOutput(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    static func resolveWhisperExecutable(configuredPath: String) -> String? {
        let configured = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            let expanded = expandPath(configured)
            if FileManager.default.isExecutableFile(atPath: expanded) {
                return expanded
            }
            if !expanded.contains("/"), let found = which(expanded) {
                return found
            }
        }

        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("whisper-cli").path,
           FileManager.default.isExecutableFile(atPath: bundled)
        {
            return bundled
        }
        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("main").path,
           FileManager.default.isExecutableFile(atPath: bundled)
        {
            return bundled
        }
        let commonPaths = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/main",
            "/usr/local/bin/main",
        ]
        for path in commonPaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let found = which("whisper-cli") {
            return found
        }
        if let found = which("main") {
            return found
        }
        return nil
    }

    static func normalizeLanguage(_ language: String?) -> String {
        let code = (language ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? "auto" : code
    }

    static func detectedLanguage(from output: String) -> String? {
        let patterns = [
            #"auto[- ]detected language:\s*([A-Za-z-]+)"#,
            #"language:\s*([A-Za-z-]+)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let ns = NSRange(output.startIndex..<output.endIndex, in: output)
            guard let match = regex.firstMatch(in: output, options: [], range: ns), match.numberOfRanges > 1 else { continue }
            guard let range = Range(match.range(at: 1), in: output) else { continue }
            let lang = String(output[range]).lowercased()
            if !lang.isEmpty {
                return lang
            }
        }
        return nil
    }

    static func which(_ executable: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [executable]

        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let value = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    static func expandPath(_ path: String) -> String {
        NSString(string: path).expandingTildeInPath
    }
}

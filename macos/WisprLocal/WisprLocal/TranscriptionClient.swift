import Foundation

struct TranscriptionResult: Decodable, Sendable {
    let text: String
    let language: String?
    let language_probability: Double?
    let elapsed_ms: Int?
}

struct TranscriptionClient: Sendable {
    private static let warmServer = WarmWhisperServerController()

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
        timeoutSeconds: Double,
        keepModelWarmBetweenTranscriptions: Bool,
        modelWarmIdleSleepSeconds: Double
    ) async throws -> TranscriptionResult {
        let resolvedModelPath = Self.expandPath(modelPath.isEmpty ? Self.preferredModelPath() : modelPath)
        guard FileManager.default.fileExists(atPath: resolvedModelPath) else {
            throw ClientError.missingModel(resolvedModelPath)
        }

        let languageArg = Self.normalizeLanguage(language)
        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: audioFileURL.path)[.size] as? NSNumber)?.int64Value ?? 0

        if keepModelWarmBetweenTranscriptions {
            do {
                let result = try await Self.warmServer.transcribe(
                    audioFileURL: audioFileURL,
                    modelPath: resolvedModelPath,
                    whisperBinaryPath: whisperBinaryPath,
                    language: languageArg,
                    timeoutSeconds: timeoutSeconds,
                    idleSleepSeconds: modelWarmIdleSleepSeconds
                )
                Log.network.info(
                    "Local transcribe ok via warm-server ms=\(result.elapsed_ms ?? -1, privacy: .public) lang=\(result.language ?? "?", privacy: .public) chars=\(result.text.count, privacy: .public)"
                )
                return result
            } catch {
                Log.network.error("Warm whisper-server failed: \(error.localizedDescription, privacy: .public). Falling back to whisper-cli.")
            }
        } else {
            await Self.warmServer.shutdown(reason: "warm mode disabled")
        }

        guard let executable = Self.resolveWhisperExecutable(configuredPath: whisperBinaryPath) else {
            throw ClientError.missingWhisperCLI
        }
        let outputPrefix = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr_transcript_\(UUID().uuidString)")
        let outputTextURL = URL(fileURLWithPath: outputPrefix.path + ".txt")

        let args = [
            "-m", resolvedModelPath,
            "-f", audioFileURL.path,
            "-l", languageArg,
            "-t", String(Self.defaultThreadCount()),
            "-otxt",
            "-of", outputPrefix.path,
            "-np",
        ]

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

    static func shutdownWarmServer() async {
        await warmServer.shutdown(reason: "shutdown requested")
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

    static func resolveWhisperServerExecutable(configuredPath: String) -> String? {
        var candidates: [String] = []
        let configured = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configured.isEmpty {
            let expanded = expandPath(configured)
            candidates.append(expanded)
            if expanded.contains("/") {
                let url = URL(fileURLWithPath: expanded)
                let sibling = url.deletingLastPathComponent().appendingPathComponent("whisper-server").path
                candidates.append(sibling)
            }
        }

        if let cliPath = resolveWhisperExecutable(configuredPath: configuredPath) {
            let sibling = URL(fileURLWithPath: cliPath).deletingLastPathComponent().appendingPathComponent("whisper-server").path
            candidates.append(sibling)
        }

        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("whisper-server").path {
            candidates.append(bundled)
        }

        candidates.append(contentsOf: [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server",
        ])

        for candidate in candidates {
            if candidate.contains("/") {
                if FileManager.default.isExecutableFile(atPath: candidate) {
                    return candidate
                }
            } else if let found = which(candidate) {
                return found
            }
        }
        return which("whisper-server")
    }

    static func defaultThreadCount() -> Int {
        max(4, ProcessInfo.processInfo.activeProcessorCount)
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

private actor WarmWhisperServerController {
    private struct ServerResponse: Decodable {
        let text: String
        let language: String?
        let language_probability: Double?
    }

    enum WarmServerError: Error, LocalizedError {
        case missingExecutable
        case startupFailed(String)
        case startupTimeout
        case badHTTPStatus(Int, String)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .missingExecutable:
                return "whisper-server not found. Install whisper.cpp server binary or disable warm mode."
            case let .startupFailed(message):
                return "whisper-server failed to start: \(message)"
            case .startupTimeout:
                return "whisper-server startup timed out."
            case let .badHTTPStatus(code, body):
                return "whisper-server returned HTTP \(code): \(body)"
            case .invalidResponse:
                return "whisper-server returned an invalid response."
            }
        }
    }

    private var process: Process?
    private var logHandle: FileHandle?
    private var executablePath: String?
    private var modelPath: String?
    private var port: Int = 9091
    private var idleSleepTask: Task<Void, Never>?
    private var idleToken = 0
    private var lastActivityAt = Date()

    func transcribe(
        audioFileURL: URL,
        modelPath: String,
        whisperBinaryPath: String,
        language: String,
        timeoutSeconds: Double,
        idleSleepSeconds: Double
    ) async throws -> TranscriptionResult {
        idleSleepTask?.cancel()

        try await ensureRunning(modelPath: modelPath, whisperBinaryPath: whisperBinaryPath)
        let started = CFAbsoluteTimeGetCurrent()
        defer { scheduleIdleSleep(timeoutSeconds: idleSleepSeconds) }

        var request = try makeRequest(
            audioFileURL: audioFileURL,
            language: language,
            timeoutSeconds: timeoutSeconds
        )
        request.httpMethod = "POST"

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw TranscriptionClient.ClientError.timeout
        } catch {
            throw error
        }

        guard let http = response as? HTTPURLResponse else {
            throw WarmServerError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw WarmServerError.badHTTPStatus(http.statusCode, body)
        }

        let decoded: ServerResponse
        do {
            decoded = try JSONDecoder().decode(ServerResponse.self, from: data)
        } catch {
            throw WarmServerError.invalidResponse
        }

        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
        let text = decoded.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let detectedLanguage = decoded.language?.trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptionResult(
            text: text,
            language: (detectedLanguage?.isEmpty == true ? nil : detectedLanguage),
            language_probability: decoded.language_probability,
            elapsed_ms: elapsedMs
        )
    }

    func shutdown(reason: String) {
        idleSleepTask?.cancel()
        idleSleepTask = nil
        idleToken += 1

        guard let process else { return }
        Log.network.info("Stopping warm whisper-server: \(reason, privacy: .public)")
        if process.isRunning {
            process.terminate()
        }
        self.process = nil
        self.executablePath = nil
        self.modelPath = nil
        self.logHandle?.closeFile()
        self.logHandle = nil
    }

    private func ensureRunning(modelPath: String, whisperBinaryPath: String) async throws {
        guard let serverExecutable = TranscriptionClient.resolveWhisperServerExecutable(configuredPath: whisperBinaryPath) else {
            throw WarmServerError.missingExecutable
        }

        if let process,
           process.isRunning,
           self.modelPath == modelPath,
           self.executablePath == serverExecutable
        {
            return
        }

        shutdown(reason: "reconfigure")

        let candidatePorts = [9091, 9092, 9093]
        var lastError: Error = WarmServerError.startupTimeout
        for candidatePort in candidatePorts {
            do {
                try await startServer(
                    executablePath: serverExecutable,
                    modelPath: modelPath,
                    port: candidatePort
                )
                return
            } catch {
                lastError = error
                shutdown(reason: "start failed on port \(candidatePort)")
            }
        }
        throw lastError
    }

    private func startServer(executablePath: String, modelPath: String, port: Int) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = [
            "-m", modelPath,
            "-l", "auto",
            "-t", String(TranscriptionClient.defaultThreadCount()),
            "--host", "127.0.0.1",
            "--port", String(port),
        ]

        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("wispr_whisper_server.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            logHandle.closeFile()
            throw WarmServerError.startupFailed(error.localizedDescription)
        }

        self.process = process
        self.logHandle = logHandle
        self.executablePath = executablePath
        self.modelPath = modelPath
        self.port = port
        self.lastActivityAt = Date()

        do {
            try await waitForReadiness(timeoutSeconds: 45)
            Log.network.info(
                "Warm whisper-server ready pid=\(process.processIdentifier, privacy: .public) port=\(port, privacy: .public) model=\(modelPath, privacy: .public)"
            )
        } catch {
            throw error
        }
    }

    private func waitForReadiness(timeoutSeconds: Double) async throws {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        let url = URL(string: "http://127.0.0.1:\(port)/")!
        while Date() < deadline {
            guard let process, process.isRunning else {
                let tail = readServerLogTail(maxBytes: 1500)
                throw WarmServerError.startupFailed(tail.isEmpty ? "process exited early" : tail)
            }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 0.6
                _ = try await URLSession.shared.data(for: request)
                return
            } catch {
                // Connection refused until server is fully up.
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        throw WarmServerError.startupTimeout
    }

    private func scheduleIdleSleep(timeoutSeconds: Double) {
        lastActivityAt = Date()
        idleSleepTask?.cancel()

        guard timeoutSeconds > 0 else { return }
        idleToken += 1
        let token = idleToken
        let nanos = UInt64(max(1, timeoutSeconds) * 1_000_000_000)
        idleSleepTask = Task {
            try? await Task.sleep(nanoseconds: nanos)
            self.shutdownIfIdle(token: token, timeoutSeconds: timeoutSeconds)
        }
    }

    private func shutdownIfIdle(token: Int, timeoutSeconds: Double) {
        guard token == idleToken else { return }
        let idleSeconds = Date().timeIntervalSince(lastActivityAt)
        guard idleSeconds >= timeoutSeconds else { return }
        shutdown(reason: "idle timeout")
    }

    private func makeRequest(
        audioFileURL: URL,
        language: String,
        timeoutSeconds: Double
    ) throws -> URLRequest {
        let boundary = "Boundary-\(UUID().uuidString)"
        let url = URL(string: "http://127.0.0.1:\(port)/inference")!
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds > 0 ? timeoutSeconds : 300
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.makeMultipartBody(
            boundary: boundary,
            fileURL: audioFileURL,
            language: language
        )
        return request
    }

    private static func makeMultipartBody(
        boundary: String,
        fileURL: URL,
        language: String
    ) throws -> Data {
        let fileData = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        var data = Data()

        func appendField(name: String, value: String) {
            data.append("--\(boundary)\r\n".data(using: .utf8)!)
            data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            data.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField(name: "response_format", value: "verbose_json")
        appendField(name: "language", value: language)
        appendField(name: "temperature", value: "0")

        data.append("--\(boundary)\r\n".data(using: .utf8)!)
        data.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(fileURL.lastPathComponent)\"\r\n".data(using: .utf8)!
        )
        data.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        data.append(fileData)
        data.append("\r\n".data(using: .utf8)!)
        data.append("--\(boundary)--\r\n".data(using: .utf8)!)
        return data
    }

    private func readServerLogTail(maxBytes: Int) -> String {
        guard let handle = logHandle else { return "" }
        do {
            let end = try handle.seekToEnd()
            let start = max(0, end - UInt64(maxBytes))
            try handle.seek(toOffset: start)
            let data = try handle.readToEnd() ?? Data()
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        } catch {
            return ""
        }
    }
}

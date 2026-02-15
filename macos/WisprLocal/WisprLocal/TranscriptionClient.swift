import Foundation

struct TranscriptionResult: Decodable, Sendable {
    let text: String
    let language: String?
    let language_probability: Double?
    let elapsed_ms: Int?
}

struct TranscriptionClient: Sendable {
    enum ClientError: Error, LocalizedError {
        case invalidURL
        case invalidResponse
        case httpError(Int, String)
        case timeout
        case curlFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid server URL."
            case .invalidResponse:
                return "Invalid server response."
            case let .httpError(code, message):
                return "HTTP \(code): \(message)"
            case .timeout:
                return "Request timed out."
            case let .curlFailed(message):
                return "curl failed: \(message)"
            }
        }
    }

    func transcribe(
        audioFileURL: URL,
        serverURLString: String,
        apiKey: String?,
        language: String?
    ) async throws -> TranscriptionResult {
        guard var components = URLComponents(string: serverURLString) else {
            throw ClientError.invalidURL
        }

        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "task", value: "transcribe"))
        if let language, !language.isEmpty {
            query.append(URLQueryItem(name: "language", value: language))
        }
        components.queryItems = query

        guard let url = components.url else { throw ClientError.invalidURL }

        let fileBytes = (try? FileManager.default.attributesOfItem(atPath: audioFileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        Log.network.info("TranscriptionClient.transcribe url=\(url.absoluteString, privacy: .public) bytes=\(fileBytes, privacy: .public)")

        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // URLSession + HTTP/3 (QUIC) can sometimes hang behind certain networks/Cloudflare setups.
        // We'll try URLSession first with a short timeout, then fall back to curl (TCP) if needed.
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let apiKey, !apiKey.isEmpty {
            req.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }

        let audioData = try Data(contentsOf: audioFileURL)
        req.httpBody = makeMultipartBody(boundary: boundary, fileData: audioData, filename: audioFileURL.lastPathComponent)
        let request = req

        do {
            // Backend is usually sub-second; if URLSession hangs (often HTTP/3/QUIC), fall back fast.
            return try await withTimeout(seconds: 4) {
                try await transcribeViaURLSession(request: request)
            }
        } catch {
            Log.network.error("URLSession attempt failed: \(String(describing: error), privacy: .public). Falling back to curl.")
            // If we got an HTTP response from the server, don't retry with curl.
            if case ClientError.httpError = error {
                throw error
            }
            if case ClientError.invalidResponse = error {
                throw error
            }
            // Otherwise, retry via curl (forces HTTP/2/TCP, avoids flaky HTTP/3 paths).
            return try await transcribeViaCurl(url: url, apiKey: apiKey, audioFileURL: audioFileURL)
        }
    }

    private func transcribeViaURLSession(request: URLRequest) async throws -> TranscriptionResult {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false

        let session = URLSession(configuration: config)
        let started = CFAbsoluteTimeGetCurrent()
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClientError.invalidResponse
            }

            if http.statusCode < 200 || http.statusCode >= 300 {
                let message = Self.extractErrorMessage(from: data) ?? String(data: data, encoding: .utf8) ?? "Request failed"
                throw ClientError.httpError(http.statusCode, message)
            }

            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            Log.network.info("URLSession ok status=\(http.statusCode, privacy: .public) ms=\(ms, privacy: .public) bytes=\(data.count, privacy: .public)")
            return try JSONDecoder().decode(TranscriptionResult.self, from: data)
        } catch {
            if let urlError = error as? URLError, urlError.code == .timedOut {
                throw ClientError.timeout
            }
            throw error
        }
    }

    private func transcribeViaCurl(url: URL, apiKey: String?, audioFileURL: URL) async throws -> TranscriptionResult {
        Log.network.info("curl fallback starting url=\(url.absoluteString, privacy: .public)")
        let marker = "__WISPR_HTTP_CODE__:"
        let markerPrefix = "\n\(marker)"
        let format = "\(markerPrefix)%{http_code}\n"

        let responseData: Data = try await Task.detached(priority: .userInitiated) {
            let started = CFAbsoluteTimeGetCurrent()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")

            var args: [String] = [
                "-sS",
                "--http2",
                "--connect-timeout", "10",
                "--max-time", "30",
                "-H", "Accept: application/json",
            ]
            if let apiKey, !apiKey.isEmpty {
                args += ["-H", "X-API-Key: \(apiKey)"]
            }
            args += [
                "-F", "file=@\(audioFileURL.path)",
                "-w", format,
                url.absoluteString,
            ]
            process.arguments = args

            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            try process.run()
            process.waitUntilExit()

            let stdoutData = out.fileHandleForReading.readDataToEndOfFile()
            let stderrData = err.fileHandleForReading.readDataToEndOfFile()

            if process.terminationStatus != 0 {
                let msg = String(data: stderrData, encoding: .utf8) ?? "exit \(process.terminationStatus)"
                throw ClientError.curlFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
            }

            let ms = Int((CFAbsoluteTimeGetCurrent() - started) * 1000)
            Log.network.info("curl ok ms=\(ms, privacy: .public) bytes=\(stdoutData.count, privacy: .public)")
            return stdoutData
        }.value

        guard let raw = String(data: responseData, encoding: .utf8) else {
            throw ClientError.invalidResponse
        }

        guard let range = raw.range(of: markerPrefix) else {
            throw ClientError.invalidResponse
        }

        let bodyString = String(raw[..<range.lowerBound])
        let codeString = raw[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let code = Int(codeString) ?? -1

        let bodyData = bodyString.data(using: .utf8) ?? Data()

        if code < 200 || code >= 300 {
            let message = Self.extractErrorMessage(from: bodyData) ?? bodyString.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClientError.httpError(code, message.isEmpty ? "Request failed" : message)
        }

        return try JSONDecoder().decode(TranscriptionResult.self, from: bodyData)
    }

    private func makeMultipartBody(boundary: String, fileData: Data, filename: String) -> Data {
        var data = Data()

        data.appendString("--\(boundary)\r\n")
        data.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        data.appendString("Content-Type: audio/wav\r\n\r\n")
        data.append(fileData)
        data.appendString("\r\n")
        data.appendString("--\(boundary)--\r\n")

        return data
    }

    private static func extractErrorMessage(from data: Data) -> String? {
        struct ErrorBody: Decodable { let detail: String? }
        return (try? JSONDecoder().decode(ErrorBody.self, from: data).detail)
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let nanos = UInt64(max(0, seconds) * 1_000_000_000)
        return try await withThrowingTaskGroup(of: T.self) { group in
            defer { group.cancelAll() }

            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: nanos)
                throw ClientError.timeout
            }

            guard let first = try await group.next() else {
                throw ClientError.timeout
            }
            return first
        }
    }
}

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}

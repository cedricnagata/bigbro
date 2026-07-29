import Foundation

/// A snapshot of an in-flight model installation.
struct ModelInstallProgress: Equatable {
    var status: String           // "downloading", "verifying digest", etc.
    var bytesCompleted: Int64
    var bytesTotal: Int64
    var done: Bool
    var error: String?

    var percent: Double {
        bytesTotal > 0 ? Double(bytesCompleted) / Double(bytesTotal) : 0
    }
}

/// Installs a model on a backend, reporting progress as it goes.
///
/// This is the one capability with no OpenAI-compatible equivalent: `/v1/models` lists what
/// is available but cannot pull anything, so every backend needs its own implementation.
/// Backends with no install API at all simply have no conformer, and callers surface an
/// actionable error rather than starting a download that can never finish.
protocol ModelInstalling {
    /// Streams progress until the install completes or fails. The final element always has
    /// `done == true`.
    func install(_ model: String) -> AsyncThrowingStream<ModelInstallProgress, Error>
}

// MARK: - Ollama

/// Ollama's `POST /api/pull` streams NDJSON, one object per line. Byte counts arrive
/// per-layer digest rather than as a single figure, so they are summed across digests.
struct OllamaInstaller: ModelInstalling {

    func install(_ model: String) -> AsyncThrowingStream<ModelInstallProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                var current = ModelInstallProgress(status: "starting", bytesCompleted: 0,
                                                   bytesTotal: 0, done: false, error: nil)
                var perDigest: [String: (completed: Int64, total: Int64)] = [:]

                do {
                    guard let url = AppSettings.shared.pullURL else {
                        throw InferenceError.invalidConfiguration
                    }
                    var req = URLRequest(url: url)
                    req.httpMethod = "POST"
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = try JSONSerialization.data(withJSONObject: ["name": model, "stream": true])
                    req.timeoutInterval = 3600  // pulls can take a long time

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        throw InferenceError.upstreamFailure(statusCode: code, body: nil)
                    }

                    for try await line in bytes.lines {
                        if Task.isCancelled { break }
                        guard !line.isEmpty,
                              let data = line.data(using: .utf8),
                              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { continue }

                        if let err = json["error"] as? String {
                            throw NSError(domain: "OllamaInstaller", code: -1,
                                          userInfo: [NSLocalizedDescriptionKey: err])
                        }

                        let status = (json["status"] as? String) ?? current.status
                        if let digest = json["digest"] as? String,
                           let total = Self.int64(json["total"]) {
                            perDigest[digest] = (completed: Self.int64(json["completed"]) ?? 0, total: total)
                        }

                        current.status = status
                        current.bytesTotal = perDigest.values.reduce(Int64(0)) { $0 + $1.total }
                        current.bytesCompleted = perDigest.values.reduce(Int64(0)) { $0 + $1.completed }

                        if status == "success" {
                            current.done = true
                            current.bytesCompleted = current.bytesTotal
                            continuation.yield(current)
                            continuation.finish()
                            return
                        }
                        continuation.yield(current)
                    }

                    // The stream ended without reporting success.
                    current.done = true
                    current.error = "download ended unexpectedly"
                    continuation.yield(current)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let v = value as? Int64 { return v }
        if let v = value as? Int { return Int64(v) }
        if let v = value as? Double { return Int64(v) }
        return nil
    }
}

// MARK: - LocalAI

/// LocalAI installs from its model gallery: `POST /models/apply` returns a job id, and
/// `GET /models/jobs/<id>` is then polled. There is no stream, so the poll interval — not
/// the server — sets how often progress updates.
struct LocalAIInstaller: ModelInstalling {
    /// Matches ModelDownloader's emit throttle, so polling never outpaces what is published.
    private static let pollInterval = Duration.seconds(1)

    /// Polling has no natural end the way a closed stream does, so a stalled job would
    /// otherwise be polled forever. Generous enough for a multi-gigabyte gallery model.
    private static let deadline: TimeInterval = 2 * 60 * 60

    func install(_ model: String) -> AsyncThrowingStream<ModelInstallProgress, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let jobId = try await startJob(model)
                    var current = ModelInstallProgress(status: "starting", bytesCompleted: 0,
                                                       bytesTotal: 0, done: false, error: nil)
                    continuation.yield(current)

                    let started = Date()
                    while !Task.isCancelled {
                        if Date().timeIntervalSince(started) > Self.deadline {
                            current.done = true
                            current.error = "install timed out"
                            continuation.yield(current)
                            continuation.finish()
                            return
                        }
                        try await Task.sleep(for: Self.pollInterval)
                        guard let job = try await poll(jobId) else { continue }

                        current.status = (job["message"] as? String) ?? current.status

                        // Byte counts are only sometimes numeric; fall back to the percentage
                        // so `percent` stays meaningful either way.
                        if let total = Self.int64(job["file_size"]), total > 0 {
                            current.bytesTotal = total
                            current.bytesCompleted = Self.int64(job["downloaded_size"]) ?? current.bytesCompleted
                        } else if let pct = Self.double(job["progress"]) {
                            current.bytesTotal = 100
                            current.bytesCompleted = Int64(pct.rounded())
                        }

                        if let err = job["error"] as? String, !err.isEmpty {
                            current.done = true
                            current.error = err
                            continuation.yield(current)
                            continuation.finish()
                            return
                        }
                        if (job["processed"] as? Bool) == true {
                            current.done = true
                            if current.bytesTotal > 0 { current.bytesCompleted = current.bytesTotal }
                            continuation.yield(current)
                            continuation.finish()
                            return
                        }
                        continuation.yield(current)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Returns the job id for the started install.
    private func startJob(_ model: String) async throws -> String {
        guard let url = AppSettings.shared.localAIApplyURL else {
            throw InferenceError.invalidConfiguration
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["id": model])
        req.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw InferenceError.upstreamFailure(statusCode: code,
                                                 body: String(data: data.prefix(2000), encoding: .utf8))
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uuid = json["uuid"] as? String else {
            throw InferenceError.invalidResponse
        }
        return uuid
    }

    /// One poll of the job. Returns nil for a transient failure so the loop can retry.
    private func poll(_ jobId: String) async throws -> [String: Any]? {
        guard let url = AppSettings.shared.localAIJobURL(jobId) else {
            throw InferenceError.invalidConfiguration
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let v = value as? Int64 { return v }
        if let v = value as? Int { return Int64(v) }
        if let v = value as? Double { return Int64(v) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let v = value as? Double { return v }
        if let v = value as? Int { return Double(v) }
        if let v = value as? String { return Double(v) }
        return nil
    }
}

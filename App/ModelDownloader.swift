import Foundation
import Combine

/// Drives `ollama pull` for missing models and publishes per-model progress.
/// Throttled progress updates (~1/sec) are emitted via a Combine publisher so
/// both the Mac UI and the peer broadcaster can subscribe without flooding.
@MainActor
final class ModelDownloader: ObservableObject {
    struct Progress: Equatable {
        var status: String           // "downloading", "verifying digest", etc.
        var bytesCompleted: Int64
        var bytesTotal: Int64
        var done: Bool
        var error: String?

        var percent: Double {
            bytesTotal > 0 ? Double(bytesCompleted) / Double(bytesTotal) : 0
        }
    }

    /// Map of model → current progress. Models that finished or errored are
    /// removed shortly after completion.
    @Published private(set) var progress: [String: Progress] = [:]

    /// Fires every time a per-model progress entry mutates. Subscribers get
    /// (model, progress) — useful for broadcasting to peers without diffing
    /// the whole map.
    let updates = PassthroughSubject<(model: String, progress: Progress), Never>()

    private var tasks: [String: Task<Void, Never>] = [:]
    private var lastEmitted: [String: Date] = [:]
    private let throttleInterval: TimeInterval = 1.0

    var activeModels: Set<String> {
        Set(tasks.keys)
    }

    func isDownloading(_ model: String) -> Bool {
        tasks[model] != nil
    }

    /// Starts a pull for the given model. Returns true if a new download was
    /// started, false if one was already in progress.
    @discardableResult
    func startDownload(_ model: String) -> Bool {
        guard tasks[model] == nil else {
            print("[ModelDownloader] \(model) already downloading")
            return false
        }
        print("[ModelDownloader] Starting download: \(model)")
        let initial = Progress(status: "starting", bytesCompleted: 0, bytesTotal: 0, done: false, error: nil)
        progress[model] = initial
        emit(model: model, progress: initial, force: true)

        tasks[model] = Task { @MainActor [weak self] in
            await self?.run(model: model)
        }
        return true
    }

    func cancel(_ model: String) {
        tasks[model]?.cancel()
        tasks[model] = nil
        if var p = progress[model] {
            p.done = true
            p.error = "cancelled"
            emit(model: model, progress: p, force: true)
        }
        progress.removeValue(forKey: model)
    }

    // MARK: - Private

    private func run(model: String) async {
        defer { tasks[model] = nil }
        var current = progress[model] ?? Progress(status: "starting", bytesCompleted: 0, bytesTotal: 0, done: false, error: nil)
        var perDigest: [String: (completed: Int64, total: Int64)] = [:]

        do {
            let url = URL(string: "\(OllamaMonitor.baseURL)/api/pull")!
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["name": model, "stream": true])
            req.timeoutInterval = 3600  // pulls can take a long time

            let (bytes, response) = try await URLSession.shared.bytes(for: req)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                throw NSError(domain: "ModelDownloader", code: code, userInfo: [NSLocalizedDescriptionKey: "Ollama returned HTTP \(code)"])
            }

            for try await line in bytes.lines {
                if Task.isCancelled { break }
                guard !line.isEmpty,
                      let data = line.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                if let err = json["error"] as? String {
                    throw NSError(domain: "ModelDownloader", code: -1, userInfo: [NSLocalizedDescriptionKey: err])
                }

                let status = (json["status"] as? String) ?? current.status
                if let digest = json["digest"] as? String,
                   let total = (json["total"] as? Int64) ?? (json["total"] as? Int).map(Int64.init) {
                    let completed = (json["completed"] as? Int64) ?? (json["completed"] as? Int).map(Int64.init) ?? 0
                    perDigest[digest] = (completed: completed, total: total)
                }

                let totalBytes = perDigest.values.reduce(Int64(0)) { $0 + $1.total }
                let doneBytes = perDigest.values.reduce(Int64(0)) { $0 + $1.completed }

                current.status = status
                current.bytesCompleted = doneBytes
                current.bytesTotal = totalBytes

                if status == "success" {
                    current.done = true
                    current.bytesCompleted = totalBytes
                    progress[model] = current
                    emit(model: model, progress: current, force: true)
                    print("[ModelDownloader] \(model) complete")
                    // Drop from the published map shortly so UI clears.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(2))
                        self?.progress.removeValue(forKey: model)
                    }
                    return
                } else {
                    progress[model] = current
                    emit(model: model, progress: current, force: false)
                }
            }
            // Stream ended without "success" — treat as failure.
            current.done = true
            current.error = "download ended unexpectedly"
            progress[model] = current
            emit(model: model, progress: current, force: true)
            print("[ModelDownloader] \(model) ended without success")
        } catch is CancellationError {
            print("[ModelDownloader] \(model) cancelled")
        } catch {
            print("[ModelDownloader] \(model) failed: \(error)")
            current.done = true
            current.error = error.localizedDescription
            progress[model] = current
            emit(model: model, progress: current, force: true)
        }

        // Clear failed entry after a short delay so the UI can show the error.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if self?.progress[model]?.error != nil {
                self?.progress.removeValue(forKey: model)
            }
        }
    }

    private func emit(model: String, progress: Progress, force: Bool) {
        let now = Date()
        if !force,
           let last = lastEmitted[model],
           now.timeIntervalSince(last) < throttleInterval,
           !progress.done {
            return
        }
        lastEmitted[model] = now
        updates.send((model: model, progress: progress))
    }
}

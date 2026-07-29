import Foundation
import Combine

/// Drives installation of missing models and publishes per-model progress.
///
/// Throttled progress updates (~1/sec) are emitted via a Combine publisher so both the Mac
/// UI and the peer broadcaster can subscribe without flooding.
///
/// The transport lives behind `ModelInstalling` — Ollama streams NDJSON from `/api/pull`,
/// LocalAI polls a gallery job — so this type only coordinates state and throttling.
@MainActor
final class ModelDownloader: ObservableObject {
    /// Kept as a nested name so existing call sites read unchanged.
    typealias Progress = ModelInstallProgress

    /// Map of model → current progress. Models that finished or errored are removed shortly
    /// after completion.
    @Published private(set) var progress: [String: Progress] = [:]

    /// Fires every time a per-model progress entry mutates. Subscribers get
    /// (model, progress) — useful for broadcasting to peers without diffing the whole map.
    let updates = PassthroughSubject<(model: String, progress: Progress), Never>()

    private let installer: ModelInstalling
    private var tasks: [String: Task<Void, Never>] = [:]
    private var lastEmitted: [String: Date] = [:]
    private let throttleInterval: TimeInterval = 1.0

    init(installer: ModelInstalling = OllamaInstaller()) {
        self.installer = installer
    }

    var activeModels: Set<String> {
        Set(tasks.keys)
    }

    func isDownloading(_ model: String) -> Bool {
        tasks[model] != nil
    }

    /// Starts an install for the given model. Returns true if a new install was started,
    /// false if one was already in progress.
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
        var current = progress[model] ?? Progress(status: "starting", bytesCompleted: 0,
                                                  bytesTotal: 0, done: false, error: nil)
        do {
            for try await update in installer.install(model) {
                if Task.isCancelled { break }
                current = update
                progress[model] = current
                emit(model: model, progress: current, force: current.done)

                if current.done {
                    if let error = current.error {
                        print("[ModelDownloader] \(model) failed: \(error)")
                    } else {
                        print("[ModelDownloader] \(model) complete")
                    }
                    scheduleClear(model)
                    return
                }
            }
            if Task.isCancelled {
                print("[ModelDownloader] \(model) cancelled")
                return
            }
            // The installer finished without ever reporting a terminal update.
            current.done = true
            current.error = "download ended unexpectedly"
            progress[model] = current
            emit(model: model, progress: current, force: true)
            print("[ModelDownloader] \(model) ended without success")
            scheduleClear(model)
        } catch is CancellationError {
            print("[ModelDownloader] \(model) cancelled")
        } catch {
            print("[ModelDownloader] \(model) failed: \(error)")
            current.done = true
            current.error = error.localizedDescription
            progress[model] = current
            emit(model: model, progress: current, force: true)
            scheduleClear(model)
        }
    }

    /// Drops a finished entry after a beat, so the UI can show the terminal state first.
    /// Failures linger longer than successes so the message is readable.
    private func scheduleClear(_ model: String) {
        let failed = progress[model]?.error != nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(failed ? 4 : 2))
            self?.progress.removeValue(forKey: model)
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

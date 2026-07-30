import Foundation

/// Bridges `MLXEngine.ensureLoaded` to `ModelInstalling`, so `ModelDownloader` — and its
/// throttling and peer `modelDownloadProgress` broadcast — needs no changes at all.
///
/// The model string a client requests (an Ollama-style tag like `gpt-oss:20b` or
/// `qwen3-vl:30b`) is mapped onto one of the two fixed local models using the same
/// "does the name mention vision" heuristic as `MLXEngine.isRequiredModelSatisfied`.
///
/// mlx-swift-lm's `Progress` reports combined download-and-weight-load as a single fraction
/// with no separate phase signal, so `bytesTotal`/`bytesCompleted` here are a fixed-scale
/// percentage rather than real byte counts — the same "percentage only" shape
/// `ModelDownloadProgress` already tolerates.
struct MLXInstaller: ModelInstalling {
    private static let percentScale: Int64 = 10_000

    func install(_ model: String) -> AsyncThrowingStream<ModelInstallProgress, Error> {
        let kind = MLXEngine.ModelKind.matching(declaredName: model)

        return AsyncThrowingStream { continuation in
            Task { @MainActor in
                var current = ModelInstallProgress(status: "starting", bytesCompleted: 0,
                                                   bytesTotal: Self.percentScale, done: false, error: nil)
                continuation.yield(current)
                do {
                    _ = try await MLXEngine.shared.ensureLoaded(kind) { fraction in
                        Task { @MainActor in
                            current.status = "downloading \(kind.displayName)"
                            current.bytesCompleted = Int64((fraction * Double(Self.percentScale)).rounded())
                            continuation.yield(current)
                        }
                    }
                    current.done = true
                    current.bytesCompleted = current.bytesTotal
                    current.status = "ready"
                    continuation.yield(current)
                    continuation.finish()
                } catch {
                    current.done = true
                    current.error = error.localizedDescription
                    continuation.yield(current)
                    continuation.finish()
                }
            }
        }
    }
}

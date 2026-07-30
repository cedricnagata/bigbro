import Foundation

/// Bridges `MLXEngine.download` to `ModelInstalling`, so `ModelDownloader` — and its
/// throttling and peer `modelDownloadProgress` broadcast — needs no changes at all.
///
/// Downloads only. Installing a model used to run it too, because the only available call
/// downloaded and materialized in one step — so pulling a 12 GB model from Settings also
/// pinned 12 GB of memory nobody asked to spend. Fetching the weights and starting the model
/// are now separate, and this is the fetch.
///
/// Installs are keyed by catalog id. A name that resolves to nothing is a hard error rather
/// than a fallback: this path exists to fetch one specific model, and quietly downloading a
/// different one would be worse than saying so.
///
/// mlx-swift-lm's `Progress` reports combined download-and-weight-load as a single fraction
/// with no separate phase signal, so `bytesTotal`/`bytesCompleted` here are a fixed-scale
/// percentage rather than real byte counts — the same "percentage only" shape
/// `ModelDownloadProgress` already tolerates.
struct MLXInstaller: ModelInstalling {
    private static let percentScale: Int64 = 10_000

    func install(_ model: String) -> AsyncThrowingStream<ModelInstallProgress, Error> {
        AsyncThrowingStream { continuation in
            Task { @MainActor in
                var current = ModelInstallProgress(status: "starting", bytesCompleted: 0,
                                                   bytesTotal: Self.percentScale, done: false, error: nil)
                continuation.yield(current)

                guard let entry = ModelCatalog.resolve(model) else {
                    current.done = true
                    current.error = InferenceError.unknownModel(model).localizedDescription
                    continuation.yield(current)
                    continuation.finish()
                    return
                }

                do {
                    _ = try await MLXEngine.shared.download(entry) { fraction in
                        Task { @MainActor in
                            current.status = "downloading \(entry.displayName)"
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

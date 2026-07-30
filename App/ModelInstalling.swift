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

/// Installs a model, reporting progress as it goes.
///
/// The one conformer is `MLXInstaller` (Inference/MLXInstaller.swift), which drives
/// `MLXEngine.download` — fetching weights to disk, separate from starting the model, not a
/// separate step, so there is no network code left in this file at all.
protocol ModelInstalling {
    /// Streams progress until the install completes or fails. The final element always has
    /// `done == true`.
    func install(_ model: String) -> AsyncThrowingStream<ModelInstallProgress, Error>
}

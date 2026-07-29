import Foundation
import Combine

/// Polls the speech backend for reachability and the voice list.
///
/// Mirrors `OllamaMonitor`, with two differences that come from speech being optional and
/// less standardised: it reports `.disabled` when the user has not enabled it (and then does
/// no network work at all), and it tolerates a backend with no voice-listing endpoint —
/// mlx-audio, for one, does not document `/v1/audio/voices`.
@MainActor
final class SpeechMonitor: ObservableObject, BackendStatusReporting {
    @Published var status: BackendStatus = .disabled
    @Published var availableVoices: [String] = []
    @Published var availableModels: [String] = []

    /// Used when the backend has no voice-listing endpoint. These are Kokoro's presets,
    /// which are stable and by far the most common local voices.
    static let fallbackVoices = [
        "af_heart", "af_bella", "af_nova", "af_sky", "af_sarah",
        "am_adam", "am_echo", "am_michael",
        "bf_alice", "bf_emma", "bm_daniel", "bm_george",
    ]

    // MARK: - BackendStatusReporting

    var runningSummary: String {
        "Running (\(availableVoices.count) voice\(availableVoices.count == 1 ? "" : "s"))"
    }

    var detailItems: [String] { availableVoices }

    var unreachableHint: String {
        "Not reachable at \(AppSettings.speechBaseURL)"
    }

    private var pollTask: Task<Void, Never>?

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        guard AppSettings.shared.speechEnabled else {
            status = .disabled
            availableVoices = []
            availableModels = []
            return
        }

        guard let url = AppSettings.shared.speechModelsURL,
              let models = await fetchModels(url) else {
            status = .unreachable
            availableVoices = []
            availableModels = []
            return
        }

        status = .running
        availableModels = models
        availableVoices = await fetchVoices() ?? Self.fallbackVoices
    }

    // MARK: - Private

    private func fetchModels(_ url: URL) async -> [String]? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["data"] as? [[String: Any]] else {
            return nil
        }
        return entries.compactMap { $0["id"] as? String }
    }

    /// `/v1/audio/voices` is not part of the OpenAI spec, so backends that implement it
    /// disagree on the shape and others return 404. Returns nil when nothing usable came
    /// back, so the caller can fall back to a known list.
    private func fetchVoices() async -> [String]? {
        guard let url = AppSettings.shared.voicesURL,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }

        let root = try? JSONSerialization.jsonObject(with: data)
        let raw: Any? = (root as? [String: Any])?["voices"] ?? root
        let voices: [String]

        if let names = raw as? [String] {
            voices = names
        } else if let objects = raw as? [[String: Any]] {
            voices = objects.compactMap {
                ($0["voice_id"] as? String) ?? ($0["id"] as? String) ?? ($0["name"] as? String)
            }
        } else {
            return nil
        }
        return voices.isEmpty ? nil : voices
    }
}

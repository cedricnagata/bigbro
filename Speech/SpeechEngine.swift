import Foundation
import Combine
import AVFoundation
import FluidAudio

/// Text-to-speech (Kokoro) and speech-to-text (Parakeet) in-process via FluidAudio,
/// replacing the LocalAI OpenAI-compatible proxy. Both models are CoreML/Neural-Engine —
/// no relation to the MLX text/vision models in `MLXEngine`, so they load independently.
///
/// Each is tracked through the same lifecycle as a catalog model in `MLXEngine` — not
/// downloaded, downloading, downloaded, starting, running, failed — so Settings can present
/// "TTS models" and "STT models" sections with the same Download/Run/Stop/Remove controls as
/// Language and Vision, rather than a single on/off switch for both. There is deliberately no
/// "enabled" flag: like a language model, a speech model starts lazily on whichever request
/// needs it first, or explicitly from Settings.
///
/// `AppRouter`'s speech handlers are unchanged in shape: `synthesize` still streams `Data`
/// chunks and `transcribe` still returns `(text:, language:)`. Only the format contract
/// tightens — synthesis is always 24 kHz 16-bit mono PCM now, because that is the only format
/// Kokoro produces and the only one `BigBroAudioPlayer` (BigBroKit) is written to expect.
@MainActor
final class SpeechEngine: ObservableObject, BackendStatusReporting {
    static let shared = SpeechEngine()

    static let sampleRate = 24_000
    private static let chunkBytes = 8 * 1024

    /// Used when a request names no voice. Not user-configurable here — voice selection is a
    /// BigBroKit concern end to end (see `BigBroClient.defaultVoice`); this only covers a raw
    /// wire request that omits `voice` entirely.
    static let defaultVoice = "af_heart"

    enum ModelKind: String, CaseIterable, Identifiable {
        case tts
        case stt

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .tts: return "Kokoro (Speech)"
            case .stt: return "Parakeet (Transcription)"
            }
        }

        fileprivate var readyDefaultsKey: String { "bigbro.speechModelReady.\(rawValue)" }
    }

    /// Where a speech model is in its lifecycle. Mirrors `MLXEngine.ModelRunState` — downloaded
    /// and running are genuinely different states, not two names for one, so Settings can show
    /// and control them separately just like a language model.
    enum ModelRunState: Equatable {
        case notDownloaded
        case downloading(Double)
        case downloaded
        case starting
        case running
        case failed(String)

        var description: String {
            switch self {
            case .notDownloaded:        return "not downloaded"
            case .downloading(let p):   return "downloading \(Int((p * 100).rounded()))%"
            case .downloaded:           return "downloaded"
            case .starting:             return "starting"
            case .running:              return "running"
            case .failed(let message):  return "error: \(message)"
            }
        }
    }

    @Published private(set) var loadProgress: [ModelKind: Double] = [:]
    @Published private(set) var loadErrors: [ModelKind: String] = [:]

    /// Bumped whenever a model's lifecycle state changes, for the same reason
    /// `MLXEngine.stateRevision` exists: `state(_:)` reads plain instance state SwiftUI cannot
    /// observe on its own.
    @Published private var stateRevision = 0

    private var tts: KokoroTtsManager?
    private var asr: AsrManager?
    /// Kept in memory after `download(.tts)` so a later `run(.tts)` in the same launch doesn't
    /// recompile the CoreML models from disk a second time. Kokoro's download step already
    /// produces loaded `MLModel`s (unlike Parakeet's, which only fetches files) — see `download`.
    private var ttsAssets: TtsModels?

    private var downloadTasks: [ModelKind: Task<Void, Error>] = [:]
    private var runTasks: [ModelKind: Task<Void, Error>] = [:]

    private init() {}

    private func stateChanged() { stateRevision &+= 1 }

    // MARK: - BackendStatusReporting

    /// In-process, like `MLXEngine` — there is no "unreachable", only "not downloaded yet",
    /// which Settings shows per model rather than a menu-bar banner.
    var status: BackendStatus { .running }

    var runningSummary: String {
        let running = ModelKind.allCases.filter(isRunning).count
        let downloaded = ModelKind.allCases.filter(isDownloaded).count
        return "\(running) running, \(downloaded) downloaded"
    }

    var detailItems: [String] {
        ModelKind.allCases
            .filter { state($0) != .notDownloaded }
            .map { "\($0.displayName): \(state($0).description)" }
    }

    var unreachableHint: String { "" }

    // MARK: - Model state

    func isRunning(_ kind: ModelKind) -> Bool {
        switch kind {
        case .tts: return tts != nil
        case .stt: return asr != nil
        }
    }

    /// Best-effort "has this been downloaded" check — true once a download has actually
    /// completed, same discipline as `MLXEngine.isDownloaded` (not a cache-path guess that
    /// could mistake a half-finished download for a complete one). FluidAudio exposes no cheap
    /// disk-presence check of its own, so this is backed by a flag set only on success.
    func isDownloaded(_ kind: ModelKind) -> Bool {
        isRunning(kind) || UserDefaults.standard.bool(forKey: kind.readyDefaultsKey)
    }

    func isBusy(_ kind: ModelKind) -> Bool {
        runTasks[kind] != nil || downloadTasks[kind] != nil
    }

    func state(_ kind: ModelKind) -> ModelRunState {
        if isRunning(kind) { return .running }
        if let error = loadErrors[kind] { return .failed(error) }
        if runTasks[kind] != nil { return isDownloaded(kind) ? .starting : .downloading(loadProgress[kind] ?? 0) }
        if downloadTasks[kind] != nil { return .downloading(loadProgress[kind] ?? 0) }
        return isDownloaded(kind) ? .downloaded : .notDownloaded
    }

    // MARK: - Lifecycle

    /// A directory BigBro owns for this model's weights, rather than trusting FluidAudio's
    /// default cache layout — the same discipline `MLXEngine` uses (record only a path this
    /// app controls), so `remove` can delete exactly this and nothing else.
    private static func directory(for kind: ModelKind) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BigBro/Speech/\(kind.rawValue)", isDirectory: true)
    }

    /// Fetches a model's weights to `directory(for:)` without starting it.
    @discardableResult
    func download(_ kind: ModelKind) async throws {
        if isDownloaded(kind) { return }
        if let existing = downloadTasks[kind] { return try await existing.value }

        let task = Task<Void, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                let dir = Self.directory(for: kind)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let progressHandler: DownloadUtils.ProgressHandler = { progress in
                    Task { @MainActor in self.loadProgress[kind] = progress.fractionCompleted }
                }
                switch kind {
                case .tts:
                    // Kokoro's download step already compiles and loads the CoreML models, so
                    // the result is kept rather than discarded — `run` reuses it instead of
                    // paying that cost twice.
                    self.ttsAssets = try await TtsModels.download(directory: dir, progressHandler: progressHandler)
                case .stt:
                    try await AsrModels.download(to: dir, version: .v3, progressHandler: progressHandler)
                }
                await MainActor.run {
                    self.loadProgress[kind] = 1.0
                    self.loadErrors[kind] = nil
                    self.downloadTasks[kind] = nil
                    UserDefaults.standard.set(true, forKey: kind.readyDefaultsKey)
                    self.stateChanged()
                }
            } catch {
                await MainActor.run {
                    self.loadErrors[kind] = error.localizedDescription
                    self.downloadTasks[kind] = nil
                    self.stateChanged()
                }
                throw error
            }
        }
        downloadTasks[kind] = task
        stateChanged()
        return try await task.value
    }

    /// Materializes a model into memory so it can synthesize or transcribe. Downloads first if
    /// needed.
    @discardableResult
    func run(_ kind: ModelKind) async throws {
        if isRunning(kind) { return }
        if let existing = runTasks[kind] { return try await existing.value }

        let task = Task<Void, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            do {
                try await self.download(kind)
                switch kind {
                case .tts:
                    let assets: TtsModels
                    if let cached = self.ttsAssets {
                        assets = cached
                    } else {
                        assets = try await TtsModels.download(directory: Self.directory(for: kind))
                        self.ttsAssets = assets
                    }
                    let manager = KokoroTtsManager(directory: Self.directory(for: kind))
                    try await manager.initialize(models: assets)
                    await MainActor.run { self.tts = manager }
                case .stt:
                    let models = try await AsrModels.load(from: Self.directory(for: kind), version: .v3)
                    let manager = AsrManager(config: .default)
                    try await manager.initialize(models: models)
                    await MainActor.run { self.asr = manager }
                }
                await MainActor.run {
                    self.loadErrors[kind] = nil
                    self.runTasks[kind] = nil
                    self.stateChanged()
                }
            } catch {
                await MainActor.run {
                    self.loadErrors[kind] = error.localizedDescription
                    self.runTasks[kind] = nil
                    self.stateChanged()
                }
                throw error
            }
        }
        runTasks[kind] = task
        stateChanged()
        return try await task.value
    }

    /// Unloads a model from memory, keeping its download. Starting it again is fast — the
    /// weights are still on disk, only the materialization (and, for Kokoro, a recompile from
    /// that disk cache) is repeated.
    func stop(_ kind: ModelKind) {
        switch kind {
        case .tts:
            guard tts != nil else { return }
            tts = nil
        case .stt:
            guard asr != nil else { return }
            asr = nil
        }
        stateChanged()
        print("[SpeechEngine] stopped \(kind.rawValue)")
    }

    /// Deletes a model's downloaded weights. Stops it first if it is running.
    func remove(_ kind: ModelKind) throws {
        stop(kind)
        loadErrors[kind] = nil
        loadProgress[kind] = nil
        if kind == .tts { ttsAssets = nil }

        let dir = Self.directory(for: kind)
        if FileManager.default.fileExists(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir)
            print("[SpeechEngine] removed \(kind.rawValue) from \(dir.path)")
        }
        UserDefaults.standard.removeObject(forKey: kind.readyDefaultsKey)
        stateChanged()
    }

    // MARK: - Synthesis

    func synthesize(
        text: String,
        voice: String? = nil,
        speed: Double? = nil
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.run(.tts)
                    guard let tts = self.tts else {
                        throw InferenceError.generationFailed("Text-to-speech is not loaded.")
                    }
                    let resolvedVoice = (voice?.isEmpty == false) ? voice! : Self.defaultVoice
                    let result = try await tts.synthesizeDetailed(
                        text: text, voice: resolvedVoice, voiceSpeed: Float(speed ?? 1.0)
                    )
                    // `result.audio` is a full WAV file (44-byte header + 16-bit mono PCM at
                    // Self.sampleRate) — strip the header for the wire protocol, which sends
                    // headerless raw PCM so BigBroAudioPlayer can split it at arbitrary byte
                    // boundaries.
                    let pcm = result.audio.dropFirst(Self.wavHeaderBytes)

                    var offset = pcm.startIndex
                    while offset < pcm.endIndex {
                        let end = min(offset + Self.chunkBytes, pcm.endIndex)
                        continuation.yield(pcm.subdata(in: offset..<end))
                        offset = end
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Transcription

    func transcribe(audio: Data, format: String) async throws -> (text: String, language: String?) {
        try await run(.stt)
        guard let asr else {
            throw InferenceError.generationFailed("Speech-to-text is not loaded.")
        }
        let samples = try Self.floatSamples(from: audio, format: format)
        let result = try await asr.transcribe(samples, source: .system)
        return (result.text, nil)
    }

    // MARK: - Audio conversion

    /// `AudioWAV.data(from:sampleRate:)` (FluidAudio/Shared/AudioConverter.swift) always
    /// writes a canonical 44-byte PCM WAV header (RIFF+WAVE, one `fmt ` chunk, one `data`
    /// chunk — no extra chunks), so stripping a fixed offset is exact, not a guess.
    private static let wavHeaderBytes = 44

    /// Decodes an arbitrary container (wav/m4a/etc, whatever the client sent) down to 16 kHz
    /// mono Float32 samples — what Parakeet expects — via a one-shot `AVAudioConverter` pass.
    private static func floatSamples(from audio: Data, format: String) throws -> [Float] {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(format)
        try audio.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        let file = try AVAudioFile(forReading: tempURL)
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        ) else {
            throw InferenceError.generationFailed("Could not create 16 kHz mono audio format.")
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw InferenceError.generationFailed("Could not create audio converter.")
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            throw InferenceError.generationFailed("Uploaded audio contained no frames.")
        }
        try file.read(into: inputBuffer)

        let ratio = outputFormat.sampleRate / max(inputFormat.sampleRate, 1)
        let outputCapacity = AVAudioFrameCount(Double(frameCount) * ratio) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw InferenceError.generationFailed("Could not allocate conversion buffer.")
        }

        var provided = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if provided {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let conversionError { throw conversionError }

        guard let channelData = outputBuffer.floatChannelData else {
            throw InferenceError.generationFailed("Audio conversion produced no samples.")
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}

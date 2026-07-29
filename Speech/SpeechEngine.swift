import Foundation
import Combine
import AVFoundation
import FluidAudio

/// Text-to-speech (Kokoro) and speech-to-text (Parakeet) in-process via FluidAudio,
/// replacing the LocalAI OpenAI-compatible proxy. Both models are CoreML/Neural-Engine —
/// no relation to the MLX text/vision models in `MLXEngine`, so they load independently.
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

    @Published private(set) var isReady = false
    @Published private(set) var loadError: String?

    private var tts: KokoroTtsManager?
    private var asr: AsrManager?
    private var loadingTask: Task<Void, Never>?

    private init() {}

    // MARK: - BackendStatusReporting

    var status: BackendStatus {
        guard AppSettings.shared.speechEnabled else { return .disabled }
        if loadError != nil { return .unreachable }
        return isReady ? .running : .unknown
    }

    var runningSummary: String { "Running" }
    var detailItems: [String] { [] }
    var unreachableHint: String {
        loadError.map { "Speech models failed to load: \($0)" } ?? "Speech models not loaded yet"
    }

    // MARK: - Lifecycle

    /// Loads Kokoro + Parakeet on first use. Cheap on repeat calls once loaded.
    func ensureLoaded() async throws {
        if isReady { return }
        if let loadingTask {
            await loadingTask.value
        } else {
            let task = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let ttsManager = KokoroTtsManager()
                    try await ttsManager.initialize()

                    let models = try await AsrModels.downloadAndLoad(version: .v3)
                    let asrManager = AsrManager(config: .default)
                    try await asrManager.initialize(models: models)

                    self.tts = ttsManager
                    self.asr = asrManager
                    self.isReady = true
                    self.loadError = nil
                } catch {
                    self.loadError = error.localizedDescription
                }
                self.loadingTask = nil
            }
            loadingTask = task
            await task.value
        }
        if let loadError {
            throw InferenceError.generationFailed(loadError)
        }
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
                    try await self.ensureLoaded()
                    guard let tts = self.tts else {
                        throw InferenceError.generationFailed("Text-to-speech is not loaded.")
                    }
                    let resolvedVoice = (voice?.isEmpty == false) ? voice! : AppSettings.shared.ttsVoice
                    guard !resolvedVoice.isEmpty else {
                        throw InferenceError.modelNotSelected(capability: "speech")
                    }
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

    /// A whole utterance as a WAV-wrapped buffer, for the Settings preview (`AVAudioPlayer`
    /// needs a container; the wire protocol strips this same header for its headerless PCM).
    func synthesizePreviewWAV(voice: String, sample: String) async throws -> Data {
        try await ensureLoaded()
        guard let tts else {
            throw InferenceError.generationFailed("Text-to-speech is not loaded.")
        }
        return try await tts.synthesize(text: sample, voice: voice)
    }

    // MARK: - Transcription

    func transcribe(audio: Data, format: String) async throws -> (text: String, language: String?) {
        try await ensureLoaded()
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

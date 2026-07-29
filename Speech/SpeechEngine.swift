import Foundation
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

    private var tts: KokoroAneManager?
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
                    let ttsManager = KokoroAneManager()
                    try await ttsManager.initialize()

                    let models = try await AsrModels.downloadAndLoad(version: .v3)
                    let asrManager = AsrManager(config: .default)
                    try await asrManager.loadModels(models)

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
                        text: text, voice: resolvedVoice, speed: Float(speed ?? 1.0)
                    )
                    let pcm = Self.pcm16Data(from: result.samples)

                    var offset = 0
                    while offset < pcm.count {
                        let end = min(offset + Self.chunkBytes, pcm.count)
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

    /// Collects a whole utterance into one WAV-wrapped buffer, for the Settings preview
    /// (`AVAudioPlayer` needs a container; the wire protocol's raw PCM is headerless by
    /// design so BigBroAudioPlayer can split it at arbitrary byte boundaries).
    func synthesizePreviewWAV(voice: String, sample: String) async throws -> Data {
        var pcm = Data()
        for try await chunk in synthesize(text: sample, voice: voice) {
            pcm.append(chunk)
        }
        return Self.wavData(from: pcm, sampleRate: Self.sampleRate)
    }

    // MARK: - Transcription

    func transcribe(audio: Data, format: String) async throws -> (text: String, language: String?) {
        try await ensureLoaded()
        guard let asr else {
            throw InferenceError.generationFailed("Speech-to-text is not loaded.")
        }
        let samples = try Self.floatSamples(from: audio, format: format)
        let result = try await asr.transcribe(samples)
        return (result.text, nil)
    }

    // MARK: - Audio conversion

    private static func pcm16Data(from samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var intSample = Int16(clamped * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &intSample) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func wavData(from pcm16: Data, sampleRate: Int) -> Data {
        var header = Data()
        func append32(_ v: UInt32) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        func append16(_ v: UInt16) {
            var le = v.littleEndian
            withUnsafeBytes(of: &le) { header.append(contentsOf: $0) }
        }
        let byteRate = sampleRate * 2  // mono, 16-bit
        header.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + pcm16.count))
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8))
        append32(16)
        append16(1)  // PCM
        append16(1)  // mono
        append32(UInt32(sampleRate))
        append32(UInt32(byteRate))
        append16(2)   // block align
        append16(16)  // bits per sample
        header.append(contentsOf: Array("data".utf8))
        append32(UInt32(pcm16.count))
        return header + pcm16
    }

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

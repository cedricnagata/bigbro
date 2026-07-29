import Foundation
import AVFoundation
import Combine

/// Plays a synthesized sample on the Mac, so a voice can be auditioned from Settings without
/// a paired device or the peer protocol in the loop.
///
/// Requests `wav` rather than the configured wire format: AVAudioPlayer needs a container,
/// and the `pcm` default is deliberately headerless.
@MainActor
final class SpeechPreview: ObservableObject {
    @Published private(set) var isSynthesizing = false
    @Published private(set) var error: String?

    private let proxy = OpenAIProxy()
    /// Retained deliberately — a released AVAudioPlayer stops mid-playback.
    private var player: AVAudioPlayer?

    func play(voice: String, sample: String = "The quick brown fox jumps over the lazy dog.") {
        guard !isSynthesizing else { return }
        isSynthesizing = true
        error = nil

        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isSynthesizing = false }
            do {
                let audio = try await self.proxy.synthesizeAll(
                    input: sample,
                    voice: voice,
                    responseFormat: "wav"
                )
                let player = try AVAudioPlayer(data: audio)
                self.player = player
                player.play()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

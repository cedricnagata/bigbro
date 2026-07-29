import SwiftUI
import AppKit
import Combine

@main
struct BigBroApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra("BigBro", image: "bigbro") {
            DeviceListView()
                .environmentObject(appModel.pairingManager)
                .environmentObject(appModel.mlxEngine)
                .environmentObject(appModel.speechEngine)
                .environmentObject(appModel.modelDownloader)
                .onAppear { appDelegate.appModel = appModel }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel.pairingManager)
                .environmentObject(appModel.mlxEngine)
                .environmentObject(appModel.speechEngine)
                .environmentObject(appModel.modelDownloader)
        }
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var appModel: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let appModel else { return .terminateNow }
        Task { @MainActor in
            await appModel.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

// MARK: - App model

@MainActor
final class AppModel: ObservableObject {
    let pairingManager = PairingManager()
    let mlxEngine = MLXEngine.shared
    let speechEngine = SpeechEngine.shared
    let modelDownloader = ModelDownloader()
    private let server = PeerServer()
    private let advertiser = BonjourAdvertiser()
    private let router: AppRouter  // must be retained — delegate is weak
    private var cancellables: Set<AnyCancellable> = []

    init() {
        router = AppRouter(pairingManager: pairingManager, modelDownloader: modelDownloader)
        pairingManager.peerServer = server
        pairingManager.modelDownloader = modelDownloader

        // Loading Kokoro + Parakeet is not free, so it only happens once the user actually
        // opts in — never eagerly at launch.
        AppSettings.shared.$speechEnabled
            .dropFirst()
            .filter { $0 }
            .sink { _ in
                Task { try? await SpeechEngine.shared.ensureLoaded() }
            }
            .store(in: &cancellables)

        modelDownloader.updates
            .sink { [weak self] update in
                self?.pairingManager.broadcastDownloadProgress(model: update.model, progress: update.progress)
                if update.progress.done && update.progress.error == nil {
                    self?.pairingManager.pushModelsUpdate()
                }
            }
            .store(in: &cancellables)

        Task {
            await server.setDelegate(router)
            do {
                try await server.start(port: 8765)
                advertiser.start(port: 8765)
                print("[BigBro] Server started on port 8765")
            } catch {
                print("[BigBro] Failed to start server: \(error)")
            }
        }
    }

    func shutdown() async {
        print("[BigBro] Shutting down")
        await server.shutdown()
    }
}

// MARK: - Message router

final class AppRouter: PeerServerDelegate, @unchecked Sendable {
    private let pairingManager: PairingManager
    private let mlxEngine = MLXEngine.shared
    private let speechEngine = SpeechEngine.shared
    private let modelDownloader: ModelDownloader
    private let powerAssertion = PowerAssertion()
    weak var server: PeerServer?

    init(
        pairingManager: PairingManager,
        modelDownloader: ModelDownloader
    ) {
        self.pairingManager = pairingManager
        self.modelDownloader = modelDownloader
        print("[AppRouter] Initialized")
    }

    func peerServer(_ server: PeerServer, didReceive message: [String: Any], connectionId: UUID) async {
        guard let type = message["type"] as? String else {
            print("[AppRouter] Received message with no type from \(connectionId)")
            return
        }
        print("[AppRouter] ← \(connectionId): type=\(type)")

        if type == "hello" {
            let deviceId = message["deviceId"] as? String ?? ""
            let deviceName = message["deviceName"] as? String ?? "Unknown"
            let appName = message["appName"] as? String ?? "Unknown App"
            let requiredModels = message["requiredModels"] as? [String] ?? []
            print("[AppRouter] hello from deviceId=\(deviceId.prefix(8)) name='\(deviceName)' app='\(appName)' requiredModels=\(requiredModels)")
            await pairingManager.handleHello(deviceId: deviceId, deviceName: deviceName, appName: appName, requiredModels: requiredModels, connectionId: connectionId, server: server)
            return
        }

        guard let deviceId = await server.deviceId(for: connectionId) else {
            print("[AppRouter] No deviceId for connectionId \(connectionId) (type=\(type))")
            return
        }

        switch type {
        case "request":
            print("[AppRouter] request from \(deviceId.prefix(8))")
            await handleRequest(message, server: server, deviceId: deviceId)
        case "generateRequest":
            print("[AppRouter] generateRequest from \(deviceId.prefix(8))")
            await handleGenerateRequest(message, server: server, deviceId: deviceId)
        case "speechRequest":
            print("[AppRouter] speechRequest from \(deviceId.prefix(8))")
            await handleSpeechRequest(message, server: server, deviceId: deviceId)
        case "transcribeRequest":
            print("[AppRouter] transcribeRequest from \(deviceId.prefix(8))")
            await handleTranscribeRequest(message, server: server, deviceId: deviceId)
        case "bye":
            print("[AppRouter] bye from \(deviceId.prefix(8)), marking disconnected")
            await MainActor.run { pairingManager.markDisconnected(deviceId) }
            await server.disconnect(deviceId: deviceId)
        default:
            print("[AppRouter] unhandled message type '\(type)' from \(deviceId.prefix(8))")
        }
    }

    func peerServer(_ server: PeerServer, didDisconnectPeer deviceId: String) async {
        print("[AppRouter] Peer disconnected: \(deviceId.prefix(8))")
        await MainActor.run { pairingManager.markDisconnected(deviceId) }
    }

    func peerServer(_ server: PeerServer, didConnectFirstPeer deviceId: String) async {
        print("[AppRouter] First peer connected: \(deviceId.prefix(8)) — acquiring power assertion")
        await MainActor.run { powerAssertion.acquire(reason: "bigbro: peer connected") }
    }

    func peerServer(_ server: PeerServer, didDisconnectLastPeer deviceId: String) async {
        print("[AppRouter] Last peer disconnected: \(deviceId.prefix(8)) — releasing power assertion")
        await MainActor.run { powerAssertion.release() }
    }

    // MARK: - Missing-model handling

    /// Returns true once the model this request needs is ready to use. If it isn't, kicks
    /// off (or reports) a download and tells the peer, mirroring the old Ollama-missing-model
    /// flow so BigBroKit clients need no changes.
    private func ensureModelReady(
        for messages: [[String: Any]],
        requestId: String,
        deviceId: String,
        server: PeerServer
    ) async -> Bool {
        let kind = mlxEngine.kind(for: messages)
        if mlxEngine.isDownloaded(kind) { return true }

        let modelName = kind.displayName
        let alreadyInProgress = modelDownloader.isDownloading(modelName)
        if !alreadyInProgress {
            print("[AppRouter] Model '\(modelName)' missing — starting download for \(deviceId.prefix(8))")
            modelDownloader.startDownload(modelName)
        } else {
            print("[AppRouter] Model '\(modelName)' already downloading — informing \(deviceId.prefix(8))")
        }
        await server.send([
            "type": "modelDownloading",
            "requestId": requestId,
            "model": modelName,
            "alreadyInProgress": alreadyInProgress,
        ], to: deviceId)
        await server.send(["type": "done", "requestId": requestId], to: deviceId)
        return false
    }

    // MARK: - Event forwarding

    /// Forwards one inference event to the peer.
    ///
    /// Reasoning goes out as its own message type rather than folded into `chunk`: the
    /// client pipes chunks to text-to-speech, so merging them would have the model narrate
    /// its own deliberation aloud. Clients that predate this type ignore it.
    private func send(
        _ event: InferenceEvent,
        requestId: String,
        deviceId: String,
        server: PeerServer
    ) async {
        switch event {
        case .delta(let text):
            await server.send(["type": "chunk", "requestId": requestId, "delta": text], to: deviceId)
        case .reasoning(let text):
            await server.send(["type": "thinking", "requestId": requestId, "delta": text], to: deviceId)
        case .toolCalls(let calls):
            print("[AppRouter] toolCall detected for \(requestId.prefix(8)): \(calls.count)")
            await server.send(["type": "toolCall", "requestId": requestId, "calls": calls], to: deviceId)
        }
    }

    /// Drains an inference stream to the peer. `request` and `generateRequest` both funnel
    /// through here — the old split between a streamed and single-shot code path existed
    /// because the OpenAI-compatible backend had two different HTTP shapes; MLX generation is
    /// always token-by-token, so there is only one path now regardless of the client's
    /// `streaming` flag (which governs *client-side* accumulation, not what the Mac sends).
    private func drain(
        _ stream: AsyncThrowingStream<InferenceEvent, Error>,
        requestId: String,
        deviceId: String,
        server: PeerServer,
        label: String
    ) async {
        do {
            var chunkCount = 0
            for try await event in stream {
                if case .delta = event { chunkCount += 1 }
                await send(event, requestId: requestId, deviceId: deviceId, server: server)
            }
            print("[AppRouter] \(label) complete for \(requestId.prefix(8)): \(chunkCount) chunk(s)")
            await server.send(["type": "done", "requestId": requestId], to: deviceId)
        } catch {
            print("[AppRouter] \(label) error for \(requestId.prefix(8)): \(error)")
            await server.send(["type": "error", "requestId": requestId, "message": error.localizedDescription], to: deviceId)
        }
    }

    // MARK: - Request handlers

    private func handleRequest(_ message: [String: Any], server: PeerServer, deviceId: String) async {
        guard let requestId = message["requestId"] as? String,
              let messagesRaw = message["messages"] as? [[String: Any]] else {
            print("[AppRouter] handleRequest: missing requestId or messages")
            return
        }
        let tools   = (message["tools"] as? [[String: Any]]) ?? []
        let options = message["options"] as? [String: Any]

        print("[AppRouter] handleRequest: requestId=\(requestId.prefix(8)) tools=\(tools.count) messages=\(messagesRaw.count)")

        guard await ensureModelReady(for: messagesRaw, requestId: requestId, deviceId: deviceId, server: server) else { return }

        let stream = mlxEngine.chatStream(messages: messagesRaw, tools: tools, options: options)
        await drain(stream, requestId: requestId, deviceId: deviceId, server: server, label: "Request")
    }

    private func handleGenerateRequest(_ message: [String: Any], server: PeerServer, deviceId: String) async {
        guard let requestId = message["requestId"] as? String,
              let prompt = message["prompt"] as? String else {
            print("[AppRouter] handleGenerateRequest: missing requestId or prompt")
            return
        }
        let images  = (message["images"] as? [String]) ?? []
        let system  = message["system"] as? String
        let options = message["options"] as? [String: Any]

        print("[AppRouter] handleGenerateRequest: requestId=\(requestId.prefix(8)) prompt='\(prompt.prefix(40))…'")

        var messagesRaw: [[String: Any]] = []
        if let system, !system.isEmpty {
            messagesRaw.append(["role": "system", "content": system])
        }
        var user: [String: Any] = ["role": "user", "content": prompt]
        if !images.isEmpty { user["images"] = images }
        messagesRaw.append(user)

        guard await ensureModelReady(for: messagesRaw, requestId: requestId, deviceId: deviceId, server: server) else { return }

        let stream = mlxEngine.chatStream(messages: messagesRaw, tools: [], options: options)
        await drain(stream, requestId: requestId, deviceId: deviceId, server: server, label: "Generate")
    }

    // MARK: - Speech handlers

    /// Cap on an uploaded utterance after base64 decoding. Rejecting an oversized upload
    /// beats buffering it unboundedly.
    private static let maxUploadBytes = 10 * 1024 * 1024

    private func speechReady(requestId: String, deviceId: String, server: PeerServer) async -> Bool {
        guard await MainActor.run(body: { AppSettings.shared.speechEnabled }) else {
            await fail(requestId, "Speech is not enabled in BigBro Settings.", deviceId: deviceId, server: server)
            return false
        }
        return true
    }

    private func fail(_ requestId: String, _ message: String, deviceId: String, server: PeerServer) async {
        print("[AppRouter] \(requestId.prefix(8)): \(message)")
        await server.send(["type": "error", "requestId": requestId, "message": message], to: deviceId)
    }

    private func handleSpeechRequest(_ message: [String: Any], server: PeerServer, deviceId: String) async {
        guard let requestId = message["requestId"] as? String,
              let input = message["input"] as? String else {
            print("[AppRouter] handleSpeechRequest: missing requestId or input")
            return
        }
        guard await speechReady(requestId: requestId, deviceId: deviceId, server: server) else { return }

        let voice = message["voice"] as? String
        let speed = message["speed"] as? Double
        let resolvedVoice = await MainActor.run { voice?.isEmpty == false ? voice! : AppSettings.shared.ttsVoice }

        do {
            // Headerless PCM describes nothing about itself, so the client is told the
            // format up front — it needs the rate and channel count to configure playback
            // before the first chunk lands. Always pcm/24kHz/mono now — Kokoro has no other
            // output shape, so there is nothing left to negotiate here.
            await server.send([
                "type": "audioStart",
                "requestId": requestId,
                "format": "pcm",
                "sampleRate": SpeechEngine.sampleRate,
                "channels": 1,
                "voice": resolvedVoice,
            ], to: deviceId)

            var seq = 0
            for try await chunk in speechEngine.synthesize(text: input, voice: voice, speed: speed) {
                guard await server.isConnected(deviceId: deviceId) else {
                    print("[AppRouter] Peer \(deviceId.prefix(8)) gone, abandoning speech \(requestId.prefix(8))")
                    return
                }
                await server.send([
                    "type": "audioChunk",
                    "requestId": requestId,
                    "audio": chunk.base64EncodedString(),
                    "seq": seq,
                ], to: deviceId)
                seq += 1
            }
            print("[AppRouter] Speech complete for \(requestId.prefix(8)): \(seq) chunk(s)")
            await server.send(["type": "done", "requestId": requestId], to: deviceId)
        } catch {
            print("[AppRouter] Speech error for \(requestId.prefix(8)): \(error)")
            await server.send(["type": "error", "requestId": requestId, "message": error.localizedDescription], to: deviceId)
        }
    }

    private func handleTranscribeRequest(_ message: [String: Any], server: PeerServer, deviceId: String) async {
        guard let requestId = message["requestId"] as? String,
              let base64 = message["audio"] as? String else {
            print("[AppRouter] handleTranscribeRequest: missing requestId or audio")
            return
        }
        guard await speechReady(requestId: requestId, deviceId: deviceId, server: server) else { return }

        guard let audio = Data(base64Encoded: base64) else {
            await fail(requestId, "Audio payload was not valid base64.", deviceId: deviceId, server: server)
            return
        }
        guard audio.count <= Self.maxUploadBytes else {
            let mb = Self.maxUploadBytes / 1_048_576
            await fail(requestId, "Audio exceeds the \(mb) MB upload limit.", deviceId: deviceId, server: server)
            return
        }

        let format = message["audioFormat"] as? String ?? "wav"

        do {
            let result = try await speechEngine.transcribe(audio: audio, format: format)
            print("[AppRouter] Transcript for \(requestId.prefix(8)): \(result.text.count) chars")
            var reply: [String: Any] = [
                "type": "transcript",
                "requestId": requestId,
                "text": result.text,
            ]
            if let language = result.language { reply["language"] = language }
            await server.send(reply, to: deviceId)
            await server.send(["type": "done", "requestId": requestId], to: deviceId)
        } catch {
            print("[AppRouter] Transcribe error for \(requestId.prefix(8)): \(error)")
            await server.send(["type": "error", "requestId": requestId, "message": error.localizedDescription], to: deviceId)
        }
    }
}

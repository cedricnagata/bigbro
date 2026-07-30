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
        // opts in — but that includes "already opted in": `$speechEnabled` publishes its
        // current value immediately on subscription, so if speech was left on from a
        // previous launch this fires right away rather than needing a fresh toggle.
        // `ensureLoaded` is idempotent, so re-firing on every `true` costs nothing.
        AppSettings.shared.$speechEnabled
            .filter { $0 }
            .sink { _ in
                Task { try? await SpeechEngine.shared.ensureLoaded(.tts) }
                Task { try? await SpeechEngine.shared.ensureLoaded(.stt) }
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
        case "preload":
            print("[AppRouter] preload from \(deviceId.prefix(8))")
            await handlePreloadRequest(message, server: server, deviceId: deviceId)
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

    /// Returns true once `kind` is ready to use. If it isn't, kicks off (or reports) a
    /// download and tells the peer, mirroring the old Ollama-missing-model flow so BigBroKit
    /// clients need no changes. Callers that already know which model they need (a `preload`)
    /// pass it directly; chat/generate derive it from message content via `mlxEngine.kind(for:)`.
    private func ensureModelReady(
        _ kind: MLXEngine.ModelKind,
        requestId: String,
        deviceId: String,
        server: PeerServer
    ) async -> Bool {
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
    ///
    /// `sendReasoning` gates only what goes out over the wire, not generation itself — the
    /// model still produces the analysis channel either way, so a client that wants a faster
    /// perceived response can opt out of receiving it without changing what gets computed.
    private func send(
        _ event: InferenceEvent,
        requestId: String,
        deviceId: String,
        server: PeerServer,
        sendReasoning: Bool
    ) async {
        switch event {
        case .delta(let text):
            await server.send(["type": "chunk", "requestId": requestId, "delta": text], to: deviceId)
        case .reasoning(let text):
            guard sendReasoning else { return }
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
        label: String,
        sendReasoning: Bool
    ) async {
        do {
            var chunkCount = 0
            for try await event in stream {
                if case .delta = event { chunkCount += 1 }
                await send(event, requestId: requestId, deviceId: deviceId, server: server, sendReasoning: sendReasoning)
            }
            print("[AppRouter] \(label) complete for \(requestId.prefix(8)): \(chunkCount) chunk(s)")
            await server.send(["type": "done", "requestId": requestId], to: deviceId)
        } catch {
            print("[AppRouter] \(label) error for \(requestId.prefix(8)): \(error)")
            await server.send(["type": "error", "requestId": requestId, "message": error.localizedDescription], to: deviceId)
        }
    }

    // MARK: - Reasoning

    /// The reasoning budgets gpt-oss will accept. The Harmony template renders the value
    /// straight into the system message as `Reasoning: <level>`, and the model was trained on
    /// exactly these three words — a fourth would land in the prompt as text it has never
    /// seen. There is deliberately no "off". Anything unrecognized is dropped rather than
    /// forwarded, so a client sending junk gets the template default, not a poisoned prompt.
    private static let validReasoningEfforts: Set<String> = ["low", "medium", "high"]

    /// Resolves the effort for one request.
    ///
    /// An explicit `reasoning_effort` from the client always wins — that is the client saying
    /// how hard the model should think, independent of whether it wants to see the result.
    /// Absent one, `think: false` is read as a hint that the caller wants speed and has no
    /// use for the trace, so the budget drops to "low"; this is what that flag alone did
    /// before clients could ask for a level, and keeps their behavior unchanged. When neither
    /// is specified the template's own default ("medium") stands.
    private func resolveReasoningEffort(_ message: [String: Any], sendReasoning: Bool) -> String? {
        if let requested = message["reasoning_effort"] as? String {
            guard Self.validReasoningEfforts.contains(requested.lowercased()) else {
                print("[AppRouter] ignoring unrecognized reasoning_effort '\(requested)'")
                return nil
            }
            return requested.lowercased()
        }
        return sendReasoning ? nil : "low"
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
        // Absent means "unspecified", which defaults to on — this is what every client sent
        // before `think` existed, so their behavior (reasoning always forwarded) is unchanged.
        let sendReasoning = (message["think"] as? Bool) ?? true
        // Effort actually shortens the model's analysis-channel generation before it reaches
        // the final channel — unlike sendReasoning, which only affects what's forwarded after
        // the fact.
        let reasoningEffort = resolveReasoningEffort(message, sendReasoning: sendReasoning)

        print("[AppRouter] handleRequest: requestId=\(requestId.prefix(8)) tools=\(tools.count) messages=\(messagesRaw.count) think=\(sendReasoning) effort=\(reasoningEffort ?? "default")")

        let kind = mlxEngine.kind(for: messagesRaw)
        guard await ensureModelReady(kind, requestId: requestId, deviceId: deviceId, server: server) else { return }

        let stream = mlxEngine.chatStream(messages: messagesRaw, tools: tools, options: options, reasoningEffort: reasoningEffort)
        await drain(stream, requestId: requestId, deviceId: deviceId, server: server, label: "Request", sendReasoning: sendReasoning)
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
        let sendReasoning = (message["think"] as? Bool) ?? true
        let reasoningEffort = resolveReasoningEffort(message, sendReasoning: sendReasoning)

        print("[AppRouter] handleGenerateRequest: requestId=\(requestId.prefix(8)) prompt='\(prompt.prefix(40))…' think=\(sendReasoning) effort=\(reasoningEffort ?? "default")")

        var messagesRaw: [[String: Any]] = []
        if let system, !system.isEmpty {
            messagesRaw.append(["role": "system", "content": system])
        }
        var user: [String: Any] = ["role": "user", "content": prompt]
        if !images.isEmpty { user["images"] = images }
        messagesRaw.append(user)

        let kind = mlxEngine.kind(for: messagesRaw)
        guard await ensureModelReady(kind, requestId: requestId, deviceId: deviceId, server: server) else { return }

        let stream = mlxEngine.chatStream(messages: messagesRaw, tools: [], options: options, reasoningEffort: reasoningEffort)
        await drain(stream, requestId: requestId, deviceId: deviceId, server: server, label: "Generate", sendReasoning: sendReasoning)
    }

    /// Loads a model into memory without generating anything, so a client can pay the
    /// multi-second "materialize weights into MLX arrays" cost ahead of the user's first
    /// message — e.g. when a chat screen opens — rather than that cost landing on the first
    /// real request. Purely an optimization: nothing else in the app requires this message,
    /// and skipping it is harmless since `chatStream` calls `ensureLoaded` lazily either way.
    private func handlePreloadRequest(_ message: [String: Any], server: PeerServer, deviceId: String) async {
        guard let requestId = message["requestId"] as? String else {
            print("[AppRouter] handlePreloadRequest: missing requestId")
            return
        }
        let wantsVision = (message["model"] as? String)?.lowercased() == "vision"
        let kind: MLXEngine.ModelKind = wantsVision ? .vision : .text

        print("[AppRouter] preload requested by \(deviceId.prefix(8)) for \(kind.displayName)")
        guard await ensureModelReady(kind, requestId: requestId, deviceId: deviceId, server: server) else { return }

        do {
            try await mlxEngine.ensureLoaded(kind)
            print("[AppRouter] preload complete for \(deviceId.prefix(8)): \(kind.displayName)")
            await server.send(["type": "done", "requestId": requestId], to: deviceId)
        } catch {
            print("[AppRouter] preload error for \(deviceId.prefix(8)): \(error)")
            await server.send(["type": "error", "requestId": requestId, "message": error.localizedDescription], to: deviceId)
        }
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

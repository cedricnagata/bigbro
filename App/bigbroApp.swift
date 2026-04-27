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
                .environmentObject(appModel.ollamaMonitor)
                .environmentObject(appModel.modelDownloader)
                .onAppear { appDelegate.appModel = appModel }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel.pairingManager)
                .environmentObject(appModel.ollamaMonitor)
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
    let ollamaMonitor = OllamaMonitor()
    let modelDownloader = ModelDownloader()
    private let server = PeerServer()
    private let advertiser = BonjourAdvertiser()
    private let router: AppRouter  // must be retained — delegate is weak
    private var cancellables: Set<AnyCancellable> = []

    init() {
        router = AppRouter(pairingManager: pairingManager, ollamaMonitor: ollamaMonitor, modelDownloader: modelDownloader)
        pairingManager.peerServer = server
        pairingManager.ollamaMonitor = ollamaMonitor
        pairingManager.modelDownloader = modelDownloader
        ollamaMonitor.start()

        ollamaMonitor.$installedModels
            .dropFirst()
            .sink { [weak self] _ in
                self?.pairingManager.pushModelsUpdate()
            }
            .store(in: &cancellables)

        modelDownloader.updates
            .sink { [weak self] update in
                self?.pairingManager.broadcastDownloadProgress(model: update.model, progress: update.progress)
                if update.progress.done && update.progress.error == nil {
                    // Refresh installed model list so connected peers' missingModels updates.
                    Task { await self?.ollamaMonitor.refresh() }
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
        ollamaMonitor.stop()
        await server.shutdown()
    }
}

// MARK: - Message router

final class AppRouter: PeerServerDelegate, @unchecked Sendable {
    private let pairingManager: PairingManager
    private let inferenceProxy = InferenceProxy()
    private let ollamaMonitor: OllamaMonitor
    private let modelDownloader: ModelDownloader
    private let powerAssertion = PowerAssertion()
    weak var server: PeerServer?

    init(pairingManager: PairingManager, ollamaMonitor: OllamaMonitor, modelDownloader: ModelDownloader) {
        self.pairingManager = pairingManager
        self.ollamaMonitor = ollamaMonitor
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

    private func handleMissingModel(_ model: String, requestId: String, deviceId: String, server: PeerServer) async {
        let alreadyInProgress = await MainActor.run { modelDownloader.isDownloading(model) }
        if !alreadyInProgress {
            print("[AppRouter] Model '\(model)' missing — starting download for \(deviceId.prefix(8))")
            await MainActor.run { modelDownloader.startDownload(model) }
        } else {
            print("[AppRouter] Model '\(model)' already downloading — informing \(deviceId.prefix(8))")
        }
        await server.send([
            "type": "modelDownloading",
            "requestId": requestId,
            "model": model,
            "alreadyInProgress": alreadyInProgress,
        ], to: deviceId)
        await server.send(["type": "done", "requestId": requestId], to: deviceId)
    }

    // MARK: - Request handlers

    private func handleRequest(_ message: [String: Any], server: PeerServer, deviceId: String) async {
        guard let requestId = message["requestId"] as? String,
              let messagesRaw = message["messages"] as? [[String: Any]] else {
            print("[AppRouter] handleRequest: missing requestId or messages")
            return
        }
        let tools     = (message["tools"] as? [[String: Any]]) ?? []
        let streaming = message["streaming"] as? Bool ?? true
        let model     = message["model"] as? String
        let format    = message["format"]               // Any? — "json" string or schema dict
        let options   = message["options"] as? [String: Any]
        let think     = message["think"] as? Bool
        let keepAlive = message["keep_alive"] as? String

        print("[AppRouter] handleRequest: requestId=\(requestId.prefix(8)) streaming=\(streaming) tools=\(tools.count) messages=\(messagesRaw.count)")

        let resolvedModel = await MainActor.run {
            model?.isEmpty == false ? model! : AppSettings.shared.defaultModel
        }
        let modelInstalled = await MainActor.run { ollamaMonitor.isInstalled(resolvedModel) }
        if !modelInstalled {
            await handleMissingModel(resolvedModel, requestId: requestId, deviceId: deviceId, server: server)
            return
        }

        do {
            if streaming {
                var chunkCount = 0
                for try await delta in inferenceProxy.forwardStream(
                    messages: messagesRaw,
                    model: model,
                    tools: tools,
                    format: format,
                    options: options,
                    think: think,
                    keepAlive: keepAlive
                ) {
                    if delta.hasPrefix(toolCallsSentinel) {
                        let jsonStr = String(delta.dropFirst(toolCallsSentinel.count))
                        if let data = jsonStr.data(using: .utf8),
                           let calls = try? JSONSerialization.jsonObject(with: data) {
                            print("[AppRouter] toolCall detected for \(requestId.prefix(8))")
                            await server.send(["type": "toolCall", "requestId": requestId, "calls": calls], to: deviceId)
                        }
                    } else {
                        chunkCount += 1
                        await server.send(["type": "chunk", "requestId": requestId, "delta": delta], to: deviceId)
                    }
                }
                print("[AppRouter] Stream complete for \(requestId.prefix(8)): \(chunkCount) chunk(s)")
            } else {
                let reply = try await inferenceProxy.forward(
                    messages: messagesRaw,
                    model: model,
                    tools: tools,
                    format: format,
                    options: options,
                    think: think,
                    keepAlive: keepAlive
                )
                print("[AppRouter] Non-streaming reply for \(requestId.prefix(8)): \(reply.count) chars")
                if reply.hasPrefix(toolCallsSentinel) {
                    let jsonStr = String(reply.dropFirst(toolCallsSentinel.count))
                    if let tcData = jsonStr.data(using: .utf8),
                       let calls = try? JSONSerialization.jsonObject(with: tcData) {
                        print("[AppRouter] toolCall detected for \(requestId.prefix(8))")
                        await server.send(["type": "toolCall", "requestId": requestId, "calls": calls], to: deviceId)
                    }
                } else {
                    await server.send(["type": "chunk", "requestId": requestId, "delta": reply], to: deviceId)
                }
            }
            await server.send(["type": "done", "requestId": requestId], to: deviceId)
            print("[AppRouter] done sent for \(requestId.prefix(8))")
        } catch {
            print("[AppRouter] Inference error for \(requestId.prefix(8)): \(error)")
            await server.send(["type": "error", "requestId": requestId, "message": error.localizedDescription], to: deviceId)
        }
    }

    private func handleGenerateRequest(_ message: [String: Any], server: PeerServer, deviceId: String) async {
        guard let requestId = message["requestId"] as? String,
              let prompt = message["prompt"] as? String else {
            print("[AppRouter] handleGenerateRequest: missing requestId or prompt")
            return
        }
        let images    = (message["images"] as? [String]) ?? []
        let suffix    = message["suffix"] as? String
        let system    = message["system"] as? String
        let template  = message["template"] as? String
        let model     = message["model"] as? String
        let format    = message["format"]
        let options   = message["options"] as? [String: Any]
        let raw       = message["raw"] as? Bool
        let think     = message["think"] as? Bool
        let keepAlive = message["keep_alive"] as? String
        let streaming = message["streaming"] as? Bool ?? true

        print("[AppRouter] handleGenerateRequest: requestId=\(requestId.prefix(8)) streaming=\(streaming) prompt='\(prompt.prefix(40))…'")

        let resolvedModel = await MainActor.run {
            model?.isEmpty == false ? model! : AppSettings.shared.defaultModel
        }
        let modelInstalled = await MainActor.run { ollamaMonitor.isInstalled(resolvedModel) }
        if !modelInstalled {
            await handleMissingModel(resolvedModel, requestId: requestId, deviceId: deviceId, server: server)
            return
        }

        do {
            if streaming {
                var chunkCount = 0
                for try await delta in inferenceProxy.forwardGenerateStream(
                    prompt: prompt,
                    images: images,
                    suffix: suffix,
                    system: system,
                    template: template,
                    model: model,
                    format: format,
                    options: options,
                    raw: raw,
                    think: think,
                    keepAlive: keepAlive
                ) {
                    chunkCount += 1
                    await server.send(["type": "chunk", "requestId": requestId, "delta": delta], to: deviceId)
                }
                print("[AppRouter] Generate stream complete for \(requestId.prefix(8)): \(chunkCount) chunk(s)")
            } else {
                let reply = try await inferenceProxy.forwardGenerate(
                    prompt: prompt,
                    images: images,
                    suffix: suffix,
                    system: system,
                    template: template,
                    model: model,
                    format: format,
                    options: options,
                    raw: raw,
                    think: think,
                    keepAlive: keepAlive
                )
                print("[AppRouter] Non-streaming generate reply for \(requestId.prefix(8)): \(reply.count) chars")
                await server.send(["type": "chunk", "requestId": requestId, "delta": reply], to: deviceId)
            }
            await server.send(["type": "done", "requestId": requestId], to: deviceId)
            print("[AppRouter] done sent for \(requestId.prefix(8))")
        } catch {
            print("[AppRouter] Generate error for \(requestId.prefix(8)): \(error)")
            await server.send(["type": "error", "requestId": requestId, "message": error.localizedDescription], to: deviceId)
        }
    }
}

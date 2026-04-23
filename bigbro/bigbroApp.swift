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
                .onAppear { appDelegate.appModel = appModel }
        }

        Settings {
            SettingsView()
                .environmentObject(appModel.pairingManager)
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
    private let server = PeerServer()
    private let advertiser = BonjourAdvertiser()
    private let router: AppRouter  // must be retained — delegate is weak

    init() {
        router = AppRouter(pairingManager: pairingManager)
        pairingManager.peerServer = server
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
    private let inferenceProxy = InferenceProxy()

    init(pairingManager: PairingManager) {
        self.pairingManager = pairingManager
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
            print("[AppRouter] hello from deviceId=\(deviceId.prefix(8)) name='\(deviceName)'")
            await MainActor.run {
                Task { await self.pairingManager.handleHello(deviceId: deviceId, deviceName: deviceName, connectionId: connectionId, server: server) }
            }
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
        case "ping":
            print("[AppRouter] ping from \(deviceId.prefix(8)), sending pong")
            await server.send(["type": "pong"], to: deviceId)
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

    private func handleRequest(_ message: [String: Any], server: PeerServer, deviceId: String) async {
        guard let requestId = message["requestId"] as? String,
              let messagesRaw = message["messages"] as? [[String: Any]] else {
            print("[AppRouter] handleRequest: missing requestId or messages")
            return
        }
        let tools = (message["tools"] as? [[String: Any]]) ?? []
        let streaming = message["streaming"] as? Bool ?? true
        let model: String? = nil

        print("[AppRouter] handleRequest: requestId=\(requestId.prefix(8)) streaming=\(streaming) tools=\(tools.count) messages=\(messagesRaw.count)")

        do {
            if streaming {
                var chunkCount = 0
                for try await delta in inferenceProxy.forwardStream(messages: messagesRaw, model: model, tools: tools) {
                    if delta.hasPrefix("\u{0001}TOOL_CALLS:") {
                        let jsonStr = String(delta.dropFirst(12))
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
                let reply = try await inferenceProxy.forward(messages: messagesRaw, model: model)
                print("[AppRouter] Non-streaming reply for \(requestId.prefix(8)): \(reply.count) chars")
                await server.send(["type": "chunk", "requestId": requestId, "delta": reply], to: deviceId)
            }
            await server.send(["type": "done", "requestId": requestId], to: deviceId)
            print("[AppRouter] done sent for \(requestId.prefix(8))")
        } catch {
            print("[AppRouter] Inference error for \(requestId.prefix(8)): \(error)")
            await server.send(["type": "error", "requestId": requestId, "message": error.localizedDescription], to: deviceId)
        }
    }
}

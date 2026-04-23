import SwiftUI
import AppKit
import Combine

@main
struct BigBroApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra("BigBro", image: "bigbro") {
            DeviceListView()
                .environmentObject(appModel.pairingManager)
        }

        Settings {
            SettingsView()
                .environmentObject(appModel.pairingManager)
        }
    }
}

// MARK: - App model (starts at launch)

@MainActor
final class AppModel: ObservableObject {
    let pairingManager = PairingManager()
    private let server = HTTPServer(port: 8765)
    private let advertiser = BonjourAdvertiser()
    private let router: AppRouter

    init() {
        let r = AppRouter(pairingManager: pairingManager)
        self.router = r
        Task {
            await server.setDelegate(r)
            do {
                try await server.start()
                advertiser.start(port: 8765)
                print("[BigBro] Server started on port 8765")
            } catch {
                print("[BigBro] Failed to start server: \(error)")
            }
        }
    }
}

// MARK: - Route handler

final class AppRouter: HTTPServerDelegate, @unchecked Sendable {
    private let pairingManager: PairingManager
    private let inferenceProxy = InferenceProxy()

    init(pairingManager: PairingManager) {
        self.pairingManager = pairingManager
    }

    func server(_ server: HTTPServer, didReceive request: HTTPRequest) async -> HTTPResponse {
        print("[Router] Routing: method='\(request.method)' path='\(request.path)'")
        switch (request.method, request.path) {
        case ("POST", "/pair/request"):
            return await handlePairRequest(request)
        case ("GET", "/pair/status"):
            return await handlePairStatus(request)
        case ("POST", "/chat"):
            return await handleChat(request)
        case ("GET", "/presence"):
            return await handlePresence(request)
        default:
            return .notFound
        }
    }

    private func handlePresence(_ request: HTTPRequest) async -> HTTPResponse {
        guard let token = request.queryItems["token"] else { return .unauthorized }
        let deviceId = await MainActor.run { pairingManager.deviceId(forToken: token) }
        guard let deviceId else { return .unauthorized }
        let manager = pairingManager
        print("[Router] /presence stream opening for \(deviceId)")
        let (response, cancel, poke) = HTTPResponse.presence(
            onOpen: {
                Task { @MainActor in manager.markConnected(deviceId) }
            },
            onClose: {
                Task { @MainActor in
                    manager.markDisconnected(deviceId)
                    manager.unregisterPresence(deviceId)
                }
            }
        )
        await MainActor.run { manager.registerPresence(deviceId: deviceId, cancel: cancel, poke: poke) }
        return response
    }

    private func handlePairRequest(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body else {
            print("[Router] /pair/request missing body")
            return .badRequest
        }
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: String] else {
            print("[Router] /pair/request body not a JSON string dict: \(String(data: body, encoding: .utf8) ?? "<binary>")")
            return .badRequest
        }
        guard let deviceName = json["device_name"], let deviceId = json["device_id"] else {
            print("[Router] /pair/request missing fields, keys: \(json.keys)")
            return .badRequest
        }
        print("[Router] Pair request from '\(deviceName)' id=\(deviceId)")
        let req = PairingRequest(id: deviceId, deviceName: deviceName, receivedAt: Date())
        await MainActor.run { pairingManager.enqueue(req) }
        print("[Router] Enqueued pair request, returning pending")
        return .json(["status": "pending"])
    }

    private func handlePairStatus(_ request: HTTPRequest) async -> HTTPResponse {
        guard let deviceId = request.queryItems["device_id"] else {
            print("[Router] /pair/status missing device_id query param")
            return .badRequest
        }
        let status = await MainActor.run { pairingManager.status(for: deviceId) }
        print("[Router] Status poll for \(deviceId): \(status)")
        switch status {
        case .pending:
            return .json(["status": "pending"])
        case .approved(let token):
            return .json(["status": "approved", "token": token])
        case .denied:
            return .json(["status": "denied"])
        }
    }

    private func handleChat(_ request: HTTPRequest) async -> HTTPResponse {
        guard let body = request.body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let token = json["token"] as? String,
              let stream = json["stream"] as? Bool,
              let messagesRaw = json["messages"] as? [[String: Any]] else {
            return .badRequest
        }

        let isValid = await MainActor.run { pairingManager.validate(token: token) }
        guard isValid else { return .unauthorized }

        let model = json["model"] as? String
        let tools = (json["tools"] as? [[String: Any]]) ?? []
        if stream {
            let response = inferenceProxy.forwardStream(messages: messagesRaw, model: model, tools: tools)
            return .sse(response)
        } else {
            do {
                let response = try await inferenceProxy.forward(messages: messagesRaw, model: model)
                return .json(["content": response])
            } catch {
                print("[Router] Chat forward failed: \(error)")
                return .json(["error": "upstream failure"], status: 500)
            }
        }
    }
}

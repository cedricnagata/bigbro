import Foundation
import Combine
import AppKit

@MainActor
final class PairingManager: ObservableObject {
    @Published var approvedDevices: [String: String] = [:]  // deviceId → token
    private var deniedDevices: Set<String> = []
    private var pendingRequests: [PairingRequest] = []

    init() {
        approvedDevices = TokenStore.shared.loadAll()
    }

    func enqueue(_ request: PairingRequest) {
        guard !approvedDevices.keys.contains(request.id),
              !deniedDevices.contains(request.id),
              !pendingRequests.contains(where: { $0.id == request.id }) else { return }
        pendingRequests.append(request)
        Task { showAlert(for: request) }
    }

    @discardableResult
    func approve(_ request: PairingRequest) -> String {
        let token = UUID().uuidString
        approvedDevices[request.id] = token
        pendingRequests.removeAll { $0.id == request.id }
        TokenStore.shared.save(deviceId: request.id, token: token)
        return token
    }

    func deny(_ request: PairingRequest) {
        deniedDevices.insert(request.id)
        pendingRequests.removeAll { $0.id == request.id }
    }

    func status(for deviceId: String) -> PairingStatus {
        if let token = approvedDevices[deviceId] { return .approved(token: token) }
        if deniedDevices.contains(deviceId) { return .denied }
        return .pending
    }

    func validate(token: String) -> Bool {
        approvedDevices.values.contains(token)
    }

    private func showAlert(for request: PairingRequest) {
        let alert = NSAlert()
        alert.messageText = "\(request.deviceName) wants to connect"
        alert.informativeText = "Allow this device to use BigBro for AI inference?"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Deny")
        alert.alertStyle = .informational

        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            approve(request)
        } else {
            deny(request)
        }
    }
}

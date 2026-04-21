import Foundation

@MainActor
final class PairingManager: ObservableObject {
    @Published var pendingRequests: [PairingRequest] = []
    @Published var approvedDevices: [String: String] = [:]  // deviceId → token
    private var deniedDevices: Set<String> = []

    init() {
        approvedDevices = TokenStore.shared.loadAll()
    }

    func enqueue(_ request: PairingRequest) {
        guard !approvedDevices.keys.contains(request.id),
              !deniedDevices.contains(request.id),
              !pendingRequests.contains(where: { $0.id == request.id }) else { return }
        pendingRequests.append(request)
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
}

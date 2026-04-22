import Foundation
import Combine
import AppKit

@MainActor
final class PairingManager: ObservableObject {
    @Published var approvedDevices: [String: String] = [:]  // deviceId → token
    @Published var deviceNames: [String: String] = [:]      // deviceId → display name
    @Published var connectedDeviceIds: Set<String> = []
    private var deniedDevices: Set<String> = []
    private var pendingRequests: [PairingRequest] = []

    private static let deviceNamesKey = "bigbro.deviceNames"

    init() {
        approvedDevices = TokenStore.shared.loadAll()
        deviceNames = (UserDefaults.standard.dictionary(forKey: Self.deviceNamesKey) as? [String: String]) ?? [:]
    }

    func displayName(for deviceId: String) -> String {
        deviceNames[deviceId] ?? deviceId
    }

    private func persistNames() {
        UserDefaults.standard.set(deviceNames, forKey: Self.deviceNamesKey)
    }

    func deviceId(forToken token: String) -> String? {
        approvedDevices.first(where: { $0.value == token })?.key
    }

    func markConnected(_ deviceId: String) {
        connectedDeviceIds.insert(deviceId)
    }

    func markDisconnected(_ deviceId: String) {
        connectedDeviceIds.remove(deviceId)
    }

    private var presenceCancels: [String: @Sendable () -> Void] = [:]

    func registerPresence(deviceId: String, cancel: @escaping @Sendable () -> Void) {
        presenceCancels[deviceId] = cancel
    }

    func unregisterPresence(_ deviceId: String) {
        presenceCancels.removeValue(forKey: deviceId)
    }

    /// Force-close every active presence stream. Live clients will reconnect
    /// within seconds; dead clients will stay disconnected in the UI.
    func refreshAll() {
        print("[PairingManager] Refresh: closing \(presenceCancels.count) presence stream(s)")
        for cancel in presenceCancels.values { cancel() }
    }

    func removeAll() {
        for id in approvedDevices.keys { TokenStore.shared.delete(deviceId: id) }
        approvedDevices.removeAll()
        deviceNames.removeAll()
        connectedDeviceIds.removeAll()
        persistNames()
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
        deviceNames[request.id] = request.deviceName
        pendingRequests.removeAll { $0.id == request.id }
        TokenStore.shared.save(deviceId: request.id, token: token)
        persistNames()
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

    func remove(deviceId: String) {
        approvedDevices.removeValue(forKey: deviceId)
        deviceNames.removeValue(forKey: deviceId)
        connectedDeviceIds.remove(deviceId)
        TokenStore.shared.delete(deviceId: deviceId)
        persistNames()
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
